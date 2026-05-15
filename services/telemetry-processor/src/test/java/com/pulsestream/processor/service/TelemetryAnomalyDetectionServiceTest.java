package com.pulsestream.processor.service;

import com.pulsestream.processor.model.AnomalySeverity;
import com.pulsestream.processor.model.NormalizedTelemetryEvent;
import com.pulsestream.processor.model.TelemetryAnomalyResult;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class TelemetryAnomalyDetectionServiceTest {

    private final TelemetryAnomalyDetectionService anomalyDetectionService =
            new TelemetryAnomalyDetectionService();

    @Test
    @DisplayName("should classify normal telemetry event as not anomalous")
    void shouldClassifyNormalTelemetryEventAsNotAnomalous() {
        NormalizedTelemetryEvent event = normalizedEvent("temperature", new BigDecimal("28.4"));

        TelemetryAnomalyResult result = anomalyDetectionService.detect(event);

        assertThat(result.event()).isEqualTo(event);
        assertThat(result.anomalous()).isFalse();
        assertThat(result.severity()).isEqualTo(AnomalySeverity.NONE);
        assertThat(result.reasons()).isEmpty();
    }

    @Test
    @DisplayName("should detect high temperature anomaly")
    void shouldDetectHighTemperatureAnomaly() {
        NormalizedTelemetryEvent event = normalizedEvent("temperature", new BigDecimal("95.0"));

        TelemetryAnomalyResult result = anomalyDetectionService.detect(event);

        assertThat(result.anomalous()).isTrue();
        assertThat(result.severity()).isEqualTo(AnomalySeverity.WARNING);
        assertThat(result.reasons()).contains("temperature is above maximum threshold");
    }

    @Test
    @DisplayName("should detect low temperature anomaly")
    void shouldDetectLowTemperatureAnomaly() {
        NormalizedTelemetryEvent event = normalizedEvent("temperature", new BigDecimal("-50.0"));

        TelemetryAnomalyResult result = anomalyDetectionService.detect(event);

        assertThat(result.anomalous()).isTrue();
        assertThat(result.severity()).isEqualTo(AnomalySeverity.WARNING);
        assertThat(result.reasons()).contains("temperature is below minimum threshold");
    }

    @Test
    @DisplayName("should detect missing critical fields")
    void shouldDetectMissingCriticalFields() {
        NormalizedTelemetryEvent event = new NormalizedTelemetryEvent(
                "evt-001",
                null,
                "telemetry.reading",
                Instant.parse("2026-03-31T12:00:00Z"),
                "sensor-gateway",
                "1.0",
                "",
                "temperature-sensor",
                null,
                null,
                "c",
                "zone-a"
        );

        TelemetryAnomalyResult result = anomalyDetectionService.detect(event);

        assertThat(result.anomalous()).isTrue();
        assertThat(result.severity()).isEqualTo(AnomalySeverity.CRITICAL);
        assertThat(result.reasons())
                .contains(
                        "tenantId is required",
                        "deviceId is required",
                        "metric is required",
                        "value is required"
                );
    }

    @Test
    @DisplayName("should ignore temperature thresholds for unsupported metrics")
    void shouldIgnoreTemperatureThresholdsForUnsupportedMetrics() {
        NormalizedTelemetryEvent event = normalizedEvent("pressure", new BigDecimal("95.0"));

        TelemetryAnomalyResult result = anomalyDetectionService.detect(event);

        assertThat(result.anomalous()).isFalse();
        assertThat(result.severity()).isEqualTo(AnomalySeverity.NONE);
        assertThat(result.reasons()).isEmpty();
    }

    @Test
    @DisplayName("should reject null normalized telemetry event")
    void shouldRejectNullNormalizedTelemetryEvent() {
        assertThatThrownBy(() -> anomalyDetectionService.detect(null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("normalized telemetry event must not be null");
    }

    private NormalizedTelemetryEvent normalizedEvent(String metric, BigDecimal value) {
        return new NormalizedTelemetryEvent(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                Instant.parse("2026-03-31T12:00:00Z"),
                "sensor-gateway",
                "1.0",
                "sensor-1042",
                "temperature-sensor",
                metric,
                value,
                "c",
                "zone-a"
        );
    }
}