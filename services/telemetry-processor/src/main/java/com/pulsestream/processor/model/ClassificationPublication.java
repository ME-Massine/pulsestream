package com.pulsestream.processor.model;

import com.fasterxml.jackson.annotation.JsonInclude;
import java.time.Instant;
import java.util.List;

/** V2 topic projection operation; a retraction deliberately has no result payload. */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record ClassificationPublication(
        String eventId, String tenantId, String eventType, Instant timestamp,
        String source, String version, String operation, String classification,
        long classificationRevision, TelemetryPayload payload, AnomalySeverity severity,
        List<String> reasons, Instant detectedAt) {
    public ClassificationPublication {
        reasons = reasons == null ? null : List.copyOf(reasons);
    }
}
