package com.pulsestream.processor.model;

import com.fasterxml.jackson.annotation.JsonFormat;
import java.time.Instant;
import java.util.List;

/**
 * Telemetry envelope published to {@code telemetry.events.anomalies} when the detection logic flags
 * a reading. In addition to the standard envelope fields it carries the metadata that explains why
 * the event was considered anomalous, so downstream consumers can act on it without re-running
 * detection.
 */
public record TelemetryAnomalyEvent(
        String eventId,
        String tenantId,
        String eventType,
        @JsonFormat(shape = JsonFormat.Shape.STRING) Instant timestamp,
        String source,
        String version,
        TelemetryPayload payload,
        AnomalySeverity severity,
        List<String> reasons,
        @JsonFormat(shape = JsonFormat.Shape.STRING) Instant detectedAt
) implements TelemetryEnvelope {

    public TelemetryAnomalyEvent {
        reasons = reasons == null ? List.of() : List.copyOf(reasons);
    }
}
