package com.pulsestream.query.dto;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;

public record AnomalyResponse(long id, String eventId, String tenantId, Instant timestamp,
        String deviceId, String deviceType, String metric, BigDecimal value, String unit, String location,
        BigDecimal threshold, String anomalyType, String severity, List<String> reasons,
        Instant detectedAt, Instant ingestedAt) {
    public AnomalyResponse {
        reasons = List.copyOf(reasons);
    }
}
