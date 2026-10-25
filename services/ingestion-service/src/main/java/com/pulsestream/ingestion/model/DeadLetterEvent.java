package com.pulsestream.ingestion.model;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonFormat;
import com.fasterxml.jackson.annotation.JsonProperty;
import java.time.Instant;

/**
 * Envelope published to the dead-letter topic when a telemetry event fails to publish.
 * Wraps the original event together with the failure metadata needed to triage it later.
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
