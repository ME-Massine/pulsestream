package com.pulsestream.processor.consumer;

import com.pulsestream.processor.config.KafkaConsumerConfiguration;
import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.model.DeadLetterEvent;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.service.ReplayEventPublisher;
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
import org.springframework.kafka.listener.MessageListenerContainer;

import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;

@ExtendWith(MockitoExtension.class)
class DeadLetterEventConsumerTest {

    @Mock
    private ReplayEventPublisher replayEventPublisher;

    private DeadLetterEventConsumer consumer;

    @BeforeEach
    void setUp() {
        consumer = new DeadLetterEventConsumer(replayEventPublisher);
    }

    @Test
    @DisplayName("should read, parse, and republish the wrapped event to the raw topic")
    void shouldReadAndParseDeadLetterEventWithoutThrowing() {
        DeadLetterEvent deadLetterEvent = deadLetterEvent();

        assertThatCode(() -> consumer.consumeDeadLetterEvent(deadLetterEvent))
                .doesNotThrowAnyException();

        verify(replayEventPublisher).publish(deadLetterEvent.event());
    }

    @Test
    @DisplayName("should propagate a republish failure instead of swallowing it")
    void shouldPropagateRepublishFailure() {
        DeadLetterEvent deadLetterEvent = deadLetterEvent();
        RuntimeException publishFailure = new RuntimeException("broker unavailable");
        doThrow(publishFailure).when(replayEventPublisher).publish(deadLetterEvent.event());

        assertThatThrownBy(() -> consumer.consumeDeadLetterEvent(deadLetterEvent))
                .isSameAs(publishFailure);
    }

    @Test
    @DisplayName("should reject a null dead-letter event")
    void shouldRejectNullDeadLetterEvent() {
        assertThatThrownBy(() -> consumer.consumeDeadLetterEvent(null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("deadLetterEvent must not be null");

        verifyNoInteractions(replayEventPublisher);
    }

    @Test
    @DisplayName("should reject a dead-letter event with a null wrapped event")
    void shouldRejectDeadLetterEventWithNullWrappedEvent() {
        DeadLetterEvent deadLetterEvent = new DeadLetterEvent(
                null, "boom", "ingestion-service", Instant.parse("2026-04-01T09:30:00Z")
        );

        assertThatThrownBy(() -> consumer.consumeDeadLetterEvent(deadLetterEvent))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("deadLetterEvent.event must not be null");

        verifyNoInteractions(replayEventPublisher);
    }

    @Test
    @DisplayName("should listen to configured DLQ topic with its own consumer group and container factory")
    void shouldListenToConfiguredDlqTopic() throws NoSuchMethodException {
        Method method = DeadLetterEventConsumer.class.getMethod(
                "consumeDeadLetterEvent",
                DeadLetterEvent.class
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
        DeadLetterEventConsumer deadLetterEventConsumer() {
            return new DeadLetterEventConsumer(mock(ReplayEventPublisher.class));
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
}
