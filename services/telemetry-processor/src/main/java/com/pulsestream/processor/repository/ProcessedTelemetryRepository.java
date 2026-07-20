package com.pulsestream.processor.repository;

import com.pulsestream.processor.model.ProcessedTelemetryEntity;
import java.util.Optional;
import org.springframework.data.jpa.repository.JpaRepository;

/**
 * Spring Data JPA repository for persisted processed telemetry events.
 */
public interface ProcessedTelemetryRepository extends JpaRepository<ProcessedTelemetryEntity, Long> {

    Optional<ProcessedTelemetryEntity> findByEventId(String eventId);
}
