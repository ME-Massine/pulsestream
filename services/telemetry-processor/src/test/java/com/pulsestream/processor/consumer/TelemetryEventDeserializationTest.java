package com.pulsestream.processor.consumer;

import com.pulsestream.processor.model.TelemetryEvent;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.kafka.support.serializer.JsonDeserializer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;

class TelemetryEventDeserializationTest {

    @Test
    @DisplayName("should deserialize raw telemetry event JSON into telemetry event model")
    void shouldDeserializeRawTelemetryEventJsonIntoTelemetryEventModel() {
        String json = """
                {
                  "eventId": "evt-001",
                  "tenantId": "factory-01",
                  "eventType": "telemetry.reading",
                  "timestamp": "2026-03-31T12:00:00Z",
                  "source": "sensor-gateway",
                  "version": "1.0",
                  "payload": {
                    "deviceId": "sensor-1042",
                    "deviceType": "temperature-sensor",
                    "metric": "temperature",
                    "value": 28.4,
                    "unit": "C",
                    "location": "zone-a"
                  }
                }
                """;

        JsonDeserializer<TelemetryEvent> deserializer = new JsonDeserializer<>(TelemetryEvent.class);
        deserializer.addTrustedPackages("com.pulsestream.processor.model");

        TelemetryEvent event = deserializer.deserialize(
                "telemetry.events.raw",
                json.getBytes(StandardCharsets.UTF_8)
        );

        assertThat(event.eventId()).isEqualTo("evt-001");
        assertThat(event.tenantId()).isEqualTo("factory-01");
        assertThat(event.eventType()).isEqualTo("telemetry.reading");
        assertThat(event.timestamp()).isEqualTo(Instant.parse("2026-03-31T12:00:00Z"));
        assertThat(event.source()).isEqualTo("sensor-gateway");
        assertThat(event.version()).isEqualTo("1.0");

        assertThat(event.payload()).isNotNull();
        assertThat(event.payload().deviceId()).isEqualTo("sensor-1042");
        assertThat(event.payload().deviceType()).isEqualTo("temperature-sensor");
        assertThat(event.payload().metric()).isEqualTo("temperature");
        assertThat(event.payload().value()).isEqualByComparingTo(new BigDecimal("28.4"));
        assertThat(event.payload().unit()).isEqualTo("C");
        assertThat(event.payload().location()).isEqualTo("zone-a");
    }
}