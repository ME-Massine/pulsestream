package com.pulsestream.processor.service;

import com.pulsestream.processor.model.AnomalySeverity;
import com.pulsestream.processor.model.TelemetryAnomalyEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.repository.AnomalyRepository;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessResourceFailureException;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class AnomalyPersistenceServiceTest {
    private final AnomalyRepository repository = mock(AnomalyRepository.class);
    private final SimpleMeterRegistry registry = new SimpleMeterRegistry();
    private final AnomalyPersistenceService service = new AnomalyPersistenceService(repository, registry);

    @Test
    void mapsProjectionAndCountsWritesDuplicatesAndFailuresSeparately() {
        var event = event("event", "tenant");
        when(repository.persist(any(), eq(true))).thenAnswer(call -> {
            var entity = call.getArgument(0, com.pulsestream.processor.model.AnomalyEntity.class);
            assertThat(entity.eventId()).isEqualTo(event.eventId());
            assertThat(entity.tenantId()).isEqualTo(event.tenantId());
            assertThat(entity.payload()).isEqualTo(event.payload());
            assertThat(entity.reasons()).containsExactly("threshold");
            assertThat(entity.detectedAt()).isEqualTo(event.detectedAt());
            assertThat(entity.ingestedAt()).isNotNull();
            return true;
        });
        service.persist(event, true);
        service.persist(event, false);
        when(repository.persist(any(), eq(false))).thenThrow(new DataAccessResourceFailureException("offline"));
        assertThatThrownBy(() -> service.persist(event, false)).isInstanceOf(DataAccessResourceFailureException.class);
        for (String outcome : List.of("success", "duplicate", "failure")) {
            assertThat(registry.get("pulsestream.anomaly.persistence").tag("outcome", outcome).counter().count()).isEqualTo(1);
        }
    }

    @Test
    void invalidIdentityAndPayloadFailBeforeDatabaseAccessAndIncrementFailureMetric() {
        assertThatThrownBy(() -> service.persist(null, false)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> service.persist(event(" ", "tenant"), false)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> service.persist(event("id", " "), false)).isInstanceOf(IllegalArgumentException.class);
        var event = event("id", "tenant");
        assertThatThrownBy(() -> service.persist(new TelemetryAnomalyEvent(event.eventId(), event.tenantId(), event.eventType(),
                event.timestamp(), event.source(), event.version(), null, event.severity(), event.reasons(), event.detectedAt()), false))
                .isInstanceOf(IllegalArgumentException.class);
        verifyNoInteractions(repository);
        assertThat(registry.get("pulsestream.anomaly.persistence").tag("outcome", "failure").counter().count()).isEqualTo(4);
    }

    private TelemetryAnomalyEvent event(String id, String tenant) {
        return new TelemetryAnomalyEvent(id, tenant, "telemetry.anomaly", Instant.EPOCH, "processor", "1.0",
                new TelemetryPayload("device", "sensor", "temperature", new BigDecimal("95"), "C", "room"),
                AnomalySeverity.WARNING, List.of("threshold"), Instant.EPOCH.plusSeconds(1));
    }
}
