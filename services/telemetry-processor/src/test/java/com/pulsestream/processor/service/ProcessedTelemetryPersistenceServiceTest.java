package com.pulsestream.processor.service;

import com.pulsestream.processor.model.ProcessedTelemetryEntity;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.repository.ProcessedTelemetryRepository;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.ArgumentMatchers;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.dao.QueryTimeoutException;

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
    @DisplayName("should treat non-unique DataIntegrityViolationException as a DB failure, not a duplicate")
    void shouldTreatNonUniqueIntegrityViolationAsDbFailure() {
        TelemetryEvent processedEvent = processedEvent("evt-001");
        when(repository.save(ArgumentMatchers.any()))
                .thenThrow(new DataIntegrityViolationException("null value in column violates not-null constraint"));

        assertThatCode(() -> persistenceService.persist(processedEvent)).doesNotThrowAnyException();
    }

    @Test
    @DisplayName("should swallow database failures so the pipeline is not blocked")
    void shouldSwallowDatabaseFailures() {
        TelemetryEvent processedEvent = processedEvent("evt-001");
        when(repository.save(ArgumentMatchers.any()))
                .thenThrow(new QueryTimeoutException("statement timed out"));

        assertThatCode(() -> persistenceService.persist(processedEvent)).doesNotThrowAnyException();
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
