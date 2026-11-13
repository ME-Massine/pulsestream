package com.pulsestream.processor.service;

import com.pulsestream.processor.model.ProcessedTelemetryEntity;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.repository.ProcessedTelemetryWriteRepository;
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
    private ProcessedTelemetryWriteRepository repository;

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
        verify(repository).persist(captor.capture(), org.mockito.ArgumentMatchers.eq(false));

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
    void propagatesInfrastructureAndIntegrityFailures() {
        org.mockito.Mockito.doThrow(new DataIntegrityViolationException("localized database error"))
                .when(repository).persist(ArgumentMatchers.any(), ArgumentMatchers.eq(false));
        assertThatThrownBy(() -> persistenceService.persist(processedEvent("id")))
                .isInstanceOf(DataIntegrityViolationException.class);
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
