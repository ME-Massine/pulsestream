package com.pulsestream.processor.service;

import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import java.math.BigDecimal;
import java.time.Instant;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.verify;

@ExtendWith(MockitoExtension.class)
class TelemetryProcessingServiceTest {

    @Mock
    private ProcessedTelemetryPublisher processedTelemetryPublisher;

    @Test
    @DisplayName("should normalize raw telemetry event and publish processed event")
    void shouldNormalizeRawTelemetryEventAndPublishProcessedEvent() {
        TelemetryProcessingService service = new TelemetryProcessingService(processedTelemetryPublisher);
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
                        BigDecimal.valueOf(28.4),
                        " C ",
                        " zone-a "
                )
        );

        TelemetryEvent processedEvent = service.process(rawEvent);

        ArgumentCaptor<TelemetryEvent> captor = ArgumentCaptor.forClass(TelemetryEvent.class);
        verify(processedTelemetryPublisher).publish(captor.capture());

        TelemetryEvent publishedEvent = captor.getValue();
        assertThat(processedEvent).isEqualTo(publishedEvent);
        assertThat(publishedEvent.eventId()).isEqualTo("evt-001");
        assertThat(publishedEvent.tenantId()).isEqualTo("factory-01");
        assertThat(publishedEvent.eventType()).isEqualTo("telemetry.processed");
        assertThat(publishedEvent.timestamp()).isEqualTo(Instant.parse("2026-03-15T12:05:21Z"));
        assertThat(publishedEvent.source()).isEqualTo("telemetry-processor");
        assertThat(publishedEvent.version()).isEqualTo("1.0");
        assertThat(publishedEvent.payload().deviceId()).isEqualTo("sensor_1042");
        assertThat(publishedEvent.payload().deviceType()).isEqualTo("temperature-sensor");
        assertThat(publishedEvent.payload().metric()).isEqualTo("temperature");
        assertThat(publishedEvent.payload().unit()).isEqualTo("C");
        assertThat(publishedEvent.payload().location()).isEqualTo("zone-a");
    }

    @Test
    @DisplayName("should reject raw telemetry events without payload")
    void shouldRejectRawTelemetryEventsWithoutPayload() {
        TelemetryProcessingService service = new TelemetryProcessingService(processedTelemetryPublisher);
        TelemetryEvent rawEvent = new TelemetryEvent(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                Instant.parse("2026-03-15T12:05:21Z"),
                "sensor-gateway",
                "1.0",
                null
        );

        assertThatThrownBy(() -> service.process(rawEvent))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("rawEvent payload must not be null");
    }
}
