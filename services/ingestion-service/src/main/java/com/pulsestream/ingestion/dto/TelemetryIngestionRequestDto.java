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
        @NotBlank String eventId,
        @NotBlank String tenantId,
        @NotBlank String eventType,
        @NotNull @JsonFormat(shape = JsonFormat.Shape.STRING) Instant timestamp,
        @NotBlank String source,
        @NotBlank String version,
        @NotNull @Valid TelemetryPayloadDto payload) {
}
