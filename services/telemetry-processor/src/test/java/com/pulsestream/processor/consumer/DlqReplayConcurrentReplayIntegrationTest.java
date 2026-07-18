package com.pulsestream.processor.consumer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.pulsestream.processor.config.KafkaConsumerConfiguration;
import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.model.DeadLetterEvent;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.service.DlqReplayBoundarySnapshotter;
import com.pulsestream.processor.service.DlqReplayPartitionRange;
import com.pulsestream.processor.service.DlqReplayService;
import com.pulsestream.processor.service.DlqReplaySession;
import com.pulsestream.processor.service.ReplayEventPublisher;
import java.math.BigDecimal;
import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;
import org.apache.kafka.clients.producer.Producer;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.kafka.config.ConcurrentKafkaListenerContainerFactory;
import org.springframework.kafka.config.KafkaListenerEndpointRegistry;
import org.springframework.kafka.core.ConsumerFactory;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.event.ListenerContainerIdleEvent;
import org.springframework.kafka.listener.ConcurrentMessageListenerContainer;
import org.springframework.kafka.listener.MessageListener;
import org.springframework.kafka.listener.MessageListenerContainer;
import org.springframework.kafka.support.TopicPartitionOffset;
import org.springframework.kafka.support.serializer.JsonSerializer;
import org.springframework.kafka.test.EmbeddedKafkaKraftBroker;
import org.springframework.kafka.test.utils.KafkaTestUtils;

/**
 * Container-level proof that a concurrent DLQ replay (#125) is partition-aware and cannot be ended
 * early by a single idle child.
 * <p>
 * A two-partition DLQ topic is replayed with concurrency {@code 2}, so each partition is scanned by
 * its own consumer child. Partition 0 holds one selected event that drains immediately; partition 1
 * holds two selected events whose republish is gated so that child keeps scanning. This reproduces
 * the reported bug: partition 0's child goes idle while partition 1 is still scanning. The test
 * asserts that:
 * <ul>
 *   <li>the idle fallback does <strong>not</strong> stop the parent listener while partition 1 is
 *       still scanning, so the run stays alive, and</li>
 *   <li>once the gate is released, every selected event across both partitions is replayed and the
 *       listener then stops because the whole trigger-time boundary is reached.</li>
 * </ul>
 * The real {@link DlqReplayService#onListenerContainerIdle} and
 * {@link DlqReplayService#onReplayRecordProcessed} drive the stop decisions; idle events are routed
 * to the service through the container's {@link ApplicationEventPublisher}, exactly as Spring does
 * in the application context.
 */
class DlqReplayConcurrentReplayIntegrationTest {

    private static final String TOPIC = "telemetry.events.dlq.concurrent-test";
    private static final String GROUP = "telemetry-processor-dlq-concurrent-test";
    private static final TopicPartition PARTITION_0 = new TopicPartition(TOPIC, 0);
    private static final TopicPartition PARTITION_1 = new TopicPartition(TOPIC, 1);

    private static EmbeddedKafkaKraftBroker broker;

    @BeforeAll
    static void startBroker() {
        broker = new EmbeddedKafkaKraftBroker(1, 2, TOPIC);
        broker.afterPropertiesSet();
    }

    @AfterAll
    static void stopBroker() {
        broker.destroy();
    }

