package com.pulsestream.processor.service;

import com.pulsestream.processor.model.NormalizedTelemetryEvent;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class TelemetryNormalizationServiceTest {

    private final TelemetryNormalizationService normalizationService =
            new TelemetryNormalizationService();

    @Test
    @DisplayName("should normalize telemetry event into consistent internal format")
    void shouldNormalizeTelemetryEventIntoConsistentInternalFormat() {
        TelemetryEvent rawEvent = new TelemetryEvent(
                " evt-001 ",
                " factory-01 ",
                " Telemetry.Reading ",
                Instant.parse("2026-03-31T12:00:00Z"),
                " sensor-gateway ",
                " 1.0 ",
                new TelemetryPayload(
                        " sensor-1042 ",
                        " Temperature-Sensor ",
                        " Temperature ",
                        new BigDecimal("28.4"),
                        " C ",
                        " zone-a "
                )
        );

        NormalizedTelemetryEvent normalizedEvent =
                normalizationService.normalize(rawEvent);

        assertThat(normalizedEvent.eventId()).isEqualTo("evt-001");
        assertThat(normalizedEvent.tenantId()).isEqualTo("factory-01");
        assertThat(normalizedEvent.eventType()).isEqualTo("telemetry.reading");
        assertThat(normalizedEvent.timestamp()).isEqualTo(Instant.parse("2026-03-31T12:00:00Z"));
        assertThat(normalizedEvent.source()).isEqualTo("sensor-gateway");
        assertThat(normalizedEvent.version()).isEqualTo("1.0");
        assertThat(normalizedEvent.deviceId()).isEqualTo("sensor-1042");
        assertThat(normalizedEvent.deviceType()).isEqualTo("temperature-sensor");
        assertThat(normalizedEvent.metric()).isEqualTo("temperature");
        assertThat(normalizedEvent.value()).isEqualByComparingTo(new BigDecimal("28.4"));
        assertThat(normalizedEvent.unit()).isEqualTo("c");
        assertThat(normalizedEvent.location()).isEqualTo("zone-a");
    }

    @Test
    @DisplayName("should preserve numeric value and timestamp during normalization")
    void shouldPreserveNumericValueAndTimestampDuringNormalization() {
        Instant timestamp = Instant.parse("2026-03-31T12:00:00Z");
        BigDecimal value = new BigDecimal("28.4");

        TelemetryEvent rawEvent = new TelemetryEvent(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                timestamp,
                "sensor-gateway",
                "1.0",
                new TelemetryPayload(
                        "sensor-1042",
                        "temperature-sensor",
                        "temperature",
                        value,
                        "c",
                        "zone-a"
                )
        );

        NormalizedTelemetryEvent normalizedEvent =
                normalizationService.normalize(rawEvent);

        assertThat(normalizedEvent.timestamp()).isEqualTo(timestamp);
        assertThat(normalizedEvent.value()).isEqualByComparingTo(value);
    }

    @Test
    @DisplayName("should reject null telemetry event")
    void shouldRejectNullTelemetryEvent() {
        assertThatThrownBy(() -> normalizationService.normalize(null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("telemetry event must not be null");
    }

    @Test
    @DisplayName("should reject telemetry event with null payload")
    void shouldRejectTelemetryEventWithNullPayload() {
        TelemetryEvent rawEvent = new TelemetryEvent(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                Instant.parse("2026-03-31T12:00:00Z"),
                "sensor-gateway",
                "1.0",
                null
        );

        assertThatThrownBy(() -> normalizationService.normalize(rawEvent))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("telemetry payload must not be null");
    }
}