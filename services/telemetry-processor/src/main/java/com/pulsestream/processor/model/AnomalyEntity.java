package com.pulsestream.processor.model;

import java.time.Instant;
import java.util.List;

/** Immutable database projection; schema and atomic writes are owned by the processor. */
public record AnomalyEntity(String eventId, String tenantId, Instant timestamp, TelemetryPayload payload,
        AnomalySeverity severity, List<String> reasons, Instant detectedAt, Instant ingestedAt) {
    public AnomalyEntity {
        reasons = List.copyOf(reasons);
    }
}
