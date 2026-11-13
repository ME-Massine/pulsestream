package com.pulsestream.processor.service;

import com.pulsestream.processor.config.*;
import com.pulsestream.processor.consumer.TelemetryEventConsumer;
import com.pulsestream.processor.model.*;
import com.pulsestream.processor.repository.*;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import java.math.BigDecimal;
import java.time.Duration;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.BooleanSupplier;
import org.apache.kafka.clients.admin.Admin;
import org.apache.kafka.clients.consumer.*;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.header.internals.RecordHeaders;
import org.apache.kafka.common.record.TimestampType;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.kafka.core.*;
import org.springframework.kafka.listener.*;
import org.springframework.kafka.test.EmbeddedKafkaKraftBroker;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.json.JsonMapper;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Mandatory real PostgreSQL and Kafka checks for durable outcomes and ambiguous sends. */
@Testcontainers
class DeliveryIntegrationTest {
    @Container static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16");
    private static EmbeddedKafkaKraftBroker broker;
    private static DefaultKafkaProducerFactory<String, String> producer;
    private static org.springframework.context.annotation.AnnotationConfigApplicationContext producerContext;
    private static JdbcTemplate jdbc;
    private static JdbcTransactionManager manager;
    private final ObjectMapper mapper = JsonMapper.builder().build();
    private TelemetryProcessorKafkaProperties properties;
    private SimpleMeterRegistry metrics;
    private DeliveryOutbox outbox;
    private TelemetryDeliveryService delivery;
    private KafkaTemplate<String, String> kafka;
    private String raw;

    @BeforeAll static void start() {
        var ds = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new JdbcTemplate(ds);
        manager = new JdbcTransactionManager(ds);
        Flyway.configure().dataSource(ds).defaultSchema("pulsestream_migrations").load().migrate();
        broker = new EmbeddedKafkaKraftBroker(1, 1, "telemetry.events.processed", "telemetry.events.anomalies", "telemetry.events.dlq");
        broker.afterPropertiesSet();
        producerContext = new org.springframework.context.annotation.AnnotationConfigApplicationContext();
        var kafkaProperties = new TelemetryProcessorKafkaProperties();
        kafkaProperties.setBootstrapServers(broker.getBrokersAsString());
        producerContext.registerBean(TelemetryProcessorKafkaProperties.class, () -> kafkaProperties);
        producerContext.registerBean(JsonMapper.class, () -> JsonMapper.builder().build());
        producerContext.register(KafkaProducerConfiguration.class);
        producerContext.refresh();
        @SuppressWarnings("unchecked") var configured = (DefaultKafkaProducerFactory<String, String>)
                producerContext.getBean("outboxProducerFactory", DefaultKafkaProducerFactory.class);
        producer = configured;
    }

    @AfterAll static void stop() {
        if (producerContext != null) producerContext.close();
        if (broker != null) broker.destroy();
    }

    @BeforeEach void clean() {
        jdbc.execute("DROP TRIGGER IF EXISTS fail_marker ON platform.delivery_outbox");
        jdbc.execute("DROP TRIGGER IF EXISTS fail_enqueue ON platform.delivery_outbox");
        jdbc.execute("DROP TRIGGER IF EXISTS fail_commit ON platform.delivery_outbox");
        jdbc.execute("TRUNCATE platform.delivery_outbox, platform.processing_receipts, platform.processed_telemetry, platform.anomalies, "
                + "platform.anomaly_decisions, platform.anomaly_reading_state, platform.anomaly_partition_state RESTART IDENTITY");
        raw = "delivery-" + UUID.randomUUID();
        properties = new TelemetryProcessorKafkaProperties();
        properties.setBootstrapServers(broker.getBrokersAsString());
        properties.getTopics().setRaw(raw);
        metrics = new SimpleMeterRegistry();
        outbox = spy(new DeliveryOutbox(jdbc));
        kafka = new KafkaTemplate<>(producer);
        delivery = service(outbox, mapper);
    }

