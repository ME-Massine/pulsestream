package com.pulsestream.processor.consumer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;

import com.pulsestream.processor.config.KafkaConsumerConfiguration;
import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.exception.TelemetryPublishingException;
import com.pulsestream.processor.model.DeadLetterEvent;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.service.DlqReplayPartitionRange;
import com.pulsestream.processor.service.DlqReplayService;
import com.pulsestream.processor.service.DlqReplaySession;
import com.pulsestream.processor.service.ReplayEventPublisher;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;
import org.apache.kafka.clients.admin.Admin;
import org.apache.kafka.clients.admin.AdminClientConfig;
import org.apache.kafka.clients.consumer.OffsetAndMetadata;
import org.apache.kafka.clients.producer.Producer;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.kafka.config.ConcurrentKafkaListenerContainerFactory;
import org.springframework.kafka.core.ConsumerFactory;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.listener.ConcurrentMessageListenerContainer;
import org.springframework.kafka.listener.MessageListener;
import org.springframework.kafka.support.serializer.JsonSerializer;
import org.springframework.kafka.test.EmbeddedKafkaKraftBroker;
import org.springframework.kafka.test.utils.KafkaTestUtils;

/**
 * Container-level proof of the #124 no-data-loss policy and #125 trigger-time replay boundary.
 * <p>
 * A single DLQ record is produced to an embedded broker and consumed through the real
 * {@code dlqKafkaListenerContainerFactory}. The replay publisher fails on the first attempt and
 * succeeds on the second. The test asserts that:
 * <ul>
 *   <li>a failed republish stops the container without committing the record's offset, so the
 *       record remains eligible for redelivery, and</li>
 *   <li>after restart the record is redelivered and the offset only advances once the republish
 *       succeeds.</li>
 * </ul>
 */
class DeadLetterReplayRedeliveryTest {

    private static final String DLQ_TOPIC = "telemetry.events.dlq";
    private static final String DLQ_GROUP = "telemetry-processor-dlq-replay";
    private static final TopicPartition PARTITION = new TopicPartition(DLQ_TOPIC, 0);

    private static final String BOUNDARY_TOPIC = "telemetry.events.dlq.boundary-test";
    private static final String BOUNDARY_GROUP = "telemetry-processor-dlq-boundary-test";
    private static final TopicPartition BOUNDARY_PARTITION = new TopicPartition(BOUNDARY_TOPIC, 0);

    private static EmbeddedKafkaKraftBroker broker;

    @BeforeAll
    static void startBroker() {
        broker = new EmbeddedKafkaKraftBroker(1, 1, DLQ_TOPIC, BOUNDARY_TOPIC);
        broker.afterPropertiesSet();
    }

    @AfterAll
    static void stopBroker() {
        broker.destroy();
    }

    @Test
    @DisplayName("failed republish keeps the DLQ record redeliverable; offset advances only after success")
    void failedRepublishStaysRedeliverableAndOffsetAdvancesOnlyAfterSuccess() throws Exception {
        AtomicInteger publishAttempts = new AtomicInteger();
        ReplayEventPublisher publisher = mock(ReplayEventPublisher.class);
        doAnswer(invocation -> {
            if (publishAttempts.incrementAndGet() == 1) {
                throw new TelemetryPublishingException("raw topic unavailable", null);
            }
            return null;
        }).when(publisher).publish(any());

        // Select evt-001 for replay so the consumer republishes it (replay is selective, #125).
        DlqReplaySession replaySession = new DlqReplaySession();
        replaySession.begin(
                Set.of("evt-001"),
                Map.of(PARTITION, new DlqReplayPartitionRange(0, 1))
        );
        DeadLetterEventConsumer consumer = new DeadLetterEventConsumer(
                publisher,
                replaySession,
                mock(DlqReplayService.class)
        );
        ConcurrentMessageListenerContainer<String, DeadLetterEvent> container =
                replayContainer(consumer, DLQ_TOPIC, DLQ_GROUP);

        produceDeadLetterEvent(DLQ_TOPIC);

        // Phase 1: first republish fails -> container stops, offset not committed.
        container.start();
        waitUntil(() -> publishAttempts.get() >= 1, "first republish attempt");
        waitUntil(() -> !container.isRunning(), "container stopped after failed republish");

        assertThat(publishAttempts.get()).isEqualTo(1);
        assertThat(container.isRunning()).isFalse();
        assertThat(committedOffset(DLQ_GROUP, PARTITION))
                .as("offset must not advance on a failed republish")
                .isEqualTo(-1L);

        // Phase 2: operator restarts -> record is redelivered, succeeds, offset advances.
        container.start();
        waitUntil(() -> publishAttempts.get() >= 2, "redelivered republish attempt");
        waitUntil(() -> committedOffset(DLQ_GROUP, PARTITION) == 1L, "offset committed after successful republish");

        assertThat(publishAttempts.get()).isEqualTo(2);
        assertThat(committedOffset(DLQ_GROUP, PARTITION))
                .as("offset advances only after a successful republish")
                .isEqualTo(1L);

        container.stop();
    }

