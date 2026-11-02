package com.pulsestream.processor.service;

import com.pulsestream.processor.config.AnomalyDetectionProperties;
import com.pulsestream.processor.exception.AnomalyStateException;
import com.pulsestream.processor.model.AnomalySeverity;
import com.pulsestream.processor.model.NormalizedTelemetryEvent;
import com.pulsestream.processor.model.TelemetryAnomalyResult;
import com.pulsestream.processor.model.TelemetryEvent;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.List;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.util.StringUtils;
import tools.jackson.databind.json.JsonMapper;

/** Durable, bounded state; one database transaction and lock per raw-topic partition. */
@Service
public class AnomalyStateService {
    private final JdbcTemplate jdbc;
    private final TransactionTemplate transaction;
    private final AnomalyDetectionProperties properties;
    private final TelemetryAnomalyDetectionService detector;
    private final JsonMapper json = JsonMapper.builder().build();

    public AnomalyStateService(JdbcTemplate jdbc, PlatformTransactionManager transactionManager,
            AnomalyDetectionProperties properties, TelemetryAnomalyDetectionService detector) {
        this.jdbc = jdbc;
        this.transaction = new TransactionTemplate(transactionManager);
        this.properties = properties;
        this.detector = detector;
    }

    public TelemetryAnomalyResult detect(NormalizedTelemetryEvent event, ConsumerRecord<String, TelemetryEvent> record) {
        try {
            if (StringUtils.hasText(event.tenantId()) && StringUtils.hasText(event.deviceId())
                    && !TelemetryOrderingKey.of(event.tenantId(), event.deviceId()).equals(record.key())) {
                throw new AnomalyStateException("Raw record does not use the tenant/device ordering key; stop and migrate producers");
            }
            if (record.timestamp() < 0) {
                throw new AnomalyStateException("Raw record timestamp is required for deterministic retention");
            }
            return transaction.execute(status -> detectLocked(event, record));
        } catch (AnomalyStateException ex) {
            throw ex;
        } catch (RuntimeException ex) {
            throw new AnomalyStateException("Anomaly state transaction failed; raw consumption must stop", ex);
        }
    }

    private TelemetryAnomalyResult detectLocked(NormalizedTelemetryEvent event, ConsumerRecord<String, TelemetryEvent> record) {
        String topic = record.topic();
        int partition = record.partition();
        String configuration = properties.toString();
        jdbc.update("""
                INSERT INTO platform.anomaly_partition_state (topic, partition_id, configuration)
                VALUES (?, ?, ?) ON CONFLICT DO NOTHING
                """, topic, partition, configuration);
        var checkpoint = jdbc.queryForMap("""
                SELECT last_offset, stream_time, configuration FROM platform.anomaly_partition_state
                WHERE topic = ? AND partition_id = ? FOR UPDATE
                """, topic, partition);
        if (!configuration.equals(checkpoint.get("configuration"))) {
            throw new AnomalyStateException("Anomaly configuration differs from durable state; coordinated migration required");
        }
        String inputHash = hash(record.key() + "\n" + record.timestamp() + "\n" + json.writeValueAsString(record.value()));
        var decisions = jdbc.query("""
                SELECT input_hash, severity, reasons::text FROM platform.anomaly_decisions
                WHERE topic = ? AND partition_id = ? AND record_offset = ?
                """, (row, index) -> {
                    if (!inputHash.equals(row.getString(1))) {
                        throw new AnomalyStateException("Record at a retained offset changed; topic recreation requires state migration");
                    }
                    AnomalySeverity severity = AnomalySeverity.valueOf(row.getString(2));
                    List<String> reasons = json.readValue(row.getString(3),
                            new tools.jackson.core.type.TypeReference<List<String>>() { });
                    return new TelemetryAnomalyResult(event, severity != AnomalySeverity.NONE, severity, reasons);
                }, topic, partition, record.offset());
        if (!decisions.isEmpty()) return decisions.getFirst();
        if (record.offset() <= ((Number) checkpoint.get("last_offset")).longValue()) {
            throw new AnomalyStateException("Offset predates retained anomaly decisions; explicit recovery required");
        }

        long streamTime = Math.max(record.timestamp(), ((Number) checkpoint.get("stream_time")).longValue());
        jdbc.update("DELETE FROM platform.anomaly_reading_state WHERE topic = ? AND partition_id = ? AND seen_at <= ?",
                topic, partition, streamTime - properties.stateRetention().toMillis());
        TelemetryAnomalyResult result = detector.detect(event);
        // Critical results cannot supply a usable baseline (identity, measurement or unit missing/incompatible).
        if (result.severity() != AnomalySeverity.CRITICAL) {
            var previous = jdbc.query("""
                    SELECT value FROM platform.anomaly_reading_state
                    WHERE topic = ? AND partition_id = ? AND tenant_id = ? AND device_id = ? AND metric = ? AND unit = ?
                    """, (row, index) -> row.getBigDecimal(1), topic, partition,
                    event.tenantId(), event.deviceId(), event.metric(), event.unit());
            if (previous.isEmpty() && jdbc.queryForObject("""
                    SELECT count(*) FROM platform.anomaly_reading_state WHERE topic = ? AND partition_id = ?
                    """, Integer.class, topic, partition) >= properties.maxKeysPerPartition()) {
                throw new AnomalyStateException("Anomaly state key capacity reached; no active baseline was evicted");
            }
            BigDecimal baseline = previous.isEmpty() ? null : previous.getFirst();
            result = detector.detect(event, baseline);
            jdbc.update("""
                    INSERT INTO platform.anomaly_reading_state
                        (topic, partition_id, tenant_id, device_id, metric, unit, value, seen_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (topic, partition_id, tenant_id, device_id, metric, unit)
                    DO UPDATE SET value = EXCLUDED.value, seen_at = EXCLUDED.seen_at
                    """, topic, partition, event.tenantId(), event.deviceId(), event.metric(), event.unit(), event.value(), streamTime);
        }
        jdbc.update("""
                INSERT INTO platform.anomaly_decisions (topic, partition_id, record_offset, input_hash, severity, reasons)
                VALUES (?, ?, ?, ?, ?, ?::jsonb)
                """, topic, partition, record.offset(), inputHash, result.severity().name(), json.writeValueAsString(result.reasons()));
        jdbc.update("""
                DELETE FROM platform.anomaly_decisions WHERE topic = ? AND partition_id = ? AND record_offset IN
                    (SELECT record_offset FROM platform.anomaly_decisions WHERE topic = ? AND partition_id = ?
                     ORDER BY record_offset DESC OFFSET ?)
                """, topic, partition, topic, partition, properties.decisionsPerPartition());
        jdbc.update("""
                UPDATE platform.anomaly_partition_state SET last_offset = ?, stream_time = ? WHERE topic = ? AND partition_id = ?
                """, record.offset(), streamTime, topic, partition);
        return result;
    }

    private String hash(String value) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException ex) {
            throw new IllegalStateException(ex);
        }
    }
}
