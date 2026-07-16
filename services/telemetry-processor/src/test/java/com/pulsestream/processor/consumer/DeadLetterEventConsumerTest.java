package com.pulsestream.processor.consumer;

import com.pulsestream.processor.config.KafkaConsumerConfiguration;
import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.model.DeadLetterEvent;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.service.DlqReplayPartitionRange;
import com.pulsestream.processor.service.DlqReplayService;
import com.pulsestream.processor.service.DlqReplaySession;
import com.pulsestream.processor.service.ReplayEventPublisher;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.common.TopicPartition;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.context.annotation.Bean;
import org.springframework.kafka.annotation.EnableKafka;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.config.KafkaListenerEndpointRegistry;
import org.springframework.kafka.listener.ConsumerSeekAware;
import org.springframework.kafka.listener.MessageListenerContainer;

import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;

@ExtendWith(MockitoExtension.class)
class DeadLetterEventConsumerTest {

    private static final TopicPartition DLQ_PARTITION =
            new TopicPartition("telemetry.events.dlq", 0);

    @Mock
    private ReplayEventPublisher replayEventPublisher;

    @Mock
    private DlqReplayService dlqReplayService;

    private DlqReplaySession replaySession;

    private DeadLetterEventConsumer consumer;

    @BeforeEach
    void setUp() {
        replaySession = new DlqReplaySession();
        consumer = new DeadLetterEventConsumer(replayEventPublisher, replaySession, dlqReplayService);
    }

    @Test
    @DisplayName("should republish a selected event to the raw topic")
    void shouldRepublishSelectedEvent() {
        DeadLetterEvent deadLetterEvent = deadLetterEvent();
        beginReplay(Set.of(deadLetterEvent.event().eventId()), 0, 1);

        assertThatCode(() -> consumer.consumeDeadLetterEvent(record(deadLetterEvent, 0)))
                .doesNotThrowAnyException();

        verify(replayEventPublisher).publish(deadLetterEvent.event());
        verify(dlqReplayService).onReplayRecordProcessed(DLQ_PARTITION, 0);
    }

    @Test
    @DisplayName("should skip an event that is not in the current replay selection")
    void shouldSkipUnselectedEvent() {
        DeadLetterEvent deadLetterEvent = deadLetterEvent();
        beginReplay(Set.of("some-other-event"), 0, 1);

        assertThatCode(() -> consumer.consumeDeadLetterEvent(record(deadLetterEvent, 0)))
                .doesNotThrowAnyException();

        verifyNoInteractions(replayEventPublisher);
        verify(dlqReplayService).onReplayRecordProcessed(DLQ_PARTITION, 0);
    }

    @Test
    @DisplayName("should skip a selected event appended after the trigger-time boundary")
    void shouldSkipSelectedEventAppendedAfterBoundary() {
        DeadLetterEvent deadLetterEvent = deadLetterEvent();
        beginReplay(Set.of(deadLetterEvent.event().eventId()), 0, 1);

        consumer.consumeDeadLetterEvent(record(deadLetterEvent, 1));

        verifyNoInteractions(replayEventPublisher);
        verify(dlqReplayService).onReplayRecordProcessed(DLQ_PARTITION, 1);
    }

    @Test
    @DisplayName("should propagate a republish failure instead of swallowing it")
    void shouldPropagateRepublishFailure() {
        DeadLetterEvent deadLetterEvent = deadLetterEvent();
        beginReplay(Set.of(deadLetterEvent.event().eventId()), 0, 1);
        RuntimeException publishFailure = new RuntimeException("broker unavailable");
        doThrow(publishFailure).when(replayEventPublisher).publish(deadLetterEvent.event());

        assertThatThrownBy(() -> consumer.consumeDeadLetterEvent(record(deadLetterEvent, 0)))
                .isSameAs(publishFailure);

        verifyNoInteractions(dlqReplayService);
    }

