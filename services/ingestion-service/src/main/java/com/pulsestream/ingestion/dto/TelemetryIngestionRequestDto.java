package com.pulsestream.ingestion.dto;

import com.fasterxml.jackson.annotation.JsonFormat;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.time.Instant;

/**
 * Request DTO for telemetry events received by the ingestion API.
 */
public record TelemetryIngestionRequestDto(
        @NotBlank(message = ValidationMessages.EVENT_ID_REQUIRED) String eventId,
        @NotBlank(message = ValidationMessages.TENANT_ID_REQUIRED) String tenantId,
        @NotBlank(message = ValidationMessages.EVENT_TYPE_REQUIRED) String eventType,
        @NotNull(message = ValidationMessages.TIMESTAMP_REQUIRED)
        @JsonFormat(shape = JsonFormat.Shape.STRING)
        Instant timestamp,
        @NotBlank(message = ValidationMessages.SOURCE_REQUIRED) String source,
        @NotBlank(message = ValidationMessages.VERSION_REQUIRED) String version,
        @NotNull(message = ValidationMessages.PAYLOAD_REQUIRED) @Valid TelemetryPayloadDto payload) {
}
