package com.pulsestream.processor.service;

import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import java.time.Instant;

import org.springframework.stereotype.Service;
import org.springframework.util.Assert;
import org.springframework.util.StringUtils;

@Service
public class TelemetryProcessingService {

    private static final String PROCESSED_EVENT_TYPE = "telemetry.processed";
    private static final String PROCESSED_SOURCE = "telemetry-processor";
    private static final String DEFAULT_VERSION = "1.0";

    private final ProcessedTelemetryPublisher processedTelemetryPublisher;

    public TelemetryProcessingService(ProcessedTelemetryPublisher processedTelemetryPublisher) {
        this.processedTelemetryPublisher = processedTelemetryPublisher;
    }

    public TelemetryEvent process(TelemetryEvent rawEvent) {
        Assert.notNull(rawEvent, "rawEvent must not be null");
        Assert.notNull(rawEvent.payload(), "rawEvent payload must not be null");

        TelemetryEvent processedEvent = new TelemetryEvent(
                normalize(rawEvent.eventId()),
                normalize(rawEvent.tenantId()),
                PROCESSED_EVENT_TYPE,
                rawEvent.timestamp() != null ? rawEvent.timestamp() : Instant.now(),
                PROCESSED_SOURCE,
                defaultIfBlank(rawEvent.version(), DEFAULT_VERSION),
                normalize(rawEvent.payload())
        );

        processedTelemetryPublisher.publish(processedEvent);
        return processedEvent;
    }

    private TelemetryPayload normalize(TelemetryPayload payload) {
        return new TelemetryPayload(
                normalize(payload.deviceId()),
                normalize(payload.deviceType()),
                normalize(payload.metric()),
                payload.value(),
                normalize(payload.unit()),
                normalize(payload.location())
        );
    }

    private String normalize(String value) {
        return StringUtils.hasText(value) ? value.trim() : value;
    }

    private String defaultIfBlank(String value, String fallback) {
        return StringUtils.hasText(value) ? value.trim() : fallback;
    }
}