    @Test
    @DisplayName("should reject a null consumer record")
    void shouldRejectNullConsumerRecord() {
        assertThatThrownBy(() -> consumer.consumeDeadLetterEvent(null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("record must not be null");

        verifyNoInteractions(replayEventPublisher);
    }

    @Test
    @DisplayName("should reject a dead-letter event with a null wrapped event")
    void shouldRejectDeadLetterEventWithNullWrappedEvent() {
        DeadLetterEvent deadLetterEvent = new DeadLetterEvent(
                null, "boom", "ingestion-service", Instant.parse("2026-04-01T09:30:00Z")
        );

        assertThatThrownBy(() -> consumer.consumeDeadLetterEvent(record(deadLetterEvent, 0)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("deadLetterEvent.event must not be null");

        verifyNoInteractions(replayEventPublisher);
    }

    @Test
    @DisplayName("should rewind partitions to the beginning while a replay selection is active")
    void shouldSeekToBeginningWhenReplayActive() {
        beginReplay(Set.of("evt-001"), 0, 1);
        ConsumerSeekAware.ConsumerSeekCallback callback = mock(ConsumerSeekAware.ConsumerSeekCallback.class);

        consumer.onPartitionsAssigned(Map.of(DLQ_PARTITION, 0L), callback);

        verify(callback).seekToBeginning(Set.of(DLQ_PARTITION));
    }

    @Test
    @DisplayName("should not rewind partitions when no replay selection is active")
    void shouldNotSeekWhenReplayInactive() {
        TopicPartition partition = new TopicPartition("telemetry.events.dlq", 0);
        ConsumerSeekAware.ConsumerSeekCallback callback = mock(ConsumerSeekAware.ConsumerSeekCallback.class);

        consumer.onPartitionsAssigned(Map.of(partition, 0L), callback);

        verifyNoInteractions(callback);
    }

    @Test
    @DisplayName("should listen to configured DLQ topic with its own consumer group and container factory")
    void shouldListenToConfiguredDlqTopic() throws NoSuchMethodException {
        Method method = DeadLetterEventConsumer.class.getMethod(
                "consumeDeadLetterEvent",
                ConsumerRecord.class
        );

        KafkaListener kafkaListener = method.getAnnotation(KafkaListener.class);

        assertThat(kafkaListener).isNotNull();
        assertThat(kafkaListener.id()).isEqualTo(DeadLetterEventConsumer.LISTENER_ID);
        assertThat(kafkaListener.topics()).containsExactly("${pulsestream.kafka.topics.dlq}");
        assertThat(kafkaListener.groupId()).isEqualTo("${pulsestream.kafka.consumer.dlq-group-id}");
        assertThat(kafkaListener.containerFactory()).isEqualTo("dlqKafkaListenerContainerFactory");
        assertThat(kafkaListener.autoStartup()).isEqualTo("false");
    }

    @Test
    @DisplayName("should register the DLQ replay listener container without auto-starting it")
    void shouldNotAutoStartDlqReplayListener() {
        new ApplicationContextRunner()
                .withUserConfiguration(ListenerTestConfiguration.class)
                .withPropertyValues(
                        "pulsestream.kafka.bootstrap-servers=localhost:9092",
                        "pulsestream.kafka.consumer.dlq-group-id=telemetry-processor-dlq-replay",
                        "pulsestream.kafka.topics.dlq=telemetry.events.dlq"
                )
                .run(context -> {
                    assertThat(context).hasNotFailed();

                    KafkaListenerEndpointRegistry registry =
                            context.getBean(KafkaListenerEndpointRegistry.class);
                    MessageListenerContainer container =
                            registry.getListenerContainer(DeadLetterEventConsumer.LISTENER_ID);

                    assertThat(container).isNotNull();
                    assertThat(container.isAutoStartup()).isFalse();
                    assertThat(container.isRunning()).isFalse();
                });
    }

    @EnableKafka
    @EnableConfigurationProperties(TelemetryProcessorKafkaProperties.class)
    static class ListenerTestConfiguration extends KafkaConsumerConfiguration {

        @Bean
        DlqReplaySession dlqReplaySession() {
            return new DlqReplaySession();
        }

        @Bean
        DeadLetterEventConsumer deadLetterEventConsumer(DlqReplaySession dlqReplaySession) {
            return new DeadLetterEventConsumer(
                    mock(ReplayEventPublisher.class),
                    dlqReplaySession,
                    mock(DlqReplayService.class)
            );
        }
    }

    private DeadLetterEvent deadLetterEvent() {
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

    private void beginReplay(Set<String> eventIds, long startOffset, long endOffset) {
        replaySession.begin(
                eventIds,
                Map.of(DLQ_PARTITION, new DlqReplayPartitionRange(startOffset, endOffset))
        );
    }

    private ConsumerRecord<String, DeadLetterEvent> record(DeadLetterEvent event, long offset) {
        return new ConsumerRecord<>(
                DLQ_PARTITION.topic(),
                DLQ_PARTITION.partition(),
                offset,
                event.event() == null ? null : event.event().eventId(),
                event
        );
    }
}
