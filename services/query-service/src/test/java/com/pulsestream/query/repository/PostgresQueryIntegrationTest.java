package com.pulsestream.query.repository;

import com.pulsestream.query.service.ProcessedTelemetryService;
import com.pulsestream.query.service.TelemetryQuery;
import java.math.BigDecimal;
import java.time.Instant;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.flywaydb.core.Flyway;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** Required real-database tests; unavailable Docker fails rather than skipping. */
@Testcontainers
@SpringBootTest
@AutoConfigureMockMvc
class PostgresQueryIntegrationTest {
    @Container
    static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16");
    private static final Instant TIME = Instant.parse("2026-01-01T12:00:00Z");

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry properties) {
        var owner = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        // Execute the actual processor-owned migration; no divergent test schema.
        Flyway.configure().dataSource(owner).defaultSchema("pulsestream_migrations")
                .locations("filesystem:../telemetry-processor/src/main/resources/db/migration").load().migrate();
        var jdbc = new JdbcTemplate(owner);
        jdbc.execute("CREATE ROLE query_reader LOGIN PASSWORD 'query-test-only'");
        jdbc.execute("GRANT USAGE ON SCHEMA platform TO query_reader");
        jdbc.execute("GRANT SELECT ON platform.processed_telemetry TO query_reader");
        properties.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        properties.add("spring.datasource.username", () -> "query_reader");
        properties.add("spring.datasource.password", () -> "query-test-only");
    }

    @Autowired ProcessedTelemetryRepository repository;
    @Autowired ProcessedTelemetryService service;
    @Autowired JdbcTemplate queryJdbc;
    @Autowired MockMvc mvc;
    private JdbcTemplate owner;

    @BeforeEach
    void seed() {
        owner = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        owner.execute("TRUNCATE platform.processed_telemetry RESTART IDENTITY");
        insert("a-old", "tenant-a", "sensor-1", TIME.minusSeconds(1));
        insert("a-first", "tenant-a", "sensor-1", TIME);
        insert("a-second", "tenant-a", "sensor-2", TIME);
        insert("b-secret", "tenant-b", "sensor-1", TIME.plusSeconds(1));
    }

    @Test
    void tenantScopedOrderingUsesUniqueIdToBreakTimestampTiesAcrossPages() {
        var first = service.query("tenant-a", new TelemetryQuery(null, null, null, 0, 1));
        var second = service.query("tenant-a", new TelemetryQuery(null, null, null, 1, 1));
        var last = service.query("tenant-a", new TelemetryQuery(null, null, null, 2, 1));
        assertThat(first.content()).extracting("eventId").containsExactly("a-second");
        assertThat(second.content()).extracting("eventId").containsExactly("a-first");
        assertThat(last.content()).extracting("eventId").containsExactly("a-old");
        assertThat(first.hasNext()).isTrue();
        assertThat(last.hasNext()).isFalse();
    }

    @Test
    void combinesDeviceAndHalfOpenTimeFiltersAndPreservesNumericAndTimestampValues() {
        var rows = repository.find("tenant-a", new TelemetryQuery("sensor-1", TIME, TIME.plusSeconds(1), 0, 50));
        assertThat(rows).hasSize(1);
        var row = rows.get(0);
        assertThat(row.eventId()).isEqualTo("a-first");
        assertThat(row.value()).isEqualByComparingTo(new BigDecimal("21.1234"));
        assertThat(row.timestamp()).isEqualTo(TIME);
        assertThat(row.ingestedAt()).isEqualTo(TIME);
        assertThat(row.eventType()).isEqualTo("telemetry.processed");
        assertThat(row.source()).isEqualTo("processor");
        assertThat(row.deviceType()).isEqualTo("sensor");
        assertThat(row.metric()).isEqualTo("temperature");
        assertThat(row.unit()).isEqualTo("C");
        assertThat(row.location()).isEqualTo("room");
    }

    @Test
    void optionalBoundsAndInjectionStringsCannotWidenTenantScope() {
        assertThat(repository.find("tenant-a", new TelemetryQuery(null, TIME, null, 0, 50))).hasSize(2);
        assertThat(repository.find("tenant-a", new TelemetryQuery(null, null, TIME, 0, 50)))
                .extracting("eventId").containsExactly("a-old");
        assertThat(repository.find("tenant-a", new TelemetryQuery("' OR 1=1 --", null, null, 0, 50))).isEmpty();
        assertThat(repository.find("' OR 1=1 --", new TelemetryQuery(null, null, null, 0, 50))).isEmpty();
        assertThat(service.query("tenant-a", new TelemetryQuery(null, null, null, 10000, 100)).content()).isEmpty();
    }

    @Test
    void maximumPageSizeReturnsOnlyOneHundredRowsAndLookaheadSignalsNextPage() {
        owner.execute("""
                INSERT INTO platform.processed_telemetry
                    (event_id, tenant_id, event_type, timestamp, source, device_id, device_type,
                     metric, value, unit, location)
                SELECT 'bulk-' || n, 'tenant-a', 'telemetry.processed', now(), 'processor',
                    'bulk-device', 'sensor', 'temperature', 21.1234, 'C', 'room'
                FROM generate_series(1, 105) n
                """);
        var query = new TelemetryQuery("bulk-device", null, null, 0, 100);
        assertThat(repository.find("tenant-a", query)).hasSize(101);
        var page = service.query("tenant-a", query);
        assertThat(page.content()).hasSize(100);
        assertThat(page.hasNext()).isTrue();
        assertThat(service.query("tenant-a", new TelemetryQuery("bulk-device", null, null, 1, 100)).content()).hasSize(5);
    }

    @Test
    void apiCannotOverridePrincipalTenantAndDocumentsAllResponseFields() throws Exception {
        mvc.perform(get("/api/v1/telemetry").principal(() -> "tenant-a").param("deviceId", "sensor-1"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.content.length()").value(2))
                .andExpect(jsonPath("$.content[0].tenantId").value("tenant-a"))
                .andExpect(jsonPath("$.content[0].timestamp").value(TIME.toString()))
                .andExpect(jsonPath("$.content[0].value").value(21.1234));
        mvc.perform(get("/openapi.yaml")).andExpect(status().isOk());
        mvc.perform(get("/api/v1/telemetry").principal(() -> "tenant-a").param("tenantId", "tenant-b"))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.instance").value("/api/v1/telemetry"));
        mvc.perform(get("/api/v1/telemetry").principal(() -> "unknown-tenant"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.content").isEmpty());
    }

    @Test
    void databaseRoleCannotWriteCreateObjectsOrReadAnomalies() {
        assertThatThrownBy(() -> queryJdbc.update("DELETE FROM platform.processed_telemetry"))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(() -> queryJdbc.execute("CREATE TABLE platform.forbidden (id int)"))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(() -> queryJdbc.queryForList("SELECT * FROM platform.anomalies"))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
    }

    @Test
    void healthPolicyKeepsLivenessUpAndMakesReadinessAndQueriesFailWhenDatabaseIsUnavailable() throws Exception {
        mvc.perform(get("/readyz")).andExpect(status().isOk());
        try {
            owner.execute("ALTER ROLE query_reader NOLOGIN");
            owner.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'query_reader'");
            mvc.perform(get("/readyz")).andExpect(status().isServiceUnavailable());
            mvc.perform(get("/actuator/health")).andExpect(status().isServiceUnavailable());
            mvc.perform(get("/livez")).andExpect(status().isOk());
            mvc.perform(get("/api/v1/telemetry").principal(() -> "tenant-a"))
                    .andExpect(status().isServiceUnavailable()).andExpect(jsonPath("$.status").value(503));
        } finally {
            owner.execute("ALTER ROLE query_reader LOGIN");
        }
        mvc.perform(get("/readyz")).andExpect(status().isOk());
    }

    private void insert(String event, String tenant, String device, Instant timestamp) {
        owner.update("""
                INSERT INTO platform.processed_telemetry
                    (event_id, tenant_id, event_type, timestamp, source, device_id, device_type,
                     metric, value, unit, location, ingested_at)
                VALUES (?, ?, 'telemetry.processed', ?, 'processor', ?, 'sensor', 'temperature', 21.1234, 'C', 'room', ?)
                """, event, tenant, java.sql.Timestamp.from(timestamp), device, java.sql.Timestamp.from(TIME));
    }
}
