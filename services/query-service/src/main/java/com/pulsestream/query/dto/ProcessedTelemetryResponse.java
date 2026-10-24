package com.pulsestream.query.dto;

import java.math.BigDecimal;
import java.time.Instant;

public record ProcessedTelemetryResponse(
        long id, String eventId, String tenantId, String eventType, Instant timestamp,
        String source, String deviceId, String deviceType, String metric, BigDecimal value,
        String unit, String location, Instant ingestedAt) {
}
