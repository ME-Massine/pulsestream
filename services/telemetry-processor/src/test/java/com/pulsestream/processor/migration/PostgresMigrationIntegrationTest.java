package com.pulsestream.processor.migration;

import com.pulsestream.processor.TelemetryProcessorApplication;
import com.pulsestream.processor.model.ProcessedTelemetryEntity;
import com.pulsestream.processor.repository.ProcessedTelemetryRepository;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.boot.test.context.ConfigDataApplicationContextInitializer;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.assertj.core.api.Assertions.assertThat;

/** Real PostgreSQL acceptance tests; Docker is required and unavailable Docker fails the build. */
@Testcontainers
class PostgresMigrationIntegrationTest {

    @Container
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16");

    private JdbcTemplate jdbc;
    private ApplicationContextRunner application;

    @BeforeEach
    void emptyDatabase() {
        String database = "migration_" + UUID.randomUUID().toString().replace("-", "");
        template(POSTGRES.getJdbcUrl()).execute("CREATE DATABASE " + database);
        String url = "jdbc:postgresql://" + POSTGRES.getHost() + ":" + POSTGRES.getMappedPort(5432) + "/" + database;
        jdbc = template(url);
        application = new ApplicationContextRunner()
                .withInitializer(new ConfigDataApplicationContextInitializer())
                .withUserConfiguration(TelemetryProcessorApplication.class)
                .withPropertyValues(
                        "spring.datasource.url=" + url,
                        "spring.datasource.username=" + POSTGRES.getUsername(),
                        "spring.datasource.password=" + POSTGRES.getPassword(),
                        "spring.autoconfigure.exclude=org.springframework.boot.kafka.autoconfigure.KafkaAutoConfiguration",
                        "otel.sdk.disabled=true");
    }

    @Test
    void emptyDatabaseStartsProcessorAndPersistsUsingTheMigratedContract() {
        application.run(context -> {
            assertThat(context).hasNotFailed();
            assertThat(context.getBean(Flyway.class).info().current().getVersion().toString()).isEqualTo("3");
            ProcessedTelemetryEntity saved = context.getBean(ProcessedTelemetryRepository.class).saveAndFlush(event("fresh"));
            assertThat(saved.getId()).isEqualTo(1L);
            assertThat(jdbc.queryForObject("SELECT value FROM platform.processed_telemetry", BigDecimal.class))
                    .isEqualByComparingTo("21.5000");
            insertAnomaly();
            assertThat(jdbc.queryForObject("SELECT threshold FROM platform.anomalies", BigDecimal.class))
                    .isEqualByComparingTo("40.0000");
            assertThat(jdbc.queryForObject("SELECT count(*) FROM pg_indexes WHERE schemaname = 'platform'", Integer.class))
                    .isEqualTo(15); // Existing projection indexes plus three state primary keys and expiry index.
        });
    }

