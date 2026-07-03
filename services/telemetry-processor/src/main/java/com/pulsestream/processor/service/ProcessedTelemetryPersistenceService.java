package com.pulsestream.processor.service;

import com.pulsestream.processor.model.ProcessedTelemetryEntity;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.repository.ProcessedTelemetryRepository;
import java.time.Clock;
import java.time.Instant;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

/**
 * Persists processed telemetry events to PostgreSQL for later querying and analytics.
 *
 * <p>Persistence is a secondary sink behind the {@code telemetry.events.processed} Kafka topic. A
 * slow or unavailable database must never break the processing pipeline, so persistence failures are
 * logged and swallowed here rather than propagated back to the Kafka listener (which would block the
 * consumer and trigger redelivery). Duplicate inserts — expected under at-least-once redelivery,
 * since {@code event_id} is unique — are treated as a no-op.
 */
@Service
public class ProcessedTelemetryPersistenceService {

    private static final Logger log = LoggerFactory.getLogger(ProcessedTelemetryPersistenceService.class);

    private final ProcessedTelemetryRepository repository;
    private final Clock clock;

    @Autowired
    public ProcessedTelemetryPersistenceService(ProcessedTelemetryRepository repository) {
        this(repository, Clock.systemUTC());
    }

    ProcessedTelemetryPersistenceService(ProcessedTelemetryRepository repository, Clock clock) {
        this.repository = repository;
        this.clock = clock;
    }

    public void persist(TelemetryEvent processedEvent) {
        Assert.notNull(processedEvent, "processedEvent must not be null");
        Assert.notNull(processedEvent.payload(), "processedEvent payload must not be null");

        try {
            repository.save(toEntity(processedEvent));
            log.debug(
                    "Persisted processed telemetry event eventId={} tenantId={}",
                    processedEvent.eventId(),
                    processedEvent.tenantId()
            );
        } catch (DataIntegrityViolationException ex) {
            log.debug(
                    "Skipped persisting duplicate processed telemetry event eventId={}",
                    processedEvent.eventId()
            );
        } catch (RuntimeException ex) {
            log.error(
                    "Failed to persist processed telemetry event eventId={} tenantId={}",
                    processedEvent.eventId(),
                    processedEvent.tenantId(),
                    ex
            );
        }
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
