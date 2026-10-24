package com.pulsestream.processor.service;

import com.pulsestream.processor.model.AnomalyEntity;
import com.pulsestream.processor.model.TelemetryAnomalyEvent;
import com.pulsestream.processor.repository.AnomalyRepository;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import java.time.Instant;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

@Service
public class AnomalyPersistenceService {
    private final AnomalyRepository repository;
    private final Counter success;
    private final Counter duplicate;
    private final Counter failure;

    public AnomalyPersistenceService(AnomalyRepository repository, MeterRegistry registry) {
        this.repository = repository;
        success = registry.counter("pulsestream.anomaly.persistence", "outcome", "success");
        duplicate = registry.counter("pulsestream.anomaly.persistence", "outcome", "duplicate");
        failure = registry.counter("pulsestream.anomaly.persistence", "outcome", "failure");
    }

    public void persist(TelemetryAnomalyEvent event, boolean replayed) {
        try {
            Assert.notNull(event, "anomaly event must not be null");
            Assert.hasText(event.eventId(), "eventId is required for anomaly persistence");
            Assert.hasText(event.tenantId(), "tenantId is required for anomaly persistence");
            Assert.notNull(event.payload(), "anomaly payload must not be null");
            var entity = new AnomalyEntity(event.eventId(), event.tenantId(), event.timestamp(), event.payload(),
                    event.severity(), event.reasons(), event.detectedAt(), Instant.now());
            if (repository.persist(entity, replayed)) {
                success.increment();
            } else {
                duplicate.increment();
            }
        } catch (RuntimeException ex) {
            failure.increment();
            throw ex;
        }
    }
}
