package com.pulsestream.ingestion.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.math.BigDecimal;

/**
 * Payload DTO for telemetry reading events.
 */
public record TelemetryPayloadDto(
        @NotBlank(message = "deviceId is required") String deviceId,
        @NotBlank(message = "deviceType is required") String deviceType,
        @NotBlank(message = "metric is required") String metric,
        @NotNull(message = "value is required") BigDecimal value,
        @NotBlank(message = "unit is required") String unit,
        @NotBlank(message = "location is required") String location) {
}
