package com.pulsestream.processor.model;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonFormat;
import com.fasterxml.jackson.annotation.JsonProperty;
import java.time.Instant;

/**
 * Envelope published to the dead-letter topic when a raw telemetry event fails processing.
 * Wraps the original event together with the failure metadata required to triage it later.
 * Shares its field contract with the ingestion-service DLQ envelope so both producers write a
 * consistent structure to the same {@code telemetry.events.dlq} topic; {@code sourceService}
 * identifies which producer emitted the record.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record DeadLetterEvent(
        TelemetryEvent event,
        String errorMessage,
        String sourceService,
        @JsonFormat(shape = JsonFormat.Shape.STRING) Instant failedAt
) {
    /** Historical envelopes without a version are implicitly v1.0. */
    @JsonProperty(value = "version", access = JsonProperty.Access.READ_ONLY)
    public String version() {
        return "1.0";
    }
}
