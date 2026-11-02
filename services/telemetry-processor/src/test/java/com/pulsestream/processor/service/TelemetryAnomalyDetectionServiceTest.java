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
    @DisplayName("should treat temperature exactly at maximum threshold as normal")
    void shouldTreatTemperatureAtMaxThresholdAsNormal() {
        NormalizedTelemetryEvent event = normalizedEvent("temperature", new BigDecimal("80"));

        TelemetryAnomalyResult result = anomalyDetectionService.detect(event);

        assertThat(result.anomalous()).isFalse();
        assertThat(result.severity()).isEqualTo(AnomalySeverity.NONE);
    }

    @Test
    @DisplayName("should treat temperature exactly at minimum threshold as normal")
    void shouldTreatTemperatureAtMinThresholdAsNormal() {
        NormalizedTelemetryEvent event = normalizedEvent("temperature", new BigDecimal("-40"));

        TelemetryAnomalyResult result = anomalyDetectionService.detect(event);

        assertThat(result.anomalous()).isFalse();
        assertThat(result.severity()).isEqualTo(AnomalySeverity.NONE);
    }

    @Test
    @DisplayName("should not detect spike on first reading for a device-metric pair")
    void shouldNotDetectSpikeOnFirstReading() {
        NormalizedTelemetryEvent event = normalizedEvent("temperature", new BigDecimal("28.4"));

        TelemetryAnomalyResult result = anomalyDetectionService.detect(event);

        assertThat(result.anomalous()).isFalse();
        assertThat(result.reasons()).isEmpty();
    }

    @Test
    @DisplayName("should detect value spike when reading changes by more than 50 percent from previous")
    void shouldDetectValueSpikeAboveThreshold() {
        NormalizedTelemetryEvent spikeEvent = normalizedEvent("temperature", new BigDecimal("50.0"));
        TelemetryAnomalyResult result = anomalyDetectionService.detect(spikeEvent, new BigDecimal("20.0"));

        assertThat(result.anomalous()).isTrue();
        assertThat(result.severity()).isEqualTo(AnomalySeverity.WARNING);
        assertThat(result.reasons()).anyMatch(r -> r.startsWith("value spike detected"));
    }

    @Test
    @DisplayName("should not detect spike when reading changes by 50 percent or less from previous")
    void shouldNotDetectSpikeAtOrBelowThreshold() {
        NormalizedTelemetryEvent event = normalizedEvent("temperature", new BigDecimal("30.0"));
        TelemetryAnomalyResult result = anomalyDetectionService.detect(event, new BigDecimal("20.0"));

        assertThat(result.anomalous()).isFalse();
        assertThat(result.reasons()).noneMatch(r -> r.startsWith("value spike detected"));
    }

    @Test
    @DisplayName("should reject null normalized telemetry event")
    void shouldRejectNullNormalizedTelemetryEvent() {
        assertThatThrownBy(() -> anomalyDetectionService.detect(null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("normalized telemetry event must not be null");
    }

    @Test
    void zeroBaselineHasNoRelativeSpikeAndNegativeBaselinesUseAbsoluteMagnitude() {
        assertThat(anomalyDetectionService.detect(normalizedEvent("pressure", new BigDecimal("20")), BigDecimal.ZERO).anomalous())
                .isFalse();
        assertThat(anomalyDetectionService.detect(normalizedEvent("pressure", new BigDecimal("-40")), new BigDecimal("-20")).reasons())
                .containsExactly("value spike detected: changed by 100.0% from previous reading");
        assertThat(anomalyDetectionService.detect(normalizedEvent("pressure", new BigDecimal("30.00000000001")), new BigDecimal("20")).anomalous())
                .isTrue();
    }

    @Test
    void thresholdsAndUnitAssumptionsComeFromConfiguration() {
        var properties = new com.pulsestream.processor.config.AnomalyDetectionProperties(BigDecimal.ZERO,
                new BigDecimal("30"), "c", new BigDecimal("0.1"), java.time.Duration.ofHours(1), 10, 10);
        var configured = new TelemetryAnomalyDetectionService(properties);
        assertThat(configured.detect(normalizedEvent("temperature", new BigDecimal("31")), new BigDecimal("20")).reasons())
                .hasSize(2).contains("temperature is above maximum threshold");
        assertThat(configured.detect(normalizedEvent("temperature", new BigDecimal("-1"))).reasons())
                .containsExactly("temperature is below minimum threshold");
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