    @Test
    void repeatedProcessorStartupPreservesRowsAndDoesNotReapplyV1() {
        application.run(context -> {
            assertThat(context).hasNotFailed();
            context.getBean(ProcessedTelemetryRepository.class).saveAndFlush(event("before-restart"));
            insertAnomaly();
        });
        application.run(context -> {
            assertThat(context).hasNotFailed();
            assertThat(context.getBean(Flyway.class).migrate().migrationsExecuted).isZero();
            assertThat(context.getBean(ProcessedTelemetryRepository.class).findByEventId("before-restart")).isPresent();
            assertThat(context.getBean(ProcessedTelemetryRepository.class).saveAndFlush(event("after-restart")).getId())
                    .isEqualTo(2L);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomalies", Integer.class)).isEqualTo(1);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM pulsestream_migrations.flyway_schema_history WHERE version = '1'",
                    Integer.class)).isEqualTo(1);
        });
    }

    @Test
    void legacySchemaIsAdoptedWithoutBaseliningOrLosingRowsAndSequencePositions() throws Exception {
        legacySchema();
        jdbc.update("""
                INSERT INTO platform.processed_telemetry
                    (event_id, tenant_id, event_type, timestamp, source, device_id, device_type, metric, value, unit, location)
                VALUES ('legacy', 'tenant', 'telemetry.processed', now(), 'processor', 'device', 'sensor', 'temperature', 21.5, 'C', 'room')
                """);
        insertAnomaly();
        application.run(context -> {
            assertThat(context).hasNotFailed();
            ProcessedTelemetryRepository repository = context.getBean(ProcessedTelemetryRepository.class);
            assertThat(repository.findByEventId("legacy")).isPresent();
            assertThat(repository.saveAndFlush(event("new")).getId()).isEqualTo(2L);
            assertThat(jdbc.queryForObject("SELECT value FROM platform.anomalies", BigDecimal.class)).isEqualByComparingTo("45.5000");
            assertThat(context.getBean(Flyway.class).info().current().getType().name()).isEqualTo("SQL");
        });
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "ALTER TABLE platform.processed_telemetry ALTER COLUMN value TYPE numeric(10,2)",
            "ALTER TABLE platform.anomalies ALTER COLUMN severity DROP NOT NULL",
            "ALTER TABLE platform.anomalies DROP CONSTRAINT anomalies_pkey",
            "ALTER TABLE platform.anomalies ALTER COLUMN id DROP DEFAULT",
            "ALTER TABLE platform.anomalies DROP CONSTRAINT anomalies_event_id_key",
            "ALTER TABLE platform.anomalies ALTER COLUMN ingested_at DROP DEFAULT",
            "DROP INDEX platform.idx_anomalies_timestamp; CREATE INDEX idx_anomalies_timestamp ON platform.anomalies (timestamp ASC)"
    })
    void incompatibleLegacyContractPreventsProcessorStartup(String alteration) throws Exception {
        legacySchema();
        insertAnomaly();
        jdbc.execute(alteration);
        application.run(context -> assertThat(context).hasFailed());
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomalies", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM pulsestream_migrations.flyway_schema_history WHERE version = '1'",
                Integer.class)).isZero();
    }

    @ParameterizedTest
    @CsvSource({
            "idx_telemetry_tenant, processed_telemetry, tenant_id",
            "idx_telemetry_device, processed_telemetry, device_id",
            "idx_telemetry_timestamp, processed_telemetry, timestamp DESC",
            "idx_anomalies_tenant, anomalies, tenant_id",
            "idx_anomalies_device, anomalies, device_id",
            "idx_anomalies_timestamp, anomalies, timestamp DESC"
    })
    void uniqueLegacyLookupIndexPreventsProcessorStartup(String index, String table, String column) throws Exception {
        legacySchema();
        insertAnomaly();
        jdbc.execute("DROP INDEX platform." + index);
        jdbc.execute("CREATE UNIQUE INDEX " + index + " ON platform." + table + " (" + column + ")");

        application.run(context -> {
            assertThat(context).hasFailed();
            assertThat(context.getStartupFailure()).hasStackTraceContaining("Incompatible legacy index: platform." + index);
        });
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomalies", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM pulsestream_migrations.flyway_schema_history WHERE version = '1'",
                Integer.class)).isZero();
    }

    @Test
    void checksumMismatchPreventsProcessorStartupWithoutDeletingData() {
        application.run(context -> {
            assertThat(context).hasNotFailed();
            insertAnomaly();
        });
        jdbc.update("UPDATE pulsestream_migrations.flyway_schema_history SET checksum = 0 WHERE version = '1'");
        application.run(context -> assertThat(context).hasFailed());
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomalies", Integer.class)).isEqualTo(1);
    }

    @Test
    void forwardMigrationAppliesAfterV1AndPreservesExistingRows() {
        application.run(context -> {
            assertThat(context).hasNotFailed();
            context.getBean(ProcessedTelemetryRepository.class).saveAndFlush(event("before-upgrade"));
        });
        application.withPropertyValues("spring.flyway.locations=classpath:db/migration,classpath:db/forward")
                .run(context -> {
                    assertThat(context).hasNotFailed();
                    assertThat(context.getBean(Flyway.class).info().current().getVersion().toString()).isEqualTo("4");
                    assertThat(context.getBean(ProcessedTelemetryRepository.class).findByEventId("before-upgrade")).isPresent();
                    assertThat(jdbc.queryForObject("SELECT quality FROM platform.processed_telemetry", String.class)).isEqualTo("unknown");
                });
    }

    @Test
    void simultaneousMigratorsApplyV1OnlyOnce() throws Exception {
        var executor = Executors.newFixedThreadPool(2);
        var start = new CountDownLatch(1);
        try {
            java.util.concurrent.Callable<Integer> migrate = () -> {
                start.await();
                return Flyway.configure().dataSource(jdbc.getDataSource())
                        .defaultSchema("pulsestream_migrations").schemas("pulsestream_migrations")
                        .load().migrate().migrationsExecuted;
            };
            var first = executor.submit(migrate);
            var second = executor.submit(migrate);
            start.countDown();
            assertThat(first.get(30, TimeUnit.SECONDS) + second.get(30, TimeUnit.SECONDS)).isEqualTo(3);
            application.run(context -> assertThat(context).hasNotFailed());
        } finally {
            executor.shutdownNow();
        }
    }

    @Test
    void failedForwardMigrationRollsBackDdlAndStopsStartupThenAllowsThePreviousRelease() {
        application.run(context -> {
            assertThat(context).hasNotFailed();
            insertAnomaly();
        });
        application.withPropertyValues("spring.flyway.locations=classpath:db/migration,classpath:db/failure")
                .run(context -> assertThat(context).hasFailed());
        assertThat(jdbc.queryForObject("SELECT to_regclass('platform.failed_migration')", String.class)).isNull();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform.anomalies", Integer.class)).isEqualTo(1);
        application.run(context -> assertThat(context).hasNotFailed());
    }

    @Test
    void upgradesAnAlreadyVersionedV1WithoutLosingLegacyAnomalyMetadata() {
        Flyway.configure().dataSource(jdbc.getDataSource()).defaultSchema("pulsestream_migrations")
                .target("1").load().migrate();
        insertAnomaly();
        application.run(context -> {
            assertThat(context).hasNotFailed();
            assertThat(context.getBean(Flyway.class).info().current().getVersion().toString()).isEqualTo("3");
            assertThat(jdbc.queryForObject("SELECT threshold FROM platform.anomalies", BigDecimal.class)).isEqualByComparingTo("40");
            assertThat(jdbc.queryForObject("SELECT anomaly_type FROM platform.anomalies", String.class)).isEqualTo("threshold");
            assertThat(jdbc.queryForObject("SELECT reasons::text FROM platform.anomalies", String.class)).isEqualTo("[]");
            assertThat(jdbc.queryForObject("SELECT detected_at = ingested_at FROM platform.anomalies", Boolean.class)).isTrue();
        });
    }

    private void legacySchema() throws Exception {
        // Frozen pre-Flyway script, independent of the production migration under test.
        jdbc.execute(new ClassPathResource("db/legacy/init.sql").getContentAsString(StandardCharsets.UTF_8));
    }

    private void insertAnomaly() {
        jdbc.update("""
                INSERT INTO platform.anomalies
                    (event_id, tenant_id, timestamp, device_id, metric, value, threshold, anomaly_type, severity)
                VALUES ('anomaly', 'tenant', now(), 'device', 'temperature', 45.5, 40, 'threshold', 'high')
                """);
    }

    private JdbcTemplate template(String url) {
        return new JdbcTemplate(new DriverManagerDataSource(url, POSTGRES.getUsername(), POSTGRES.getPassword()));
    }

    private ProcessedTelemetryEntity event(String eventId) {
        return new ProcessedTelemetryEntity(eventId, "tenant", "telemetry.processed", Instant.parse("2026-10-24T12:00:00Z"),
                "processor", "device", "sensor", "temperature", new BigDecimal("21.5000"), "C", "room",
                Instant.parse("2026-10-24T12:00:01Z"));
    }
}
