package com.pulsestream.processor.service;

import com.pulsestream.processor.config.AnomalyDetectionProperties;
import com.pulsestream.processor.config.KafkaConsumerConfiguration;
import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.consumer.TelemetryEventConsumer;
import com.pulsestream.processor.exception.AnomalyStateException;
import com.pulsestream.processor.model.*;
import java.math.BigDecimal;
import java.time.Duration;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.BooleanSupplier;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.header.internals.RecordHeaders;
import org.apache.kafka.common.record.TimestampType;
import org.apache.kafka.common.serialization.StringSerializer;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.listener.ConcurrentMessageListenerContainer;
import org.springframework.kafka.listener.MessageListener;
import org.springframework.kafka.support.serializer.JacksonJsonSerializer;
import org.springframework.kafka.test.EmbeddedKafkaKraftBroker;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real PostgreSQL state and real Kafka group rebalances; neither dependency may be skipped. */
@Testcontainers
class AnomalyStateIntegrationTest {
    @Container static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16");
    private static final String SINGLE = "anomaly-state-single";
    private static final String SCALED = "anomaly-state-scaled";
    private static final String FAILURE = "anomaly-state-failure";
    private static final String CRASH = "anomaly-state-crash";
    private static final long KAFKA_TIME = System.currentTimeMillis();
    private static EmbeddedKafkaKraftBroker broker;
    private static DefaultKafkaProducerFactory<String, TelemetryEvent> producerFactory;
    private static JdbcTemplate jdbc;
    private final TelemetryNormalizationService normalizer = new TelemetryNormalizationService();
    private final List<ConcurrentMessageListenerContainer<String, TelemetryEvent>> containers = new ArrayList<>();

    @BeforeAll
    static void start() {
        var dataSource = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        Flyway.configure().dataSource(dataSource).defaultSchema("pulsestream_migrations").load().migrate();
        broker = new EmbeddedKafkaKraftBroker(1, 3, SINGLE, SCALED, FAILURE, CRASH);
        broker.afterPropertiesSet();
        producerFactory = new DefaultKafkaProducerFactory<>(Map.of(
                ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, broker.getBrokersAsString()),
                new StringSerializer(), new JacksonJsonSerializer<>());
    }

    @AfterAll
    static void stop() {
        if (producerFactory != null) producerFactory.destroy();
        if (broker != null) broker.destroy();
    }

    @BeforeEach
    void clean() {
        jdbc.execute("TRUNCATE platform.anomaly_decisions, platform.anomaly_reading_state, platform.anomaly_partition_state");
    }

    @AfterEach
    void stopConsumers() { containers.forEach(ConcurrentMessageListenerContainer::stop); }

