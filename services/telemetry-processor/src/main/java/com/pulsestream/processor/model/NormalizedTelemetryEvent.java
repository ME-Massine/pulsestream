package com.pulsestream.processor.model;

import java.math.BigDecimal;
import java.time.Instant;

public record NormalizedTelemetryEvent(
        String eventId,
        String tenantId,
        String eventType,
        Instant timestamp,
        String source,
        String version,
        String deviceId,
        String deviceType,
        String metric,
        BigDecimal value,
        String unit,
        String location
) {
}