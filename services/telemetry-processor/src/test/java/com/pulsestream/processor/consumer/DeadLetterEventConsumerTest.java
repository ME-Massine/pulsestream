package com.pulsestream.processor.consumer;

import com.pulsestream.processor.config.KafkaConsumerConfiguration;
import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.model.DeadLetterEvent;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
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

class DeadLetterEventConsumerTest {

    private final DeadLetterEventConsumer consumer = new DeadLetterEventConsumer();

    @Test
    @DisplayName("should read and parse a dead-letter event without throwing")
    void shouldReadAndParseDeadLetterEventWithoutThrowing() {
        DeadLetterEvent deadLetterEvent = deadLetterEvent();

        assertThatCode(() -> consumer.consumeDeadLetterEvent(deadLetterEvent))
                .doesNotThrowAnyException();
    }

    @Test
    @DisplayName("should reject a null dead-letter event")
    void shouldRejectNullDeadLetterEvent() {
        assertThatThrownBy(() -> consumer.consumeDeadLetterEvent(null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("deadLetterEvent must not be null");
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
            return new DeadLetterEventConsumer();
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
