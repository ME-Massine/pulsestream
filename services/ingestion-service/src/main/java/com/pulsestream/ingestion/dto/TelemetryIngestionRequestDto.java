package com.pulsestream.ingestion.dto;

import com.fasterxml.jackson.annotation.JsonFormat;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import java.time.Instant;

/**
 * Request DTO for telemetry events received by the ingestion API.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record TelemetryIngestionRequestDto(
        @NotBlank(message = ValidationMessages.EVENT_ID_REQUIRED) String eventId,
        @NotBlank(message = ValidationMessages.TENANT_ID_REQUIRED) String tenantId,
        @NotBlank(message = ValidationMessages.EVENT_TYPE_REQUIRED)
        @Pattern(regexp = "telemetry\\.reading", message = "eventType must be telemetry.reading") String eventType,
        @NotNull(message = ValidationMessages.TIMESTAMP_REQUIRED)
        @JsonFormat(shape = JsonFormat.Shape.STRING)
        Instant timestamp,
        @NotBlank(message = ValidationMessages.SOURCE_REQUIRED) String source,
        @NotBlank(message = ValidationMessages.VERSION_REQUIRED)
        @Pattern(regexp = "1\\.[0-9]+", message = "version must be a supported 1.x version") String version,
        @NotNull(message = ValidationMessages.PAYLOAD_REQUIRED) @Valid TelemetryPayloadDto payload) {
}
