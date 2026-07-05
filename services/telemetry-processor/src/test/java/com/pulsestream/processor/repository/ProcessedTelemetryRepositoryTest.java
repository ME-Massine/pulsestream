package com.pulsestream.processor.repository;

import com.pulsestream.processor.model.ProcessedTelemetryEntity;
import java.math.BigDecimal;
import java.time.Instant;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;

import static org.assertj.core.api.Assertions.assertThat;

@DataJpaTest(properties = {
        "spring.datasource.url=jdbc:h2:mem:processed-telemetry-repository;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;NON_KEYWORDS=VALUE;INIT=CREATE SCHEMA IF NOT EXISTS platform",
        "spring.datasource.driver-class-name=org.h2.Driver",
        "spring.jpa.database-platform=org.hibernate.dialect.H2Dialect",
        "spring.jpa.hibernate.ddl-auto=create-drop",
        "spring.jpa.properties.hibernate.default_schema=platform"
})
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
class ProcessedTelemetryRepositoryTest {

    @Autowired
    private ProcessedTelemetryRepository repository;

    @Test
    void repositoryIsInjectableAndSavesProcessedTelemetryEvents() {
        ProcessedTelemetryEntity entity = new ProcessedTelemetryEntity(
                "evt-123",
                "tenant-1",
                "telemetry.processed",
                Instant.parse("2026-03-15T12:00:00Z"),
                "telemetry-processor",
                "device-42",
                "temperature-sensor",
                "temperature",
                new BigDecimal("21.5000"),
                "C",
                "warehouse-1",
                Instant.parse("2026-03-15T12:00:05Z")
        );

        ProcessedTelemetryEntity saved = repository.saveAndFlush(entity);

        assertThat(saved.getId()).isNotNull();
        assertThat(repository.findById(saved.getId()))
                .isPresent()
                .get()
                .satisfies(found -> {
                    assertThat(found.getEventId()).isEqualTo("evt-123");
                    assertThat(found.getTenantId()).isEqualTo("tenant-1");
                    assertThat(found.getMetric()).isEqualTo("temperature");
                    assertThat(found.getValue()).isEqualByComparingTo("21.5000");
                    assertThat(found.getIngestedAt()).isEqualTo(Instant.parse("2026-03-15T12:00:05Z"));
                });
    }
}
