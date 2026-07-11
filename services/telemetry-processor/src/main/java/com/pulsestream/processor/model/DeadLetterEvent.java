package com.pulsestream.processor.model;

import com.fasterxml.jackson.annotation.JsonFormat;
import java.time.Instant;

/**
 * Envelope published to the dead-letter topic when a raw telemetry event fails processing.
 * Wraps the original event together with the failure metadata required to triage it later.
 * Shares its field contract with the ingestion-service DLQ envelope so both producers write a
 * consistent structure to the same {@code telemetry.events.dlq} topic; {@code sourceService}
 * identifies which producer emitted the record.
 */
public record DeadLetterEvent(
        TelemetryEvent event,
        String errorMessage,
        String sourceService,
        @JsonFormat(shape = JsonFormat.Shape.STRING) Instant failedAt
) {
}
