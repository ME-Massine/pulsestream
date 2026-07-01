package com.pulsestream.processor.service;

import com.pulsestream.processor.model.AnomalySeverity;
import com.pulsestream.processor.model.NormalizedTelemetryEvent;
import com.pulsestream.processor.model.TelemetryAnomalyEvent;
import com.pulsestream.processor.model.TelemetryAnomalyResult;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;

@ExtendWith(MockitoExtension.class)
class AnomalyProcessingServiceTest {

    private static final Instant DETECTED_AT = Instant.parse("2026-03-15T12:05:30Z");

    @Mock
    private AnomalyTelemetryPublisher anomalyPublisher;

    private final Clock clock = Clock.fixed(DETECTED_AT, ZoneOffset.UTC);

    @Test
    @DisplayName("should build enriched anomaly event with detection metadata and publish it")
    void shouldBuildEnrichedAnomalyEventAndPublish() {
        AnomalyProcessingService service = new AnomalyProcessingService(anomalyPublisher, clock);
        TelemetryEvent rawEvent = new TelemetryEvent(
                " evt-001 ",
                " factory-01 ",
                "telemetry.reading",
                Instant.parse("2026-03-15T12:05:21Z"),
                "sensor-gateway",
                " ",
                new TelemetryPayload(
                        " sensor_1042 ",
                        " temperature-sensor ",
                        " temperature ",
                        BigDecimal.valueOf(95.0),
                        " C ",
                        " zone-a "
                )
        );
        TelemetryAnomalyResult anomalyResult = TelemetryAnomalyResult.anomalous(
                normalizedEvent(),
                AnomalySeverity.WARNING,
                List.of("temperature is above maximum threshold")
        );

        TelemetryAnomalyEvent anomalyEvent = service.process(rawEvent, anomalyResult);

        ArgumentCaptor<TelemetryAnomalyEvent> captor = ArgumentCaptor.forClass(TelemetryAnomalyEvent.class);
        verify(anomalyPublisher).publish(captor.capture());

        TelemetryAnomalyEvent publishedEvent = captor.getValue();
        assertThat(anomalyEvent).isEqualTo(publishedEvent);
        assertThat(publishedEvent.eventId()).isEqualTo("evt-001");
        assertThat(publishedEvent.tenantId()).isEqualTo("factory-01");
        assertThat(publishedEvent.eventType()).isEqualTo("telemetry.anomaly");
        assertThat(publishedEvent.timestamp()).isEqualTo(Instant.parse("2026-03-15T12:05:21Z"));
        assertThat(publishedEvent.source()).isEqualTo("telemetry-processor");
        assertThat(publishedEvent.version()).isEqualTo("1.0");
        assertThat(publishedEvent.severity()).isEqualTo(AnomalySeverity.WARNING);
        assertThat(publishedEvent.reasons()).containsExactly("temperature is above maximum threshold");
        assertThat(publishedEvent.detectedAt()).isEqualTo(DETECTED_AT);
        assertThat(publishedEvent.payload().deviceId()).isEqualTo("sensor_1042");
        assertThat(publishedEvent.payload().metric()).isEqualTo("temperature");
        assertThat(publishedEvent.payload().unit()).isEqualTo("C");
        assertThat(publishedEvent.payload().location()).isEqualTo("zone-a");
        assertThat(publishedEvent.payload().value()).isEqualByComparingTo(BigDecimal.valueOf(95.0));
    }

    @Test
    @DisplayName("should reject a result that is not anomalous")
    void shouldRejectNonAnomalousResult() {
        AnomalyProcessingService service = new AnomalyProcessingService(anomalyPublisher, clock);
        TelemetryEvent rawEvent = rawEvent();
        TelemetryAnomalyResult normalResult = TelemetryAnomalyResult.normal(normalizedEvent());

        assertThatThrownBy(() -> service.process(rawEvent, normalResult))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("anomalyResult must be anomalous");

        verifyNoInteractions(anomalyPublisher);
    }

    @Test
    @DisplayName("should reject raw telemetry events without payload")
    void shouldRejectRawTelemetryEventsWithoutPayload() {
        AnomalyProcessingService service = new AnomalyProcessingService(anomalyPublisher, clock);
        TelemetryEvent rawEvent = new TelemetryEvent(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                Instant.parse("2026-03-15T12:05:21Z"),
                "sensor-gateway",
                "1.0",
                null
        );
        TelemetryAnomalyResult anomalyResult = TelemetryAnomalyResult.anomalous(
                normalizedEvent(), AnomalySeverity.CRITICAL, List.of("value is required")
        );

        assertThatThrownBy(() -> service.process(rawEvent, anomalyResult))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("rawEvent payload must not be null");

        verifyNoInteractions(anomalyPublisher);
    }

    private TelemetryEvent rawEvent() {
        return new TelemetryEvent(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                Instant.parse("2026-03-15T12:05:21Z"),
                "sensor-gateway",
                "1.0",
                new TelemetryPayload(
                        "sensor_1042",
                        "temperature-sensor",
                        "temperature",
                        BigDecimal.valueOf(95.0),
                        "C",
                        "zone-a"
                )
        );
    }

    private NormalizedTelemetryEvent normalizedEvent() {
        return new NormalizedTelemetryEvent(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                Instant.parse("2026-03-15T12:05:21Z"),
                "sensor-gateway",
                "1.0",
                "sensor_1042",
                "temperature-sensor",
                "temperature",
                BigDecimal.valueOf(95.0),
                "c",
                "zone-a"
        );
    }
}
