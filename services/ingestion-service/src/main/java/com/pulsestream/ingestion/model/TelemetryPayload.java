package com.pulsestream.ingestion.model;

import java.math.BigDecimal;

public record TelemetryPayload(
        String deviceId,
        String deviceType,
        String metric,
        BigDecimal value,
        String unit,
        String location
) {
}