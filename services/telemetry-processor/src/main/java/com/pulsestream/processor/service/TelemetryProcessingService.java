package com.pulsestream.processor.service;

import com.pulsestream.processor.model.TelemetryEvent;
import java.time.Clock;
import java.time.Instant;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

@Service
public class TelemetryProcessingService {

    private static final String PROCESSED_EVENT_TYPE = "telemetry.processed";
    private static final String PROCESSED_SOURCE = "telemetry-processor";
    private static final String DEFAULT_VERSION = "1.0";

    private final ProcessedTelemetryPublisher processedTelemetryPublisher;
    private final ProcessedTelemetryPersistenceService persistenceService;
    private final Clock clock;

    @Autowired
    public TelemetryProcessingService(
            ProcessedTelemetryPublisher processedTelemetryPublisher,
            ProcessedTelemetryPersistenceService persistenceService
    ) {
        this(processedTelemetryPublisher, persistenceService, Clock.systemUTC());
    }

    TelemetryProcessingService(
            ProcessedTelemetryPublisher processedTelemetryPublisher,
            ProcessedTelemetryPersistenceService persistenceService,
            Clock clock
    ) {
        this.processedTelemetryPublisher = processedTelemetryPublisher;
        this.persistenceService = persistenceService;
        this.clock = clock;
    }

    public TelemetryEvent process(TelemetryEvent rawEvent) {
        Assert.notNull(rawEvent, "rawEvent must not be null");
        Assert.notNull(rawEvent.payload(), "rawEvent payload must not be null");

        TelemetryEvent processedEvent = new TelemetryEvent(
                TelemetryEventNormalizer.normalize(rawEvent.eventId()),
                TelemetryEventNormalizer.normalize(rawEvent.tenantId()),
                PROCESSED_EVENT_TYPE,
                rawEvent.timestamp() != null ? rawEvent.timestamp() : Instant.now(clock),
                PROCESSED_SOURCE,
                TelemetryEventNormalizer.defaultIfBlank(rawEvent.version(), DEFAULT_VERSION),
                TelemetryEventNormalizer.normalizePayload(rawEvent.payload())
        );

        processedTelemetryPublisher.publish(processedEvent);
        persistenceService.persist(processedEvent);
        return processedEvent;
    }
}
