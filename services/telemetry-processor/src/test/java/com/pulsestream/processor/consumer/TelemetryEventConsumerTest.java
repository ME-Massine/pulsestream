package com.pulsestream.processor.consumer;

import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.kafka.annotation.KafkaListener;

import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class TelemetryEventConsumerTest {

    private final TelemetryEventConsumer consumer = new TelemetryEventConsumer();

    @Test
    @DisplayName("should consume telemetry event without throwing")
    void shouldConsumeTelemetryEventWithoutThrowing() {
        TelemetryEvent event = telemetryEvent();

        consumer.consumeTelemetryEvent(event);
    }

    @Test
    @DisplayName("should reject null telemetry event")
    void shouldRejectNullTelemetryEvent() {
        assertThatThrownBy(() -> consumer.consumeTelemetryEvent(null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("telemetryEvent must not be null");
    }

    @Test
    @DisplayName("should listen to configured raw telemetry topic")
    void shouldListenToConfiguredRawTelemetryTopic() throws NoSuchMethodException {
        Method method = TelemetryEventConsumer.class.getMethod(
                "consumeTelemetryEvent",
                TelemetryEvent.class
        );

        KafkaListener kafkaListener = method.getAnnotation(KafkaListener.class);

        assertThat(kafkaListener).isNotNull();
        assertThat(kafkaListener.topics()).containsExactly("${pulsestream.kafka.topics.raw}");
        assertThat(kafkaListener.groupId()).isEqualTo("${pulsestream.kafka.consumer.group-id}");
        assertThat(kafkaListener.containerFactory()).isEqualTo("telemetryKafkaListenerContainerFactory");
    }

    private TelemetryEvent telemetryEvent() {
        return new TelemetryEvent(
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
    }
}