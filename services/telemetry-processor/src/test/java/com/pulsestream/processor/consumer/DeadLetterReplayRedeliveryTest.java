package com.pulsestream.processor.consumer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;

import com.pulsestream.processor.config.KafkaConsumerConfiguration;
import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.exception.TelemetryPublishingException;
import com.pulsestream.processor.model.DeadLetterEvent;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.service.ReplayEventPublisher;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.Map;
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
 * Container-level proof of the #124 "no data loss" acceptance criterion for DLQ replay.
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

    private static EmbeddedKafkaKraftBroker broker;

    @BeforeAll
    static void startBroker() {
        broker = new EmbeddedKafkaKraftBroker(1, 1, DLQ_TOPIC);
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

        DeadLetterEventConsumer consumer = new DeadLetterEventConsumer(publisher);
        ConcurrentMessageListenerContainer<String, DeadLetterEvent> container = replayContainer(consumer);

        produceDeadLetterEvent();

        // Phase 1: first republish fails -> container stops, offset not committed.
        container.start();
        waitUntil(() -> publishAttempts.get() >= 1, "first republish attempt");
        waitUntil(() -> !container.isRunning(), "container stopped after failed republish");

        assertThat(publishAttempts.get()).isEqualTo(1);
        assertThat(container.isRunning()).isFalse();
        assertThat(committedOffset()).as("offset must not advance on a failed republish").isEqualTo(-1L);

        // Phase 2: operator restarts -> record is redelivered, succeeds, offset advances.
        container.start();
        waitUntil(() -> publishAttempts.get() >= 2, "redelivered republish attempt");
        waitUntil(() -> committedOffset() == 1L, "offset committed after successful republish");

        assertThat(publishAttempts.get()).isEqualTo(2);
        assertThat(committedOffset()).as("offset advances only after a successful republish").isEqualTo(1L);

        container.stop();
    }

    private ConcurrentMessageListenerContainer<String, DeadLetterEvent> replayContainer(
            DeadLetterEventConsumer consumer) {
        TelemetryProcessorKafkaProperties properties = new TelemetryProcessorKafkaProperties();
        properties.setBootstrapServers(broker.getBrokersAsString());
        properties.getConsumer().setDlqGroupId(DLQ_GROUP);
        properties.getConsumer().setKeyDeserializer(StringDeserializer.class.getName());
        properties.getConsumer().setAutoOffsetReset("earliest");
        properties.getConsumer().setConcurrency(1);
        properties.getTopics().setDlq(DLQ_TOPIC);

        KafkaConsumerConfiguration configuration = new KafkaConsumerConfiguration();
        ConsumerFactory<String, DeadLetterEvent> consumerFactory =
                configuration.dlqConsumerFactory(properties);
        ConcurrentKafkaListenerContainerFactory<String, DeadLetterEvent> factory =
                configuration.dlqKafkaListenerContainerFactory(consumerFactory, properties);

        // Build the container from the real factory so its CommonContainerStoppingErrorHandler applies.
        ConcurrentMessageListenerContainer<String, DeadLetterEvent> container =
                factory.createContainer(DLQ_TOPIC);
        container.getContainerProperties().setGroupId(DLQ_GROUP);
        container.getContainerProperties().setMessageListener(
                (MessageListener<String, DeadLetterEvent>) record ->
                        consumer.consumeDeadLetterEvent(record.value()));
        container.setBeanName("dlq-replay-redelivery-test");
        return container;
    }

    private void produceDeadLetterEvent() throws Exception {
        Map<String, Object> producerProps = KafkaTestUtils.producerProps(broker);
        producerProps.put("key.serializer", StringSerializer.class);
        producerProps.put("value.serializer", JsonSerializer.class);
        // Consumers rely on VALUE_DEFAULT_TYPE (producers are separate services), not type headers.
        producerProps.put(JsonSerializer.ADD_TYPE_INFO_HEADERS, false);

        try (Producer<String, DeadLetterEvent> producer =
                new DefaultKafkaProducerFactory<String, DeadLetterEvent>(producerProps).createProducer()) {
            producer.send(new ProducerRecord<>(DLQ_TOPIC, "evt-001", deadLetterEvent())).get();
        }
    }

    private long committedOffset() {
        try (Admin admin = Admin.create(Map.of(
                AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, broker.getBrokersAsString()))) {
            Map<TopicPartition, OffsetAndMetadata> offsets =
                    admin.listConsumerGroupOffsets(DLQ_GROUP).partitionsToOffsetAndMetadata().get();
            OffsetAndMetadata offsetAndMetadata = offsets.get(PARTITION);
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
