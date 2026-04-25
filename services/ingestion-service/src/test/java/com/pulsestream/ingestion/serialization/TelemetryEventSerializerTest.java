package com.pulsestream.ingestion.serialization;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pulsestream.ingestion.model.TelemetryEvent;
import com.pulsestream.ingestion.model.TelemetryPayload;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class TelemetryEventSerializerTest {

    private final ObjectMapper objectMapper = new ObjectMapper().findAndRegisterModules();
    private final TelemetryEventSerializer serializer =
            new TelemetryEventSerializer(objectMapper);

    @Test
    @DisplayName("should serialize telemetry event to json")
    void shouldSerializeTelemetryEventToJson() throws JsonProcessingException {
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

        JsonNode root = objectMapper.readTree(json);

        assertEquals("evt-001", root.get("eventId").asText());
        assertEquals("factory-01", root.get("tenantId").asText());
        assertEquals("telemetry.reading", root.get("eventType").asText());
        assertEquals("sensor-gateway", root.get("source").asText());
        assertEquals("1.0", root.get("version").asText());
        assertEquals("2026-03-31T12:00:00Z", root.get("timestamp").asText());

        JsonNode payload = root.get("payload");
        assertEquals("sensor-1042", payload.get("deviceId").asText());
        assertEquals("temperature-sensor", payload.get("deviceType").asText());
        assertEquals("temperature", payload.get("metric").asText());
        assertEquals(new BigDecimal("28.4"), payload.get("value").decimalValue());
        assertEquals("C", payload.get("unit").asText());
        assertEquals("zone-a", payload.get("location").asText());
    }

    @Test
    @DisplayName("should wrap serialization exceptions")
    void shouldWrapSerializationException() throws Exception {
        ObjectMapper failingMapper = mock(ObjectMapper.class);

        JsonProcessingException rootCause = new JsonProcessingException("fail") {};
        when(failingMapper.writeValueAsString(any()))
                .thenThrow(rootCause);

        TelemetryEventSerializer serializer =
                new TelemetryEventSerializer(failingMapper);

        TelemetryEvent event = new TelemetryEvent(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                Instant.now(),
                "sensor-gateway",
                "1.0",
                null
        );

        TelemetrySerializationException ex = assertThrows(
                TelemetrySerializationException.class,
                () -> serializer.serialize(event)
        );

        assertEquals("Failed to serialize telemetry event", ex.getMessage());
        assertSame(rootCause, ex.getCause());
    }
}