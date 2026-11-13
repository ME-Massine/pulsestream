package com.pulsestream.processor.service;

import com.pulsestream.processor.model.ProcessedTelemetryEntity;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.repository.ProcessedTelemetryWriteRepository;
import java.time.Clock;
import java.time.Instant;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

/**
 * Persists processed telemetry events to PostgreSQL for later querying and analytics.
 *
 * <p>The raw Kafka record should not be acknowledged until the processed event is stored. Duplicate
 * inserts, expected under at-least-once redelivery because {@code event_id} is unique, are treated
 * as a no-op so retries can continue through the pipeline idempotently.
 */
@Service
public class ProcessedTelemetryPersistenceService {

    private final ProcessedTelemetryWriteRepository repository;
    private final Clock clock;

    @Autowired
    public ProcessedTelemetryPersistenceService(ProcessedTelemetryWriteRepository repository) {
        this(repository, Clock.systemUTC());
    }

    ProcessedTelemetryPersistenceService(ProcessedTelemetryWriteRepository repository, Clock clock) {
        this.repository = repository;
        this.clock = clock;
    }

    public void persist(TelemetryEvent processedEvent) {
        persist(processedEvent, false);
    }

    /**
     * Persists an event projection. A replay replaces the existing projection with the same
     * {@code event_id}; ordinary at-least-once redelivery still treats that collision as a no-op.
     */
    public void persist(TelemetryEvent processedEvent, boolean replayed) {
        Assert.notNull(processedEvent, "processedEvent must not be null");
        Assert.notNull(processedEvent.payload(), "processedEvent payload must not be null");

        repository.persist(toEntity(processedEvent), replayed);
    }

    private ProcessedTelemetryEntity toEntity(TelemetryEvent processedEvent) {
        TelemetryPayload payload = processedEvent.payload();
        return new ProcessedTelemetryEntity(
                processedEvent.eventId(),
                processedEvent.tenantId(),
                processedEvent.eventType(),
                processedEvent.timestamp(),
                processedEvent.source(),
                payload.deviceId(),
                payload.deviceType(),
                payload.metric(),
                payload.value(),
                payload.unit(),
                payload.location(),
                Instant.now(clock)
        );
    }
}