    private TelemetryDeliveryService service(DeliveryOutbox writer, ObjectMapper json) {
        var normalizer = new TelemetryNormalizationService();
        var state = new AnomalyStateService(jdbc, manager, AnomalyDetectionProperties.defaults(), new TelemetryAnomalyDetectionService());
        var named = new NamedParameterJdbcTemplate(jdbc);
        return new TelemetryDeliveryService(manager, writer, normalizer, state,
                new TelemetryProcessingService(new ProcessedTelemetryPersistenceService(new ProcessedTelemetryWriteRepository(named))),
                new AnomalyProcessingService(new AnomalyPersistenceService(new AnomalyRepository(named, mapper), metrics)), properties, json);
    }

    private OutboxDispatcher dispatcher(KafkaTemplate<String, String> sender) {
        return new OutboxDispatcher(jdbc, manager, sender, properties, metrics);
    }

    @Test void normalAndAnomalyCommitBeforeKafkaAndRestartDispatchesStoredPayloads() {
        delivery.consume(record(0, "normal", "20"));
        delivery.consume(record(1, "anomaly", "100"));
        assertThat(count("processed_telemetry")).isEqualTo(1);
        assertThat(count("anomalies")).isEqualTo(1);
        assertThat(count("delivery_outbox")).isEqualTo(2);
        assertThat(metrics.get("pulsestream.anomaly.persistence").tag("outcome", "success").counter().count()).isEqualTo(1);
        var restarted = service(new DeliveryOutbox(jdbc), mapper);
        restarted.consume(record(0, "normal", "20"));
        dispatcher(kafka).dispatch();
        assertThat(pending()).isZero();
        for (var row : jdbc.queryForList("SELECT destination, payload FROM platform.delivery_outbox")) {
            String schema = row.get("destination").toString().endsWith("anomalies") ? "anomaly" : "processed";
            com.pulsestream.processor.contract.ContractAssertions.valid("schemas/" + schema + "/v1.schema.json", row.get("payload").toString());
        }
        assertThat(read("telemetry.events.processed", "normal", 1).getFirst()).contains("telemetry.processed");
        assertThat(read("telemetry.events.anomalies", "anomaly", 1).getFirst()).contains("telemetry.anomaly");
    }

    @Test void enqueueFailureRollsBackProjectionReceiptAndDetectionAndDoesNotCountSuccess() {
        doThrow(new DataAccessResourceFailureException("database unavailable")).when(outbox)
                .enqueue(anyLong(), anyString(), any(), anyString());
        assertThatThrownBy(() -> delivery.consume(record(0, "failure", "100")))
                .isInstanceOf(DataAccessResourceFailureException.class);
        for (String table : List.of("anomalies", "processing_receipts", "delivery_outbox", "anomaly_decisions", "anomaly_partition_state")) {
            assertThat(count(table)).as(table).isZero();
        }
        assertThat(metrics.get("pulsestream.anomaly.persistence").tag("outcome", "success").counter().count()).isZero();
        service(new DeliveryOutbox(jdbc), mapper).consume(record(0, "failure", "100"));
        assertThat(pending()).isEqualTo(1);
    }

    @Test void databaseConstraintFailureStopsAndRollsBackInsteadOfBecomingDlq() {
        var original = record(0, "too-long-" + "x".repeat(50), "20");
        assertThatThrownBy(() -> delivery.consume(original)).isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        assertThat(count("processing_receipts")).isZero();
        assertThat(count("anomaly_decisions")).isZero();
        assertThat(pending()).isZero();
    }

    @Test void commitFailureRollsBackTheCompleteOutcomeAndRetrySucceeds() {
        jdbc.execute("CREATE OR REPLACE FUNCTION platform.reject_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'commit unavailable'; END $$");
        jdbc.execute("CREATE CONSTRAINT TRIGGER fail_commit AFTER INSERT ON platform.delivery_outbox DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION platform.reject_commit()");
        var record = record(0, "commit-failure", "100");
        try {
            assertThatThrownBy(() -> delivery.consume(record)).isInstanceOf(org.springframework.transaction.TransactionException.class);
            for (String table : List.of("anomalies", "processing_receipts", "delivery_outbox", "anomaly_decisions")) {
                assertThat(count(table)).as(table).isZero();
            }
            assertThat(metrics.get("pulsestream.anomaly.persistence").tag("outcome", "success").counter().count()).isZero();
        } finally { jdbc.execute("DROP TRIGGER fail_commit ON platform.delivery_outbox"); }
        delivery.consume(record);
        assertThat(pending()).isEqualTo(1);
    }

