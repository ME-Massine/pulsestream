package com.pulsestream.ingestion.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.math.BigDecimal;

/**
 * Payload DTO for telemetry reading events.
 */
public record TelemetryPayloadDto(
        @NotBlank String deviceId,
        @NotBlank String deviceType,
        @NotBlank String metric,
        @NotNull BigDecimal value,
        @NotBlank String unit,
        @NotBlank String location) {
}
