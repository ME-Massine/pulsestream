package com.pulsestream.processor.model;

import java.time.Instant;

/**
 * Common envelope contract shared by every telemetry message the processor publishes to Kafka.
 *
 * <p>Having a single sealed type lets the outbound {@code KafkaTemplate} serialize both processed
 * events and anomaly events while keeping the message key resolution logic uniform across
 * publishers.
 */
public sealed interface TelemetryEnvelope permits TelemetryEvent, TelemetryAnomalyEvent {

    String eventId();

    String tenantId();

    String eventType();

    Instant timestamp();

    String source();

    String version();

    TelemetryPayload payload();
}
