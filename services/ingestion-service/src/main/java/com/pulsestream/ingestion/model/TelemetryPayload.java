package com.pulsestream.ingestion.model;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import java.math.BigDecimal;

@JsonIgnoreProperties(ignoreUnknown = true)
public record TelemetryPayload(
        String deviceId,
        String deviceType,
        String metric,
        BigDecimal value,
        String unit,
        String location
) {
}
