package com.pulsestream.processor.service;

import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.inOrder;

@ExtendWith(MockitoExtension.class)
class TelemetryProcessingServiceTest {

    @Mock
    private ProcessedTelemetryPublisher processedTelemetryPublisher;

    @Mock
    private ProcessedTelemetryPersistenceService persistenceService;

    @Test
    @DisplayName("should normalize raw telemetry event, persist it, and publish processed event")
    void shouldNormalizeRawTelemetryEventPersistItAndPublishProcessedEvent() {
        TelemetryProcessingService service =
                new TelemetryProcessingService(processedTelemetryPublisher, persistenceService);
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
        InOrder inOrder = inOrder(persistenceService, processedTelemetryPublisher);
        inOrder.verify(persistenceService).persist(captor.capture());
        inOrder.verify(processedTelemetryPublisher).publish(captor.getValue());

        TelemetryEvent persistedEvent = captor.getValue();
        assertThat(processedEvent).isEqualTo(persistedEvent);
        assertThat(persistedEvent.eventId()).isEqualTo("evt-001");
        assertThat(persistedEvent.tenantId()).isEqualTo("factory-01");
        assertThat(persistedEvent.eventType()).isEqualTo("telemetry.processed");
        assertThat(persistedEvent.timestamp()).isEqualTo(Instant.parse("2026-03-15T12:05:21Z"));
        assertThat(persistedEvent.source()).isEqualTo("telemetry-processor");
        assertThat(persistedEvent.version()).isEqualTo("1.0");
        assertThat(persistedEvent.payload().deviceId()).isEqualTo("sensor_1042");
        assertThat(persistedEvent.payload().deviceType()).isEqualTo("temperature-sensor");
        assertThat(persistedEvent.payload().metric()).isEqualTo("temperature");
        assertThat(persistedEvent.payload().unit()).isEqualTo("C");
        assertThat(persistedEvent.payload().location()).isEqualTo("zone-a");
    }

    @Test
    @DisplayName("should stamp processed event with clock time when raw timestamp is missing")
    void shouldStampProcessedEventWithClockTimeWhenRawTimestampIsMissing() {
        Instant fixedNow = Instant.parse("2026-03-15T12:05:30Z");
        Clock clock = Clock.fixed(fixedNow, ZoneOffset.UTC);
        TelemetryProcessingService service =
                new TelemetryProcessingService(processedTelemetryPublisher, persistenceService, clock);
        TelemetryEvent rawEvent = new TelemetryEvent(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                null,
                "sensor-gateway",
                "1.0",
                new TelemetryPayload(
                        "sensor_1042",
                        "temperature-sensor",
                        "temperature",
                        BigDecimal.valueOf(28.4),
                        "C",
                        "zone-a"
                )
        );

        TelemetryEvent processedEvent = service.process(rawEvent);

        assertThat(processedEvent.timestamp()).isEqualTo(fixedNow);
    }

    @Test
    @DisplayName("should reject raw telemetry events without payload")
    void shouldRejectRawTelemetryEventsWithoutPayload() {
        TelemetryProcessingService service =
                new TelemetryProcessingService(processedTelemetryPublisher, persistenceService);
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
