package com.pulsestream.processor.model;

import com.fasterxml.jackson.annotation.JsonFormat;
import java.time.Instant;

/**
 * Envelope published to the dead-letter topic when a raw telemetry event fails processing.
 * Wraps the original event together with the failure metadata required to triage it later.
 */
public record DeadLetterEvent(
        TelemetryEvent event,
        String errorReason,
        @JsonFormat(shape = JsonFormat.Shape.STRING) Instant failedAt
) {
}