    @Test
    @DisplayName("a matching DLQ event appended during replay should not extend the trigger-time boundary")
    void appendedMatchingEventShouldNotBeReplayedInTheSameRun() throws Exception {
        long originalOffset = produceDeadLetterEvent(BOUNDARY_TOPIC);
        AtomicInteger publishAttempts = new AtomicInteger();
        AtomicInteger handledRecords = new AtomicInteger();
        ReplayEventPublisher publisher = mock(ReplayEventPublisher.class);
        doAnswer(invocation -> {
            publishAttempts.incrementAndGet();
            produceDeadLetterEvent(BOUNDARY_TOPIC);
            return null;
        }).when(publisher).publish(any());

        DlqReplaySession replaySession = new DlqReplaySession();
        replaySession.begin(
                Set.of("evt-001"),
                Map.of(
                        BOUNDARY_PARTITION,
                        new DlqReplayPartitionRange(originalOffset, originalOffset + 1)
                )
        );
        DlqReplayService replayService = mock(DlqReplayService.class);
        doAnswer(invocation -> {
            handledRecords.incrementAndGet();
            return null;
        }).when(replayService).onReplayRecordProcessed(any(), anyLong());
        DeadLetterEventConsumer consumer = new DeadLetterEventConsumer(
                publisher,
                replaySession,
                replayService
        );
        ConcurrentMessageListenerContainer<String, DeadLetterEvent> container =
                replayContainer(consumer, BOUNDARY_TOPIC, BOUNDARY_GROUP);

        container.start();
        waitUntil(() -> handledRecords.get() >= 2, "original and appended DLQ records handled");

        assertThat(publishAttempts.get())
                .as("only the record inside the trigger-time boundary is replayed")
                .isEqualTo(1);

        container.stop();
    }

    private ConcurrentMessageListenerContainer<String, DeadLetterEvent> replayContainer(
            DeadLetterEventConsumer consumer,
            String topic,
            String groupId
    ) {
        TelemetryProcessorKafkaProperties properties = new TelemetryProcessorKafkaProperties();
        properties.setBootstrapServers(broker.getBrokersAsString());
        properties.getConsumer().setDlqGroupId(groupId);
        properties.getConsumer().setKeyDeserializer(StringDeserializer.class.getName());
        properties.getConsumer().setAutoOffsetReset("earliest");
        properties.getConsumer().setConcurrency(1);
        properties.getTopics().setDlq(topic);

        KafkaConsumerConfiguration configuration = new KafkaConsumerConfiguration();
        ConsumerFactory<String, DeadLetterEvent> consumerFactory =
                configuration.dlqConsumerFactory(properties);
        ConcurrentKafkaListenerContainerFactory<String, DeadLetterEvent> factory =
                configuration.dlqKafkaListenerContainerFactory(consumerFactory, properties);

        // Build the container from the real factory so its CommonContainerStoppingErrorHandler applies.
        ConcurrentMessageListenerContainer<String, DeadLetterEvent> container =
                factory.createContainer(topic);
        container.getContainerProperties().setGroupId(groupId);
        container.getContainerProperties().setMessageListener(
                (MessageListener<String, DeadLetterEvent>) record ->
                        consumer.consumeDeadLetterEvent(record));
        container.setBeanName("dlq-replay-redelivery-test");
        return container;
    }

    private long produceDeadLetterEvent(String topic) throws Exception {
        Map<String, Object> producerProps = KafkaTestUtils.producerProps(broker);
        producerProps.put("key.serializer", StringSerializer.class);
        producerProps.put("value.serializer", JsonSerializer.class);
        // Consumers rely on VALUE_DEFAULT_TYPE (producers are separate services), not type headers.
        producerProps.put(JsonSerializer.ADD_TYPE_INFO_HEADERS, false);

        try (Producer<String, DeadLetterEvent> producer =
                new DefaultKafkaProducerFactory<String, DeadLetterEvent>(producerProps).createProducer()) {
            return producer.send(new ProducerRecord<>(topic, "evt-001", deadLetterEvent())).get().offset();
        }
    }

    private long committedOffset(String groupId, TopicPartition partition) {
        try (Admin admin = Admin.create(Map.of(
                AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, broker.getBrokersAsString()))) {
            Map<TopicPartition, OffsetAndMetadata> offsets =
                    admin.listConsumerGroupOffsets(groupId).partitionsToOffsetAndMetadata().get();
            OffsetAndMetadata offsetAndMetadata = offsets.get(partition);
            return offsetAndMetadata == null ? -1L : offsetAndMetadata.offset();
        } catch (Exception ex) {
            throw new IllegalStateException("Failed to read committed offset", ex);
        }
    }

    private static void waitUntil(BooleanSupplier condition, String description) throws InterruptedException {
        long deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(30);
        while (System.nanoTime() < deadline) {
            if (condition.getAsBoolean()) {
                return;
            }
            Thread.sleep(100);
        }
        throw new AssertionError("Timed out waiting for: " + description);
    }

    private static DeadLetterEvent deadLetterEvent() {
        TelemetryEvent event = new TelemetryEvent(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                Instant.parse("2026-03-31T12:00:00Z"),
                "sensor-gateway",
                "1.0",
                new TelemetryPayload(
                        "sensor-1042",
                        "temperature-sensor",
                        "temperature",
                        new BigDecimal("28.4"),
                        "C",
                        "zone-a"
                )
        );

        return new DeadLetterEvent(
                event, "normalization exploded", "telemetry-processor", Instant.parse("2026-04-01T09:30:00Z")
        );
    }
}
