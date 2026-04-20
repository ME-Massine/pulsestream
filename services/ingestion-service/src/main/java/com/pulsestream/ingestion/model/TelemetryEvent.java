package com.pulsestream.ingestion.model;

import java.time.Instant;

public record TelemetryEvent(
        String eventId,
        String tenantId,
        String eventType,
        Instant timestamp,
        String source,
        String version,
        TelemetryPayload payload
) {
}