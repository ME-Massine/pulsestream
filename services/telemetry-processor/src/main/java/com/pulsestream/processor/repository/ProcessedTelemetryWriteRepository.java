package com.pulsestream.processor.repository;

import com.pulsestream.processor.model.ProcessedTelemetryEntity;
import java.sql.Timestamp;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

@Repository
public class ProcessedTelemetryWriteRepository {
    private final NamedParameterJdbcTemplate jdbc;

    public ProcessedTelemetryWriteRepository(NamedParameterJdbcTemplate jdbc) { this.jdbc = jdbc; }

    @Transactional
    public void persist(ProcessedTelemetryEntity event, boolean replayed) {
        var parameters = new MapSqlParameterSource("eventId", event.getEventId())
                .addValue("tenantId", event.getTenantId()).addValue("eventType", event.getEventType())
                .addValue("timestamp", Timestamp.from(event.getTimestamp())).addValue("source", event.getSource())
                .addValue("deviceId", event.getDeviceId()).addValue("deviceType", event.getDeviceType())
                .addValue("metric", event.getMetric()).addValue("value", event.getValue())
                .addValue("unit", event.getUnit()).addValue("location", event.getLocation())
                .addValue("ingestedAt", Timestamp.from(event.getIngestedAt())).addValue("replayed", replayed);
        int changed = jdbc.update("""
                INSERT INTO platform.processed_telemetry AS existing
                    (event_id, tenant_id, event_type, timestamp, source, device_id, device_type,
                     metric, value, unit, location, ingested_at)
                VALUES (:eventId, :tenantId, :eventType, :timestamp, :source, :deviceId, :deviceType,
                    :metric, :value, :unit, :location, :ingestedAt)
                ON CONFLICT (event_id) DO UPDATE SET
                    event_type = EXCLUDED.event_type, timestamp = EXCLUDED.timestamp, source = EXCLUDED.source,
                    device_id = EXCLUDED.device_id, device_type = EXCLUDED.device_type, metric = EXCLUDED.metric,
                    value = EXCLUDED.value, unit = EXCLUDED.unit, location = EXCLUDED.location,
                    ingested_at = EXCLUDED.ingested_at
                WHERE :replayed AND existing.tenant_id = EXCLUDED.tenant_id
                """, parameters);
        if (changed == 0) {
            String tenant = jdbc.queryForObject("SELECT tenant_id FROM platform.processed_telemetry WHERE event_id = :eventId",
                    parameters, String.class);
            if (!event.getTenantId().equals(tenant)) {
                throw new DataIntegrityViolationException("Processed event identifier belongs to another tenant");
            }
        }
    }
}
