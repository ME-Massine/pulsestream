package com.pulsestream.ingestion.model;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import com.fasterxml.jackson.annotation.JsonFormat;

import java.time.Instant;

@JsonIgnoreProperties(ignoreUnknown = true)
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
