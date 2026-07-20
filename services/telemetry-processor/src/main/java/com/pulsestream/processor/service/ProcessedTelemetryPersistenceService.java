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
        persist(processedEvent, false);
    }

    /**
     * Persists an event projection. A replay replaces the existing projection with the same
     * {@code event_id}; ordinary at-least-once redelivery still treats that collision as a no-op.
     */
    public void persist(TelemetryEvent processedEvent, boolean replayed) {
        Assert.notNull(processedEvent, "processedEvent must not be null");
        Assert.notNull(processedEvent.payload(), "processedEvent payload must not be null");

        try {
            if (replayed) {
                upsert(toEntity(processedEvent));
            } else {
                repository.save(toEntity(processedEvent));
            }
            log.debug(
                    "Persisted processed telemetry event eventId={} tenantId={} replayed={}",
                    processedEvent.eventId(),
                    processedEvent.tenantId(),
                    replayed
            );
        } catch (DataAccessException ex) {
            if (ex instanceof DataIntegrityViolationException divEx && isUniqueConstraintViolation(divEx)) {
                if (replayed) {
                    replaceAfterConcurrentInsert(toEntity(processedEvent), divEx);
                } else {
                    log.debug(
                            "Skipped persisting duplicate processed telemetry event eventId={}",
                            processedEvent.eventId()
                    );
                }
            } else {
                log.warn(
                        "Failed to persist processed telemetry event eventId={} tenantId={}",
                        processedEvent.eventId(),
                        processedEvent.tenantId(),
                        ex
                );
                throw ex;
            }
        } catch (RuntimeException ex) {
            log.warn(
                    "Unexpected failure persisting processed telemetry event eventId={} tenantId={}",
                    processedEvent.eventId(),
                    processedEvent.tenantId(),
                    ex
            );
            throw ex;
        }
    }

    private void upsert(ProcessedTelemetryEntity replacement) {
        repository.findByEventId(replacement.getEventId())
                .ifPresentOrElse(existing -> {
                    existing.updateFrom(replacement);
                    repository.save(existing);
                }, () -> repository.save(replacement));
    }

    private void replaceAfterConcurrentInsert(
            ProcessedTelemetryEntity replacement,
            DataIntegrityViolationException originalException
    ) {
        ProcessedTelemetryEntity existing = repository.findByEventId(replacement.getEventId())
                .orElseThrow(() -> originalException);
        existing.updateFrom(replacement);
        repository.save(existing);
    }

    /**
     * Returns true only when the violation is a unique-constraint collision (PostgreSQL "duplicate key").
     * Other integrity failures (NOT NULL, FK, check constraints) return false and are propagated.
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
