package com.pulsestream.ingestion.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.math.BigDecimal;

/**
 * Payload DTO for telemetry reading events.
 */
public record TelemetryPayloadDto(
        @NotBlank(message = ValidationMessages.DEVICE_ID_REQUIRED) String deviceId,
        @NotBlank(message = ValidationMessages.DEVICE_TYPE_REQUIRED) String deviceType,
        @NotBlank(message = ValidationMessages.METRIC_REQUIRED) String metric,
        @NotNull(message = ValidationMessages.VALUE_REQUIRED) BigDecimal value,
        @NotBlank(message = ValidationMessages.UNIT_REQUIRED) String unit,
        @NotBlank(message = ValidationMessages.LOCATION_REQUIRED) String location) {
}
