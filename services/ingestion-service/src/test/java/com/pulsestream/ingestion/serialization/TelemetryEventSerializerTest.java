package com.pulsestream.ingestion.serialization;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.pulsestream.ingestion.model.TelemetryEvent;
import com.pulsestream.ingestion.model.TelemetryPayload;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.*;

class TelemetryEventSerializerTest {

    private final TelemetryEventSerializer serializer =
            new TelemetryEventSerializer(new ObjectMapper().findAndRegisterModules());

    @Test
    @DisplayName("should serialize telemetry event to json")
    void shouldSerializeTelemetryEventToJson() {
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

        String json = serializer.serialize(event);

        assertNotNull(json);
        assertTrue(json.contains("\"eventId\":\"evt-001\""));
        assertTrue(json.contains("\"tenantId\":\"factory-01\""));
        assertTrue(json.contains("\"eventType\":\"telemetry.reading\""));
        assertTrue(json.contains("\"source\":\"sensor-gateway\""));
        assertTrue(json.contains("\"version\":\"1.0\""));
        assertTrue(json.contains("\"deviceId\":\"sensor-1042\""));
        assertTrue(json.contains("\"metric\":\"temperature\""));
        assertTrue(json.contains("\"value\":28.4"));
        assertTrue(json.contains("\"unit\":\"C\""));
        assertTrue(json.contains("\"location\":\"zone-a\""));
    }
}