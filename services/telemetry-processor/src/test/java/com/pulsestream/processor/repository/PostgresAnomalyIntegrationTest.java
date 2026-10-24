package com.pulsestream.processor.repository;

import com.pulsestream.processor.model.AnomalyEntity;
import com.pulsestream.processor.model.AnomalySeverity;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.model.TelemetryAnomalyEvent;
import com.pulsestream.processor.service.AnomalyProcessingService;
import com.pulsestream.processor.service.AnomalyTelemetryPublisher;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

import static org.assertj.core.api.Assertions.*;

/** Required PostgreSQL atomic-write and durability tests. */
@Testcontainers
@SpringBootTest(properties = {
        "spring.autoconfigure.exclude=org.springframework.boot.kafka.autoconfigure.KafkaAutoConfiguration",
        "otel.sdk.disabled=true"
})
class PostgresAnomalyIntegrationTest {
    @Container static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16");
    private static final Instant TIME = Instant.parse("2026-01-01T00:00:00Z");

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry properties) {
        properties.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        properties.add("spring.datasource.username", POSTGRES::getUsername);
        properties.add("spring.datasource.password", POSTGRES::getPassword);
    }

    @Autowired AnomalyRepository repository;
    @Autowired JdbcTemplate jdbc;
    @Autowired Flyway flyway;
    @Autowired AnomalyProcessingService processing;
    @MockitoBean AnomalyTelemetryPublisher publisher;

    @BeforeEach
    void clean() {
        jdbc.execute("TRUNCATE platform.anomalies, platform.processed_telemetry RESTART IDENTITY");
    }

    @Test
    void insertDuplicateAndReplayKeepOneRowStableIdAndFirstIngestionTime() {
        assertThat(repository.persist(entity("id", "tenant", "95", List.of("original")), false)).isTrue();
        var replacement = new AnomalyEntity("id", "tenant", TIME.plusSeconds(10),
                new TelemetryPayload("other-device", "other-type", "humidity", new BigDecimal("99"), "%", "elsewhere"),
                AnomalySeverity.CRITICAL, List.of("updated", "spike"), TIME.plusSeconds(11), TIME.plusSeconds(12));
        assertThat(repository.persist(replacement, false)).isFalse();
        assertThat(jdbc.queryForObject("SELECT value FROM platform.anomalies", BigDecimal.class)).isEqualByComparingTo("95");
        assertThat(repository.persist(replacement, true)).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomalies", Integer.class)).isEqualTo(1);
        var row = jdbc.queryForMap("SELECT * FROM platform.anomalies");
        assertThat(row.get("id")).isEqualTo(1);
        assertThat(row.get("value")).isEqualTo(new BigDecimal("99.0000"));
        assertThat(row.get("severity")).isEqualTo("CRITICAL");
        assertThat(row.get("threshold")).isNull();
        assertThat(row.get("device_id")).isEqualTo("other-device");
        assertThat(row.get("device_type")).isEqualTo("other-type");
        assertThat(row.get("metric")).isEqualTo("humidity");
        assertThat(row.get("unit")).isEqualTo("%");
        assertThat(row.get("location")).isEqualTo("elsewhere");
        assertThat(jdbc.queryForObject("SELECT timestamp FROM platform.anomalies", java.sql.Timestamp.class).toInstant())
                .isEqualTo(TIME.plusSeconds(10));
        assertThat(jdbc.queryForObject("SELECT detected_at FROM platform.anomalies", java.sql.Timestamp.class).toInstant())
                .isEqualTo(TIME.plusSeconds(11));
        assertThat(row.get("reasons").toString()).isEqualTo("[\"updated\", \"spike\"]");
        assertThat(jdbc.queryForObject("SELECT ingested_at FROM platform.anomalies", java.sql.Timestamp.class).toInstant())
                .isEqualTo(TIME.plusSeconds(2));
        assertThat(flyway.migrate().migrationsExecuted).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomalies", Integer.class)).isEqualTo(1);
    }

    @Test
    void missingReadingFieldsAreStoredAndCrossTenantCollisionsAndOtherIntegrityFailuresPropagate() {
        var event = new AnomalyEntity("missing", "tenant", TIME,
                new TelemetryPayload(null, null, null, null, null, null), AnomalySeverity.CRITICAL,
                List.of("value is required"), TIME, TIME);
        assertThat(repository.persist(event, false)).isTrue();
        for (boolean replay : new boolean[] {false, true}) {
            assertThatThrownBy(() -> repository.persist(entity("missing", "other", "99", List.of("reason")), replay))
                    .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        }
        assertThatThrownBy(() -> repository.persist(entity("x".repeat(51), "tenant", "99", List.of()), false))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThat(jdbc.queryForObject("SELECT tenant_id FROM platform.anomalies", String.class)).isEqualTo("tenant");
        assertThat(jdbc.queryForObject("SELECT value FROM platform.anomalies", BigDecimal.class)).isNull();
    }

    @Test
    void concurrentDeliveryAndReplaysAreAtomic() throws Exception {
        try (var executor = Executors.newFixedThreadPool(4)) {
            var start = new CountDownLatch(1);
            var futures = new java.util.ArrayList<java.util.concurrent.Future<Boolean>>();
            for (int i = 0; i < 8; i++) {
                futures.add(executor.submit(() -> {
                    start.await();
                    return repository.persist(entity("concurrent", "tenant", "95", List.of("initial")), false);
                }));
            }
            start.countDown();
            int inserted = 0;
            for (var future : futures) {
                if (future.get(20, TimeUnit.SECONDS)) inserted++;
            }
            assertThat(inserted).isEqualTo(1);
            futures.clear();
            for (int i = 0; i < 8; i++) {
                String value = Integer.toString(100 + i);
                futures.add(executor.submit(() -> repository.persist(entity("new-replay", "tenant", value,
                        List.of("value=" + value)), true)));
            }
            for (var future : futures) assertThat(future.get(20, TimeUnit.SECONDS)).isTrue();
            assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomalies", Integer.class)).isEqualTo(2);
            assertThat(jdbc.queryForObject("""
                    SELECT reasons->>0 = 'value=' || value::integer FROM platform.anomalies WHERE event_id = 'new-replay'
                    """, Boolean.class)).isTrue();
        }
    }

    @Test
    void detectedAnomalyCommitsBeforePublishingAndDoesNotWriteNormalTelemetry() {
        var raw = new com.pulsestream.processor.model.TelemetryEvent("detected", "tenant", "telemetry.reading", TIME,
                "gateway", "1.0", entity("id", "tenant", "95", List.of()).payload());
        var result = com.pulsestream.processor.model.TelemetryAnomalyResult.anomalous(null, AnomalySeverity.WARNING,
                List.of("threshold"));
        org.mockito.Mockito.doAnswer(call -> {
            TelemetryAnomalyEvent event = call.getArgument(0);
            assertThat(jdbc.queryForObject("SELECT event_id FROM platform.anomalies", String.class)).isEqualTo(event.eventId());
            return null;
        }).when(publisher).publish(org.mockito.ArgumentMatchers.any());
        processing.process(raw, result);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.processed_telemetry", Integer.class)).isZero();
    }

    private AnomalyEntity entity(String id, String tenant, String value, List<String> reasons) {
        return new AnomalyEntity(id, tenant, TIME,
                new TelemetryPayload("device", "sensor", "temperature", new BigDecimal(value), "C", "room"),
                AnomalySeverity.WARNING, reasons, TIME.plusSeconds(1), TIME.plusSeconds(2));
    }
}
