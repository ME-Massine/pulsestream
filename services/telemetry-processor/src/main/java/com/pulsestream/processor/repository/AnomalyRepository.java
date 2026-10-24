package com.pulsestream.processor.repository;

import com.pulsestream.processor.model.AnomalyEntity;
import java.sql.Timestamp;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;
import tools.jackson.databind.ObjectMapper;

@Repository
public class AnomalyRepository {
    private final NamedParameterJdbcTemplate jdbc;
    private final ObjectMapper mapper;

    public AnomalyRepository(NamedParameterJdbcTemplate jdbc, ObjectMapper mapper) {
        this.jdbc = jdbc;
        this.mapper = mapper;
    }

    /** Commit before returning to the caller, so success metrics include commit failures. */
    @Transactional
    public boolean persist(AnomalyEntity entity, boolean replayed) {
        var payload = entity.payload();
        var parameters = new MapSqlParameterSource("eventId", entity.eventId())
                .addValue("tenantId", entity.tenantId()).addValue("timestamp", Timestamp.from(entity.timestamp()))
                .addValue("deviceId", payload.deviceId()).addValue("deviceType", payload.deviceType())
                .addValue("metric", payload.metric()).addValue("value", payload.value())
                .addValue("unit", payload.unit()).addValue("location", payload.location())
                .addValue("severity", entity.severity().name()).addValue("reasons", mapper.writeValueAsString(entity.reasons()))
                .addValue("detectedAt", Timestamp.from(entity.detectedAt()))
                .addValue("ingestedAt", Timestamp.from(entity.ingestedAt())).addValue("replayed", replayed);
        int changed = jdbc.update("""
                INSERT INTO platform.anomalies AS existing
                    (event_id, tenant_id, timestamp, device_id, device_type, metric, value, unit,
                     location, anomaly_type, severity, reasons, detected_at, ingested_at)
                VALUES (:eventId, :tenantId, :timestamp, :deviceId, :deviceType, :metric, :value, :unit,
                    :location, 'rule_violation', :severity, CAST(:reasons AS jsonb), :detectedAt, :ingestedAt)
                ON CONFLICT (event_id) DO UPDATE SET
                    timestamp = EXCLUDED.timestamp, device_id = EXCLUDED.device_id,
                    device_type = EXCLUDED.device_type, metric = EXCLUDED.metric, value = EXCLUDED.value,
                    unit = EXCLUDED.unit, location = EXCLUDED.location, threshold = NULL,
                    anomaly_type = EXCLUDED.anomaly_type, severity = EXCLUDED.severity,
                    reasons = EXCLUDED.reasons, detected_at = EXCLUDED.detected_at
                WHERE :replayed AND existing.tenant_id = EXCLUDED.tenant_id
                """, parameters);
        if (changed == 0) {
            String tenant = jdbc.queryForObject("SELECT tenant_id FROM platform.anomalies WHERE event_id = :eventId",
                    parameters, String.class);
            if (!entity.tenantId().equals(tenant)) {
                throw new DataIntegrityViolationException("Anomaly event identifier belongs to another tenant");
            }
        }
        return changed > 0;
    }
}
