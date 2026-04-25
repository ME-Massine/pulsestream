package com.pulsestream.ingestion.model;

import com.fasterxml.jackson.annotation.JsonFormat;

import java.time.Instant;

public record TelemetryEvent(
        String eventId,
        String tenantId,
        String eventType,
        @JsonFormat(shape = JsonFormat.Shape.STRING) Instant timestamp,
        String source,
        String version,
        TelemetryPayload payload
) {
}