    @Test void concurrentRedeliveryCommitsOnlyOneOutcomeAndRejectsChangedHeaders() throws Exception {
        var record = record(0, "racing", "20");
        record.headers().add("nullable", null);
        try (var executor = Executors.newFixedThreadPool(2)) {
            var gate = new CountDownLatch(1);
            Callable<Void> attempt = () -> { gate.await(); delivery.consume(record); return null; };
            var a = executor.submit(attempt);
            var b = executor.submit(attempt);
            gate.countDown();
            a.get(15, TimeUnit.SECONDS);
            b.get(15, TimeUnit.SECONDS);
        }
        assertThat(count("processing_receipts")).isEqualTo(1);
        assertThat(pending()).isEqualTo(1);
        assertThat(count("processed_telemetry")).isEqualTo(1);
        record.headers().add(ReplayHeaders.REPLAY, "true".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        assertThatThrownBy(() -> delivery.consume(record)).hasMessageContaining("coordinate changed");
    }

    @Test void failedPartitionDoesNotBlockIndependentPartitionAndInterruptedSendIsRetained() {
        delivery.consume(record(0, "blocked-partition", "20"));
        var other = record(0, "other-partition", "21");
        delivery.consume(new ConsumerRecord<>(raw, 1, 0, other.timestamp(), other.timestampType(), 0, 0,
                other.key(), other.value(), other.headers(), Optional.empty()));
        var sender = sender(CompletableFuture.completedFuture(null));
        when(sender.send(anyString(), eq("blocked-partition"), anyString()))
                .thenReturn(CompletableFuture.failedFuture(new IllegalStateException("failed partition")));
        dispatcher(sender).dispatch();
        assertThat(pending()).isEqualTo(1);
        verify(sender).send(anyString(), eq("other-partition"), anyString());
        due();
        var interrupted = sender(new CompletableFuture<>());
        Thread.currentThread().interrupt();
        try {
            dispatcher(interrupted).dispatch();
            assertThat(Thread.currentThread().isInterrupted()).isTrue();
            assertThat(pending()).isEqualTo(1);
        } finally { Thread.interrupted(); }
    }

    @Test void unavailableDatabaseReportsUnknownBacklogInsteadOfZeroAndInvalidRecordsStop() {
        var unavailable = mock(JdbcTemplate.class);
        when(unavailable.queryForObject(anyString(), eq(Double.class)))
                .thenThrow(new DataAccessResourceFailureException("database offline"));
        var registry = new SimpleMeterRegistry();
        new OutboxDispatcher(unavailable, manager, kafka, properties, registry);
        assertThat(registry.get("pulsestream.delivery.pending").gauge().value()).isNaN();
        assertThatThrownBy(() -> delivery.consume(null)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> delivery.consume(new ConsumerRecord<>(raw, 0, 0, "key", null)))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test void dlqIsDurableAndCompoundFailuresCannotSilentlyAcknowledge() {
        var event = new TelemetryEvent("invalid", "tenant", "telemetry.reading", Instant.now(), "test", "1.0", null);
        var record = record(0, event, new RecordHeaders());
        delivery.consume(record);
        assertThat(count("processing_receipts")).isEqualTo(1);
        assertThat(count("anomaly_decisions")).isZero();
        assertThat(jdbc.queryForObject("SELECT payload FROM platform.delivery_outbox", String.class))
                .contains("telemetry-processor", "telemetry payload must not be null");
        var failed = sender(CompletableFuture.failedFuture(new IllegalStateException("broker down")));
        dispatcher(failed).dispatch();
        assertThat(pending()).isEqualTo(1);
        delivery.consume(record); // Redelivery cannot enqueue another DLQ envelope.
        assertThat(count("delivery_outbox")).isEqualTo(1);
        due();
        dispatcher(kafka).dispatch();
        var dlqJson = read("telemetry.events.dlq", "invalid", 1).getFirst();
        com.pulsestream.processor.contract.ContractAssertions.valid("schemas/dead-letter/v1.schema.json", dlqJson);

        doThrow(new DataAccessResourceFailureException("DB down too")).when(outbox)
                .enqueue(anyLong(), anyString(), any(), anyString());
        assertThatThrownBy(() -> delivery.consume(record(1, event, new RecordHeaders())))
                .isInstanceOf(DataAccessResourceFailureException.class);
        assertThat(count("processing_receipts")).isEqualTo(1);
    }

    @Test void serializationFailureRollsBackNormalOutcomeAndDlqFallbackIsValidJson() {
        var brokenMapper = mock(ObjectMapper.class);
        when(brokenMapper.writeValueAsString(any())).thenThrow(new IllegalStateException("serializer failed"));
        var broken = service(outbox, brokenMapper);
        assertThatThrownBy(() -> broken.consume(record(0, "serialization", "20"))).hasMessage("serializer failed");
        assertThat(count("processed_telemetry")).isZero();
        assertThat(count("anomaly_decisions")).isZero();
        var invalid = new TelemetryEvent("fallback", "tenant", "telemetry.reading", Instant.now(), "test", "1.0", null);
        broken.consume(record(0, invalid, new RecordHeaders()));
        assertThat(mapper.readValue(jdbc.queryForObject("SELECT payload FROM platform.delivery_outbox", String.class), DeadLetterEvent.class).event())
                .isEqualTo(invalid);
    }

    @Test void timeoutAndRetryAreVisibleAndDoNotAllowLaterOffsetsToOvertake() {
        delivery.consume(record(0, "timeout", "20"));
        delivery.consume(record(1, "later", "21"));
        properties.getProducer().setPublishTimeout(Duration.ofMillis(10));
        var blocked = sender(new CompletableFuture<>());
        var dispatcher = dispatcher(blocked);
        dispatcher.dispatch();
        dispatcher.dispatch(); // Backoff has not expired.
        verify(blocked, times(1)).send(anyString(), anyString(), anyString());
        assertThat(pending()).isEqualTo(2);
        assertThat(metrics.get("pulsestream.delivery.failed.pending").gauge().value()).isEqualTo(1);
        assertThat(metrics.get("pulsestream.delivery.pending").gauge().value()).isEqualTo(2);
        assertThat(metrics.get("pulsestream.delivery.oldest.pending.seconds").gauge().value()).isGreaterThanOrEqualTo(0);
        due();
        properties.getProducer().setPublishTimeout(Duration.ofSeconds(5));
        dispatcher(kafka).dispatch();
        assertThat(pending()).isZero();
        assertThat(metrics.get("pulsestream.delivery.retries").counter().count()).isEqualTo(1);
        assertThat(metrics.get("pulsestream.delivery.recovered").counter().count()).isEqualTo(1);
        assertThat(metrics.get("pulsestream.delivery.failures").counter().count()).isEqualTo(1);
    }

    @Test void crashAfterBrokerAckBeforeDatabaseMarkerCausesDocumentedDuplicateAndRecovers() {
        delivery.consume(record(0, "ambiguous", "20"));
        jdbc.execute("""
                CREATE OR REPLACE FUNCTION platform.reject_marker() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN RAISE EXCEPTION 'simulated crash before marker'; END $$
                """);
        jdbc.execute("CREATE TRIGGER fail_marker BEFORE UPDATE ON platform.delivery_outbox FOR EACH ROW EXECUTE FUNCTION platform.reject_marker()");
        assertThatThrownBy(() -> dispatcher(kafka).dispatch()).isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThat(pending()).isEqualTo(1);
        jdbc.execute("DROP TRIGGER fail_marker ON platform.delivery_outbox");
        dispatcher(kafka).dispatch();
        assertThat(pending()).isZero();
        var values = read("telemetry.events.processed", "ambiguous", 2);
        assertThat(values).hasSize(2);
        assertThat(values.getFirst()).isEqualTo(values.getLast());
        assertThat(count("processed_telemetry")).isEqualTo(1);
    }

    @Test void crashBeforeSendAndConcurrentReplicaDispatchReleaseLocksWithoutLosingWork() throws Exception {
        delivery.consume(record(0, "concurrent", "20"));
        var entered = new CountDownLatch(1);
        var release = new CountDownLatch(1);
        var blocked = sender(new CompletableFuture<>());
        when(blocked.send(anyString(), anyString(), anyString())).thenAnswer(call -> {
            entered.countDown();
            release.await(10, TimeUnit.SECONDS);
            throw new AssertionError("process terminated before send");
        });
        try (var executor = Executors.newSingleThreadExecutor()) {
            var first = executor.submit(() -> dispatcher(blocked).dispatch());
            assertThat(entered.await(10, TimeUnit.SECONDS)).isTrue();
            dispatcher(kafka).dispatch(); // Another replica cannot own the same partition.
            assertThat(pending()).isEqualTo(1);
            release.countDown();
            assertThatThrownBy(() -> first.get(10, TimeUnit.SECONDS)).hasCauseInstanceOf(AssertionError.class);
        }
        dispatcher(kafka).dispatch();
        assertThat(pending()).isZero();
        assertThat(read("telemetry.events.processed", "concurrent", 1)).hasSize(1);
    }

    @Test void duplicatesReplayTenantProtectionAndFingerprintGuard() {
        var first = record(0, "duplicate", "20");
        delivery.consume(first);
        delivery.consume(first);
        delivery.consume(record(1, "duplicate", "22"));
        assertThat(count("processed_telemetry")).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT value FROM platform.processed_telemetry", BigDecimal.class)).isEqualByComparingTo("20");
        var headers = new RecordHeaders().add(ReplayHeaders.REPLAY, "true".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        delivery.consume(record(2, record(2, "duplicate", "24").value(), headers));
        assertThat(jdbc.queryForObject("SELECT value FROM platform.processed_telemetry", BigDecimal.class)).isEqualByComparingTo("24");
        assertThat(count("delivery_outbox")).isEqualTo(3);
        assertThatThrownBy(() -> delivery.consume(record(0, "duplicate", "99"))).hasMessageContaining("coordinate changed");
        var event = first.value();
        var foreign = new TelemetryEvent(event.eventId(), "other-tenant", event.eventType(), event.timestamp(), event.source(), event.version(), event.payload());
        assertThatThrownBy(() -> delivery.consume(record(3, foreign, headers)))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        assertThat(count("processing_receipts")).isEqualTo(3);
    }

    @Test void listenerOffsetsRemainUncommittedOnFailureAndRecoverCommittedOutcomeAfterCrash() throws Exception {
        broker.addTopics(raw);
        var event = record(0, "offset", "20").value();
        kafka.send(raw, TelemetryOrderingKey.of(event.tenantId(), event.payload().deviceId()), mapper.writeValueAsString(event))
                .get(10, TimeUnit.SECONDS);
        properties.getConsumer().setGroupId(raw);
        var config = new KafkaConsumerConfiguration();
        var factory = config.telemetryKafkaListenerContainerFactory(config.telemetryConsumerFactory(properties), properties);
        doThrow(new DataAccessResourceFailureException("db down")).when(outbox).enqueue(anyLong(), anyString(), any(), anyString());
        var failed = factory.createContainer(raw);
        failed.getContainerProperties().setMessageListener((MessageListener<String, TelemetryEvent>) delivery::consume);
        failed.start();
        try {
            await(() -> !failed.isRunning());
            assertThat(committed()).isEqualTo(0);
            assertThat(count("processing_receipts")).isZero();
        } finally { failed.stop(); }
        var restarted = service(new DeliveryOutbox(jdbc), mapper);
        var crash = factory.createContainer(raw);
        crash.getContainerProperties().setMessageListener((MessageListener<String, TelemetryEvent>) record -> {
            restarted.consume(record);
            throw new IllegalStateException("process crash after database commit");
        });
        crash.start();
        try {
            await(() -> !crash.isRunning());
            assertThat(committed()).isZero();
            assertThat(count("processing_receipts")).isEqualTo(1);
            assertThat(pending()).isEqualTo(1);
        } finally { crash.stop(); }
        var recovered = factory.createContainer(raw);
        recovered.getContainerProperties().setMessageListener((MessageListener<String, TelemetryEvent>) new TelemetryEventConsumer(restarted)::consumeTelemetryRecord);
        recovered.start();
        try {
            await(() -> committed() == 1);
            assertThat(count("processing_receipts")).isEqualTo(1);
            assertThat(count("processed_telemetry")).isEqualTo(1);
        } finally { recovered.stop(); }
        dispatcher(kafka).dispatch();
        assertThat(pending()).isZero();
    }

    private long committed() {
        try (var admin = Admin.create(Map.of("bootstrap.servers", broker.getBrokersAsString()))) {
            var offsets = admin.listConsumerGroupOffsets(raw).partitionsToOffsetAndMetadata().get(5, TimeUnit.SECONDS);
            var offset = offsets.get(new TopicPartition(raw, 0));
            return offset == null ? 0 : offset.offset();
        } catch (Exception ex) { throw new IllegalStateException(ex); }
    }

    private KafkaTemplate<String, String> sender(CompletableFuture<org.springframework.kafka.support.SendResult<String, String>> result) {
        @SuppressWarnings("unchecked") KafkaTemplate<String, String> sender = mock(KafkaTemplate.class);
        when(sender.send(anyString(), anyString(), anyString())).thenReturn(result);
        return sender;
    }

    private ConsumerRecord<String, TelemetryEvent> record(long offset, String id, String value) {
        return record(offset, new TelemetryEvent(id, "tenant", "telemetry.reading", Instant.parse("2026-01-01T00:00:00Z"), "test", "1.0",
                new TelemetryPayload("device", "sensor", "temperature", new BigDecimal(value), "c", "room")), new RecordHeaders());
    }

    private ConsumerRecord<String, TelemetryEvent> record(long offset, TelemetryEvent event, org.apache.kafka.common.header.Headers headers) {
        return new ConsumerRecord<>(raw, 0, offset, 1000 + offset, TimestampType.CREATE_TIME, 0, 0,
                TelemetryOrderingKey.of(event.tenantId(), "device"), event, headers, Optional.empty());
    }

    private int count(String table) { return jdbc.queryForObject("SELECT count(*) FROM platform." + table, Integer.class); }
    private int pending() { return jdbc.queryForObject("SELECT count(*) FROM platform.delivery_outbox WHERE delivered_at IS NULL", Integer.class); }
    private void due() { jdbc.update("UPDATE platform.delivery_outbox SET next_attempt_at = now() - interval '1 second'"); }

    private List<String> read(String topic, String key, int expected) {
        var values = new ArrayList<String>();
        try (var consumer = new KafkaConsumer<String, String>(Map.of("bootstrap.servers", broker.getBrokersAsString(),
                "group.id", UUID.randomUUID().toString(), "auto.offset.reset", "earliest", "enable.auto.commit", false),
                new StringDeserializer(), new StringDeserializer())) {
            consumer.subscribe(List.of(topic));
            long end = System.nanoTime() + Duration.ofSeconds(15).toNanos();
            while (values.size() < expected && System.nanoTime() < end) {
                for (var record : consumer.poll(Duration.ofMillis(100))) if (key.equals(record.key())) values.add(record.value());
            }
        }
        assertThat(values).hasSize(expected);
        return values;
    }

    private void await(BooleanSupplier condition) throws Exception {
        long end = System.nanoTime() + Duration.ofSeconds(30).toNanos();
        while (!condition.getAsBoolean() && System.nanoTime() < end) Thread.sleep(100);
        assertThat(condition.getAsBoolean()).isTrue();
    }
}