    @Test
    @DisplayName("an idle child must not end a concurrent replay while another partition is still scanning")
    void concurrentReplayIsNotStoppedEarlyBySingleIdleChild() throws Exception {
        // Partition 0: one selected event that drains immediately, so its child goes idle first.
        produceDeadLetterEvent(0, "p0-evt-0");
        // Partition 1: two selected events whose republish is gated so its child keeps scanning.
        produceDeadLetterEvent(1, "p1-evt-0");
        produceDeadLetterEvent(1, "p1-evt-1");

        Set<String> published = ConcurrentHashMap.newKeySet();
        CountDownLatch partition1Gate = new CountDownLatch(1);
        ReplayEventPublisher publisher = mock(ReplayEventPublisher.class);
        doAnswer(invocation -> {
            TelemetryEvent event = invocation.getArgument(0);
            if (event.eventId().startsWith("p1-")) {
                // Keep partition 1's child busy (and therefore not idle) until the gate opens.
                partition1Gate.await(30, TimeUnit.SECONDS);
            }
            published.add(event.eventId());
            return null;
        }).when(publisher).publish(any());

        DlqReplaySession session = new DlqReplaySession();
        Set<TopicPartition> observedIdlePartitions = ConcurrentHashMap.newKeySet();

        TelemetryProcessorKafkaProperties properties = replayProperties();
        KafkaConsumerConfiguration configuration = new KafkaConsumerConfiguration();
        ConsumerFactory<String, DeadLetterEvent> consumerFactory =
                configuration.dlqConsumerFactory(properties);
        DlqReplayBoundarySnapshotter snapshotter =
                new DlqReplayBoundarySnapshotter(consumerFactory, properties);

        // Pin each partition to its own child via explicit assignment (assign(), not a group
        // subscription). Subscribing by topic would let the consumer-group rebalancer decide the
        // layout, and under load a single child can be assigned *both* partitions; if it then blocks
        // on partition 1's gate before the sibling joins, partition 0 is never read and the run
        // deadlocks. Explicit assignment gives a deterministic one-partition-per-child layout with no
        // rebalance, which is exactly the topology this test needs to prove the partition-aware idle
        // fallback. Seek to offset 0 so each child starts at the trigger-time boundary start.
        ConcurrentMessageListenerContainer<String, DeadLetterEvent> container =
                configuration
                        .dlqKafkaListenerContainerFactory(consumerFactory, properties, session)
                        .createContainer(
                                new TopicPartitionOffset(TOPIC, 0, 0L),
                                new TopicPartitionOffset(TOPIC, 1, 0L));
        // The parent bean name is the listener id the service matches on; children are suffixed.
        container.setBeanName(DeadLetterEventConsumer.LISTENER_ID);
        container.getContainerProperties().setGroupId(GROUP);

        DlqReplayService service = new DlqReplayService(
                registryProviderReturning(container), session, snapshotter);
        DeadLetterEventConsumer consumer =
                new DeadLetterEventConsumer(publisher, session, service);

        container.getContainerProperties().setMessageListener(
                (MessageListener<String, DeadLetterEvent>) record ->
                        consumer.consumeDeadLetterEvent(record));
        // Route idle events to the real service exactly as the Spring context would.
        container.setApplicationEventPublisher(event -> {
            if (event instanceof ListenerContainerIdleEvent idle
                    && DeadLetterEventConsumer.LISTENER_ID.equals(
                            idle.getContainer(MessageListenerContainer.class).getListenerId())) {
                observedIdlePartitions.addAll(idle.getTopicPartitions());
                service.onListenerContainerIdle(idle);
            }
        });

        Map<TopicPartition, DlqReplayPartitionRange> boundary = snapshotter.snapshot();
        session.begin(Set.of("p0-evt-0", "p1-evt-0", "p1-evt-1"), boundary);
        container.start();

        // Wait until partition 0 has drained and its child reported idle -- the exact moment the old
        // (partition-unaware) fallback would have stopped the entire listener.
        waitUntil(() -> published.contains("p0-evt-0"), "partition 0 event replayed");
        waitUntil(() -> observedIdlePartitions.contains(PARTITION_0), "partition 0 child went idle");

        assertThat(container.isRunning())
                .as("an idle partition-0 child must not stop the replay while partition 1 is still scanning")
                .isTrue();
        assertThat(session.isActive())
                .as("the replay run must stay active until every partition is settled")
                .isTrue();
        assertThat(published)
                .as("partition 1 events are still gated, so only partition 0 has been replayed")
                .containsExactly("p0-evt-0");

        // Release partition 1 -> its selected events replay and the whole boundary is reached.
        partition1Gate.countDown();
        waitUntil(() -> published.size() == 3, "all selected events across both partitions replayed");
        waitUntil(() -> !container.isRunning(), "listener stops once the whole boundary is reached");

        assertThat(published)
                .containsExactlyInAnyOrder("p0-evt-0", "p1-evt-0", "p1-evt-1");
        assertThat(session.isActive())
                .as("the run is cleared after a bounded, complete replay")
                .isFalse();

        container.stop();
    }

    private TelemetryProcessorKafkaProperties replayProperties() {
        TelemetryProcessorKafkaProperties properties = new TelemetryProcessorKafkaProperties();
        properties.setBootstrapServers(broker.getBrokersAsString());
        properties.getConsumer().setDlqGroupId(GROUP);
        properties.getConsumer().setKeyDeserializer(StringDeserializer.class.getName());
        properties.getConsumer().setAutoOffsetReset("earliest");
        // Two children, each explicitly pinned to one partition (see createContainer below), so an
        // idle child maps to a single partition.
        properties.getConsumer().setConcurrency(2);
        // Idle quickly so partition 0's drained child reports idle well within the test window.
        properties.getConsumer().setDlqReplayIdleTimeout(Duration.ofMillis(250));
        properties.getTopics().setDlq(TOPIC);
        return properties;
    }

    @SuppressWarnings("unchecked")
    private ObjectProvider<KafkaListenerEndpointRegistry> registryProviderReturning(
            MessageListenerContainer container) {
        KafkaListenerEndpointRegistry registry = mock(KafkaListenerEndpointRegistry.class);
        when(registry.getListenerContainer(DeadLetterEventConsumer.LISTENER_ID)).thenReturn(container);
        ObjectProvider<KafkaListenerEndpointRegistry> provider = mock(ObjectProvider.class);
        when(provider.getIfAvailable()).thenReturn(registry);
        return provider;
    }

    private void produceDeadLetterEvent(int partition, String eventId) throws Exception {
        Map<String, Object> producerProps = KafkaTestUtils.producerProps(broker);
        producerProps.put("key.serializer", StringSerializer.class);
        producerProps.put("value.serializer", JsonSerializer.class);
        // Consumers rely on VALUE_DEFAULT_TYPE (producers are separate services), not type headers.
        producerProps.put(JsonSerializer.ADD_TYPE_INFO_HEADERS, false);

        try (Producer<String, DeadLetterEvent> producer =
                new DefaultKafkaProducerFactory<String, DeadLetterEvent>(producerProps).createProducer()) {
            producer.send(new ProducerRecord<>(TOPIC, partition, eventId, deadLetterEvent(eventId))).get();
        }
    }

    private static void waitUntil(BooleanSupplier condition, String description) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30);
        while (System.nanoTime() < deadline) {
            if (condition.getAsBoolean()) {
                return;
            }
            Thread.sleep(100);
        }
        throw new AssertionError("Timed out waiting for: " + description);
    }

    private static DeadLetterEvent deadLetterEvent(String eventId) {
        TelemetryEvent event = new TelemetryEvent(
                eventId,
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
