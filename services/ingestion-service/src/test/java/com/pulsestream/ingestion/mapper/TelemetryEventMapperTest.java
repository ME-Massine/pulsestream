package com.pulsestream.ingestion.mapper;

import com.pulsestream.ingestion.dto.TelemetryIngestionRequestDto;
import com.pulsestream.ingestion.dto.TelemetryPayloadDto;
import com.pulsestream.ingestion.model.TelemetryEvent;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.*;

class TelemetryEventMapperTest {

    private final TelemetryEventMapper mapper = new TelemetryEventMapper();

    @Test
    @DisplayName("should map telemetry ingestion request dto to internal telemetry event")
    void shouldMapTelemetryIngestionRequestDtoToInternalModel() {
        TelemetryIngestionRequestDto request = new TelemetryIngestionRequestDto(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                Instant.parse("2026-03-31T12:00:00Z"),
                "sensor-gateway",
                "1.0",
                new TelemetryPayloadDto(
                        "sensor-1042",
                        "temperature-sensor",
                        "temperature",
                        new BigDecimal("28.4"),
                        "C",
                        "zone-a"
                )
        );

        TelemetryEvent result = mapper.toModel(request);

        assertNotNull(result);
        assertEquals("evt-001", result.eventId());
        assertEquals("factory-01", result.tenantId());
        assertEquals("telemetry.reading", result.eventType());
        assertEquals(Instant.parse("2026-03-31T12:00:00Z"), result.timestamp());
        assertEquals("sensor-gateway", result.source());
        assertEquals("1.0", result.version());

        assertNotNull(result.payload());
        assertEquals("sensor-1042", result.payload().deviceId());
        assertEquals("temperature-sensor", result.payload().deviceType());
        assertEquals("temperature", result.payload().metric());
        assertEquals(new BigDecimal("28.4"), result.payload().value());
        assertEquals("C", result.payload().unit());
        assertEquals("zone-a", result.payload().location());
    }
}