package com.pulsestream.processor.service;

import com.pulsestream.processor.model.ProcessedTelemetryEntity;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.repository.ProcessedTelemetryRepository;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Optional;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.ArgumentMatchers;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.transaction.CannotCreateTransactionException;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class ProcessedTelemetryPersistenceServiceTest {

    private static final Instant INGESTED_AT = Instant.parse("2026-03-15T12:06:00Z");

    @Mock
    private ProcessedTelemetryRepository repository;

    private ProcessedTelemetryPersistenceService persistenceService;

    @BeforeEach
    void setUp() {
        Clock clock = Clock.fixed(INGESTED_AT, ZoneOffset.UTC);
        persistenceService = new ProcessedTelemetryPersistenceService(repository, clock);
    }

    @Test
    @DisplayName("should map processed event and persist it")
    void shouldMapProcessedEventAndPersistIt() {
        TelemetryEvent processedEvent = processedEvent("evt-001");

        persistenceService.persist(processedEvent);

        ArgumentCaptor<ProcessedTelemetryEntity> captor = ArgumentCaptor.forClass(ProcessedTelemetryEntity.class);
        verify(repository).save(captor.capture());

        ProcessedTelemetryEntity saved = captor.getValue();
        assertThat(saved.getEventId()).isEqualTo("evt-001");
        assertThat(saved.getTenantId()).isEqualTo("factory-01");
        assertThat(saved.getEventType()).isEqualTo("telemetry.processed");
        assertThat(saved.getTimestamp()).isEqualTo(Instant.parse("2026-03-15T12:05:21Z"));
        assertThat(saved.getSource()).isEqualTo("telemetry-processor");
        assertThat(saved.getDeviceId()).isEqualTo("sensor_1042");
        assertThat(saved.getDeviceType()).isEqualTo("temperature-sensor");
        assertThat(saved.getMetric()).isEqualTo("temperature");
        assertThat(saved.getValue()).isEqualByComparingTo(BigDecimal.valueOf(28.4));
        assertThat(saved.getUnit()).isEqualTo("C");
        assertThat(saved.getLocation()).isEqualTo("zone-a");
        assertThat(saved.getIngestedAt()).isEqualTo(INGESTED_AT);
    }

    @Test
    @DisplayName("should swallow unique-constraint duplicate so the pipeline is not blocked")
    void shouldSwallowDuplicatePersistence() {
        TelemetryEvent processedEvent = processedEvent("evt-001");
        when(repository.save(ArgumentMatchers.any()))
                .thenThrow(new DataIntegrityViolationException("duplicate key value violates unique constraint"));

        assertThatCode(() -> persistenceService.persist(processedEvent)).doesNotThrowAnyException();
    }

    @Test
    @DisplayName("should replace the existing projection when processing a replay")
    void shouldReplaceExistingProjectionWhenProcessingReplay() {
        TelemetryEvent processedEvent = processedEvent("evt-001");
        ProcessedTelemetryEntity existing = new ProcessedTelemetryEntity(
                "evt-001", "old-tenant", "telemetry.processed", Instant.parse("2026-03-01T00:00:00Z"),
                "old-source", "old-device", "old-type", "old-metric", BigDecimal.ONE, "old-unit",
                "old-location", Instant.parse("2026-03-01T00:00:00Z")
        );
        when(repository.findByEventId("evt-001")).thenReturn(Optional.of(existing));

        persistenceService.persist(processedEvent, true);

        verify(repository).save(existing);
        assertThat(existing.getTenantId()).isEqualTo("factory-01");
        assertThat(existing.getMetric()).isEqualTo("temperature");
        assertThat(existing.getIngestedAt()).isEqualTo(INGESTED_AT);
    }

    @Test
    @DisplayName("should propagate non-unique DataIntegrityViolationException so Kafka can retry")
    void shouldPropagateNonUniqueIntegrityViolation() {
        TelemetryEvent processedEvent = processedEvent("evt-001");
        when(repository.save(ArgumentMatchers.any()))
                .thenThrow(new DataIntegrityViolationException("null value in column violates not-null constraint"));

        assertThatThrownBy(() -> persistenceService.persist(processedEvent))
                .isInstanceOf(DataIntegrityViolationException.class);
    }

    @Test
    @DisplayName("should propagate database failures so Kafka can retry")
    void shouldPropagateDatabaseFailures() {
        TelemetryEvent processedEvent = processedEvent("evt-001");
        when(repository.save(ArgumentMatchers.any()))
                .thenThrow(new CannotCreateTransactionException("could not open JDBC connection"));

        assertThatThrownBy(() -> persistenceService.persist(processedEvent))
                .isInstanceOf(CannotCreateTransactionException.class);
    }

    @Test
    @DisplayName("should reject null processed events")
    void shouldRejectNullProcessedEvents() {
        assertThatThrownBy(() -> persistenceService.persist(null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("processedEvent must not be null");

        verifyNoInteractions(repository);
    }

    private TelemetryEvent processedEvent(String eventId) {
        return new TelemetryEvent(
                eventId,
                "factory-01",
                "telemetry.processed",
                Instant.parse("2026-03-15T12:05:21Z"),
                "telemetry-processor",
                "1.0",
                new TelemetryPayload(
                        "sensor_1042",
                        "temperature-sensor",
                        "temperature",
                        BigDecimal.valueOf(28.4),
                        "C",
                        "zone-a"
                )
        );
    }
}