    @Test
    void scaleOutScaleInRestartAndRebalanceMatchOneReplicaAcrossThreePartitions() throws Exception {
        var expected = new ConcurrentHashMap<String, List<String>>();
        var actual = new ConcurrentHashMap<String, List<String>>();
        var baseline = consumer(SINGLE, "single", expected);
        var first = consumer(SCALED, "scaled", actual);
        baseline.start();
        first.start();
        await(() -> assigned(baseline) == 3 && assigned(first) == 3);

        publishPhase(0);
        await(() -> actual.size() == 12 && expected.size() == 12);
        var second = consumer(SCALED, "scaled", actual);
        second.start();
        await(() -> assigned(first) > 0 && assigned(second) > 0 && assigned(first) + assigned(second) == 3);
        publishPhase(1);
        await(() -> actual.size() == 24 && expected.size() == 24);

        first.stop(); // Force the surviving replica to recover partitions from the other instance.
        await(() -> assigned(second) == 3);
        publishPhase(2);
        await(() -> actual.size() == 36 && expected.size() == 36);

        second.stop();
        var restarted = consumer(SCALED, "scaled", actual); // Fresh service objects, no retained Java state.
        restarted.start();
        await(() -> assigned(restarted) == 3);
        publishPhase(3);
        await(() -> actual.size() == 48 && expected.size() == 48);
        assertThat(actual).isEqualTo(expected);
        assertThat(actual.values().stream().filter(reasons -> !reasons.isEmpty()).count()).isEqualTo(36);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomaly_partition_state", Integer.class)).isEqualTo(6);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomaly_reading_state", Integer.class)).isEqualTo(24);
    }

    @Test
    void duplicateDeliveryAfterRestartUsesOriginalDecisionAndDoesNotRewindTheBaseline() throws Exception {
        var first = record(0, 1000, event("first", "tenant", "device", "temperature", "c", "20"));
        var spike = record(1, 2000, event("spike", "tenant", "device", "temperature", "c", "50"));
        var state = state(AnomalyDetectionProperties.defaults());
        assertThat(detect(state, first).anomalous()).isFalse();
        var original = detect(state, spike);
        assertThat(original.reasons()).containsExactly("value spike detected: changed by 150.0% from previous reading");
        var restarted = state(AnomalyDetectionProperties.defaults());
        assertThat(detect(restarted, spike)).isEqualTo(original);
        assertThat(detect(restarted, first).anomalous()).isFalse();
        assertThat(detect(restarted, record(2, 3000, event("next", "tenant", "device", "temperature", "c", "55")))
                .anomalous()).isFalse();

        // Two owners racing the same delivery commit one state transition and the same decision.
        var next = record(3, 4000, event("concurrent", "tenant", "device", "temperature", "c", "25"));
        try (var executor = Executors.newFixedThreadPool(2)) {
            var gate = new CountDownLatch(1);
            Callable<TelemetryAnomalyResult> delivery = () -> { gate.await(); return detect(state(AnomalyDetectionProperties.defaults()), next); };
            var a = executor.submit(delivery);
            var b = executor.submit(delivery);
            gate.countDown();
            assertThat(a.get(15, TimeUnit.SECONDS)).isEqualTo(b.get(15, TimeUnit.SECONDS));
        }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomaly_decisions", Integer.class)).isEqualTo(4);
        assertThatThrownBy(() -> detect(state, record(3, 4000, event("changed", "tenant", "device", "temperature", "c", "26"))))
                .isInstanceOf(AnomalyStateException.class).hasMessageContaining("changed");
    }

    @Test
    void tenantDeviceMetricAndUnitKeysAreIsolatedAndIncompatibleTemperatureCannotPoisonState() {
        var state = state(AnomalyDetectionProperties.defaults());
        assertThat(detect(state, record(0, 1000, event("a", "t:a", "b", "pressure", "bar", "20"))).anomalous()).isFalse();
        assertThat(detect(state, record(1, 1001, event("b", "t", "a:b", "pressure", "bar", "50"))).anomalous()).isFalse();
        assertThat(detect(state, record(2, 1002, event("c", "t:a", "b", "pressure", "kpa", "2000"))).anomalous()).isFalse();
        assertThat(detect(state, record(3, 1003, event("d", "other", "b", "pressure", "bar", "100"))).anomalous()).isFalse();
        assertThat(detect(state, record(4, 1004, event("e", "t:a", "b", "humidity", "%", "99"))).anomalous()).isFalse();
        assertThat(detect(state, record(5, 1005, event("f", "t:a", "b", "pressure", "bar", "50"))).anomalous()).isTrue();
        assertThat(detect(state, record(6, 1006, event("g", "t:a", "b", "temperature", "f", "212"))).severity())
                .isEqualTo(AnomalySeverity.CRITICAL);
        assertThat(detect(state, record(7, 1007, event("h", "t:a", "b", "temperature", "c", "20"))).anomalous()).isFalse();
        assertThat(detect(state, record(8, 1008, event("i", "t:a", "b", "temperature", null, "999"))).severity())
                .isEqualTo(AnomalySeverity.CRITICAL);
        assertThat(detect(state, record(9, 1009, event("j", "t:a", "b", "temperature", "c", "21"))).anomalous()).isFalse();
        assertThat(detect(state, record(10, 1010, event("missing", null, null, null, null, null))).severity())
                .isEqualTo(AnomalySeverity.CRITICAL);
    }

    @Test
    void streamTimeExpirationSurvivesRestartLateTimestampsAndFreesBoundedCapacity() {
        var properties = bounded(2, 2, Duration.ofSeconds(10));
        var state = state(properties);
        detect(state, record(0, 1000, event("a", "t", "a", "temperature", "c", "20")));
        detect(state, record(1, 2000, event("b", "t", "b", "temperature", "c", "20")));
        var c = record(2, 3000, event("c", "t", "c", "temperature", "c", "20"));
        assertThatThrownBy(() -> detect(state, c)).isInstanceOf(AnomalyStateException.class).hasMessageContaining("capacity");
        assertThat(jdbc.queryForObject("SELECT last_offset FROM platform.anomaly_partition_state", Long.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomaly_decisions", Integer.class)).isEqualTo(2);
        // Updating an existing key at capacity is permitted; expiry is inclusive at the retention boundary.
        detect(state, record(2, 3000, event("a-update", "t", "a", "temperature", "c", "21")));
        var recovered = state(properties);
        assertThat(detect(recovered, record(3, 13000, event("new-baseline", "t", "a", "temperature", "c", "50"))).anomalous()).isFalse();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomaly_reading_state", Integer.class)).isEqualTo(1);
        assertThat(detect(recovered, record(4, 1000, event("late", "t", "a", "temperature", "c", "51"))).anomalous()).isFalse();
        assertThat(jdbc.queryForObject("SELECT stream_time FROM platform.anomaly_partition_state", Long.class)).isEqualTo(13000);
        assertThat(jdbc.queryForObject("SELECT seen_at FROM platform.anomaly_reading_state", Long.class)).isEqualTo(13000);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomaly_decisions", Integer.class)).isEqualTo(2);
        assertThatThrownBy(() -> detect(recovered, record(0, 1000, event("a", "t", "a", "temperature", "c", "20"))))
                .isInstanceOf(AnomalyStateException.class).hasMessageContaining("predates");
    }

    @Test
    void mismatchedKeysMissingTimestampsAndMixedConfigurationFailBeforeAdvancingState() {
        var event = event("a", "tenant", "device", "temperature", "c", "20");
        var state = state(AnomalyDetectionProperties.defaults());
        assertThatThrownBy(() -> detect(state, new ConsumerRecord<>("raw", 0, 0, event.eventId(), event)))
                .isInstanceOf(AnomalyStateException.class).hasMessageContaining("ordering key");
        assertThatThrownBy(() -> detect(state, new ConsumerRecord<>("raw", 0, 0,
                TelemetryOrderingKey.of(event.tenantId(), event.payload().deviceId()), event)))
                .isInstanceOf(AnomalyStateException.class).hasMessageContaining("timestamp");
        detect(state, record(0, 1000, event));
        var other = state(bounded(1, 1, Duration.ofSeconds(1)));
        assertThatThrownBy(() -> detect(other, record(1, 2000, event)))
                .isInstanceOf(AnomalyStateException.class).hasMessageContaining("configuration differs");
        assertThat(jdbc.queryForObject("SELECT last_offset FROM platform.anomaly_partition_state", Long.class)).isZero();
    }

    @Test
    void databaseFailureStopsWithoutDeadLetterRoutingAndUncommittedRecordRecovers() throws Exception {
        var results = new ConcurrentHashMap<String, List<String>>();
        var properties = kafkaProperties("failure-recovery");
        var factory = new KafkaConsumerConfiguration().telemetryKafkaListenerContainerFactory(
                new KafkaConsumerConfiguration().telemetryConsumerFactory(properties), properties);
        var container = factory.createContainer(FAILURE);
        containers.add(container);
        var brokenJdbc = mock(JdbcTemplate.class);
        when(brokenJdbc.update(anyString(), org.mockito.ArgumentMatchers.<Object[]>any()))
                .thenThrow(new org.springframework.dao.DataAccessResourceFailureException("database unavailable"));
        var broken = new AnomalyStateService(brokenJdbc, new JdbcTransactionManager(jdbc.getDataSource()),
                AnomalyDetectionProperties.defaults(), new TelemetryAnomalyDetectionService());
        var deadLetter = mock(DeadLetterPublisher.class);
        var listener = new TelemetryEventConsumer(normalizer, broken,
                mock(AnomalyProcessingService.class), mock(TelemetryProcessingService.class), deadLetter);
        var attempted = new CountDownLatch(1);
        container.getContainerProperties().setMessageListener((MessageListener<String, TelemetryEvent>) record -> {
            try { listener.consumeTelemetryRecord(record); } finally { attempted.countDown(); }
        });
        container.start();
        await(() -> assigned(container) == 3);
        publish(FAILURE, null, event("recovery", "tenant", "device", "temperature", "c", "20"), KAFKA_TIME);
        assertThat(attempted.await(30, TimeUnit.SECONDS)).isTrue();
        await(() -> !container.isRunning());
        verifyNoInteractions(deadLetter);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomaly_partition_state", Integer.class)).isZero();
        var recovered = consumer(FAILURE, "failure-recovery", results);
        recovered.start();
        await(() -> results.containsKey("recovery"));
        assertThat(results.get("recovery")).isEmpty();
    }

    @Test
    void crashAfterStateCommitBeforeKafkaCommitRedeliversTheSameSpikeAfterRestart() throws Exception {
        var properties = kafkaProperties("state-commit-crash");
        var config = new KafkaConsumerConfiguration();
        var container = config.telemetryKafkaListenerContainerFactory(config.telemetryConsumerFactory(properties), properties)
                .createContainer(CRASH);
        containers.add(container);
        var state = state(AnomalyDetectionProperties.defaults());
        var crashed = new CountDownLatch(1);
        container.getContainerProperties().setMessageListener((MessageListener<String, TelemetryEvent>) record -> {
            var result = detect(state, record);
            if (record.value().eventId().equals("crash")) {
                assertThat(result.anomalous()).isTrue();
                crashed.countDown();
                throw new AnomalyStateException("Simulated termination after detection committed");
            }
        });
        container.start();
        await(() -> assigned(container) == 3);
        publish(CRASH, null, event("seed", "tenant", "device", "temperature", "c", "20"), KAFKA_TIME);
        publish(CRASH, null, event("crash", "tenant", "device", "temperature", "c", "50"), KAFKA_TIME + 1000);
        assertThat(crashed.await(30, TimeUnit.SECONDS)).isTrue();
        await(() -> !container.isRunning());

        var results = new ConcurrentHashMap<String, List<String>>();
        var restarted = consumer(CRASH, "state-commit-crash", results);
        restarted.start();
        await(() -> results.containsKey("crash"));
        assertThat(results).containsOnlyKeys("crash");
        assertThat(results.get("crash")).containsExactly("value spike detected: changed by 150.0% from previous reading");
        publish(CRASH, null, event("after-crash", "tenant", "device", "temperature", "c", "55"), KAFKA_TIME + 2000);
        await(() -> results.containsKey("after-crash"));
        assertThat(results.get("after-crash")).isEmpty();
    }

    private AnomalyStateService state(AnomalyDetectionProperties properties) {
        return new AnomalyStateService(jdbc, new JdbcTransactionManager(jdbc.getDataSource()), properties,
                new TelemetryAnomalyDetectionService(properties));
    }

    private AnomalyDetectionProperties bounded(int keys, int decisions, Duration retention) {
        return new AnomalyDetectionProperties(new BigDecimal("-40"), new BigDecimal("80"), "c",
                new BigDecimal("0.5"), retention, keys, decisions);
    }

    private TelemetryAnomalyResult detect(AnomalyStateService state, ConsumerRecord<String, TelemetryEvent> record) {
        return state.detect(normalizer.normalize(record.value()), record);
    }

    private ConsumerRecord<String, TelemetryEvent> record(long offset, long time, TelemetryEvent event) {
        String key = event.tenantId() == null ? "invalid" : TelemetryOrderingKey.of(event.tenantId(), event.payload().deviceId());
        return new ConsumerRecord<>("raw", 0, offset, time, TimestampType.CREATE_TIME, -1, -1, key, event,
                new RecordHeaders(), Optional.empty());
    }

    private TelemetryEvent event(String id, String tenant, String device, String metric, String unit, String value) {
        return new TelemetryEvent(id, tenant, "telemetry.reading", Instant.parse("2026-10-25T00:00:00Z"), "test", "1.0",
                new TelemetryPayload(device, "sensor", metric, value == null ? null : new BigDecimal(value), unit, "room"));
    }

    private TelemetryProcessorKafkaProperties kafkaProperties(String group) {
        var properties = new TelemetryProcessorKafkaProperties();
        properties.setBootstrapServers(broker.getBrokersAsString());
        properties.getConsumer().setGroupId(group);
        properties.getConsumer().getProperties().put("spring.json.use.type.headers", "false");
        properties.getConsumer().getProperties().put("session.timeout.ms", "6000");
        properties.getConsumer().getProperties().put("heartbeat.interval.ms", "1000");
        return properties;
    }

    private ConcurrentMessageListenerContainer<String, TelemetryEvent> consumer(
            String topic, String group, Map<String, List<String>> results) {
        var config = new KafkaConsumerConfiguration();
        var properties = kafkaProperties(group);
        var factory = config.telemetryKafkaListenerContainerFactory(config.telemetryConsumerFactory(properties), properties);
        var container = factory.createContainer(topic);
        container.setBeanName(group + "-" + containers.size());
        var normal = mock(TelemetryProcessingService.class);
        when(normal.process(any())).thenAnswer(call -> {
            TelemetryEvent event = call.getArgument(0);
            results.put(event.eventId(), List.of());
            return event;
        });
        var anomalous = mock(AnomalyProcessingService.class);
        when(anomalous.process(any(), any())).thenAnswer(call -> {
            TelemetryEvent event = call.getArgument(0);
            TelemetryAnomalyResult result = call.getArgument(1);
            results.put(event.eventId(), result.reasons());
            return null;
        });
        var listener = new TelemetryEventConsumer(normalizer, state(AnomalyDetectionProperties.defaults()), anomalous, normal,
                mock(DeadLetterPublisher.class));
        container.getContainerProperties().setMessageListener((MessageListener<String, TelemetryEvent>) listener::consumeTelemetryRecord);
        containers.add(container);
        return container;
    }

    private void publishPhase(int phase) throws Exception {
        // Two tenants with identical device IDs; choose keys that exercise every partition.
        Set<Integer> partitions = new HashSet<>();
        for (int device = 0; device < 6; device++) {
            for (String tenant : List.of("tenant-a", "tenant-b")) {
                String key = TelemetryOrderingKey.of(tenant, "device-" + device);
                int partition = org.apache.kafka.common.utils.Utils.toPositive(
                        org.apache.kafka.common.utils.Utils.murmur2(key.getBytes(java.nio.charset.StandardCharsets.UTF_8))) % 3;
                partitions.add(partition);
                String[] values = tenant.equals("tenant-a") ? new String[] {"20", "50", "20", "50"}
                        : new String[] {"60", "25", "60", "25"};
                var event = event(tenant + "-" + device + "-" + phase, tenant, "device-" + device, "temperature", "c", values[phase]);
                publish(SINGLE, null, event, KAFKA_TIME + phase * 1000L);
                publish(SCALED, null, event, KAFKA_TIME + phase * 1000L);
            }
        }
        assertThat(partitions).containsExactlyInAnyOrder(0, 1, 2);
    }

    private void publish(String topic, Integer partition, TelemetryEvent event, long timestamp) throws Exception {
        try (var producer = producerFactory.createProducer()) {
            producer.send(new ProducerRecord<>(topic, partition, timestamp,
                    TelemetryOrderingKey.of(event.tenantId(), event.payload().deviceId()), event)).get(15, TimeUnit.SECONDS);
        }
    }

    private int assigned(ConcurrentMessageListenerContainer<?, ?> container) {
        var assigned = container.getAssignedPartitions();
        return assigned == null ? 0 : assigned.size();
    }

    private void await(BooleanSupplier condition) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(40);
        while (!condition.getAsBoolean() && System.nanoTime() < deadline) Thread.sleep(50);
        assertThat(condition.getAsBoolean()).as("Kafka processing/assignment completed before timeout").isTrue();
    }
}
