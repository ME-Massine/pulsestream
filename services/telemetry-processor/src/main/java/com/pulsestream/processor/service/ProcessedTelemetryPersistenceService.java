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
import org.springframework.dao.DataAccessException;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

/**
 * Persists processed telemetry events to PostgreSQL for later querying and analytics.
 *
 * <p>Persistence is a secondary sink behind the {@code telemetry.events.processed} Kafka topic. A
 * slow or unavailable database must never break the processing pipeline, so this method executes
 * asynchronously on a dedicated bounded executor and DB failures are logged rather than propagated.
 * Duplicate inserts — expected under at-least-once redelivery, since {@code event_id} is unique —
 * are treated as a no-op.
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

    @Async("persistenceExecutor")
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
        } catch (DataAccessException ex) {
            if (ex instanceof DataIntegrityViolationException divEx && isUniqueConstraintViolation(divEx)) {
                log.debug(
                        "Skipped persisting duplicate processed telemetry event eventId={}",
                        processedEvent.eventId()
                );
            } else {
                log.error(
                        "Failed to persist processed telemetry event eventId={} tenantId={}",
                        processedEvent.eventId(),
                        processedEvent.tenantId(),
                        ex
                );
            }
        }
    }

    /**
     * Returns true only when the violation is a unique-constraint collision (PostgreSQL "duplicate key").
     * Other integrity failures (NOT NULL, FK, check constraints) return false and are logged at ERROR.
     */
    private static boolean isUniqueConstraintViolation(DataIntegrityViolationException ex) {
        String message = ex.getMostSpecificCause().getMessage();
        return message != null && message.contains("duplicate key");
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
