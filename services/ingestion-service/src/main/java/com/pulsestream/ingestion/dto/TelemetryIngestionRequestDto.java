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
        @NotBlank(message = "eventId is required") String eventId,
        @NotBlank(message = "tenantId is required") String tenantId,
        @NotBlank(message = "eventType is required") String eventType,
        @NotNull(message = "timestamp is required")
        @JsonFormat(shape = JsonFormat.Shape.STRING)
        Instant timestamp,
        @NotBlank(message = "source is required") String source,
        @NotBlank(message = "version is required") String version,
        @NotNull(message = "payload is required") @Valid TelemetryPayloadDto payload) {
}
