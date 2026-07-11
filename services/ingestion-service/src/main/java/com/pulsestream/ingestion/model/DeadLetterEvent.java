package com.pulsestream.ingestion.model;

import com.fasterxml.jackson.annotation.JsonFormat;
import java.time.Instant;

/**
 * Envelope published to the dead-letter topic when a telemetry event fails to publish.
 * Wraps the original event together with the failure metadata needed to triage it later.
 */
public record DeadLetterEvent(
        TelemetryEvent originalEvent,
        String errorMessage,
        String sourceService,
        @JsonFormat(shape = JsonFormat.Shape.STRING) Instant timestamp
) {
}
