package com.pulsestream.query.repository;

import com.pulsestream.query.dto.ProcessedTelemetryResponse;
import com.pulsestream.query.mapper.ProcessedTelemetryMapper;
import com.pulsestream.query.service.TelemetryQuery;
import java.sql.Timestamp;
import java.util.List;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

/** Read-only access to the schema owned by telemetry-processor migrations. */
@Repository
public class ProcessedTelemetryRepository {
    private final NamedParameterJdbcTemplate jdbc;
    private final ProcessedTelemetryMapper mapper;

    public ProcessedTelemetryRepository(NamedParameterJdbcTemplate jdbc, ProcessedTelemetryMapper mapper) {
        this.jdbc = jdbc;
        this.mapper = mapper;
    }

    public List<ProcessedTelemetryResponse> find(String tenantId, TelemetryQuery query) {
        StringBuilder sql = new StringBuilder("""
                SELECT id, event_id, tenant_id, event_type, timestamp, source, device_id,
                    device_type, metric, value, unit, location, ingested_at
                FROM platform.processed_telemetry WHERE tenant_id = :tenantId
                """);
        MapSqlParameterSource parameters = new MapSqlParameterSource("tenantId", tenantId);
        if (query.deviceId() != null) {
            sql.append(" AND device_id = :deviceId");
            parameters.addValue("deviceId", query.deviceId());
        }
        if (query.from() != null) {
            sql.append(" AND timestamp >= :from");
            parameters.addValue("from", Timestamp.from(query.from()));
        }
        if (query.to() != null) {
            sql.append(" AND timestamp < :to");
            parameters.addValue("to", Timestamp.from(query.to()));
        }
        sql.append(" ORDER BY timestamp DESC, id DESC LIMIT :limit OFFSET :offset");
        parameters.addValue("limit", query.size() + 1);
        parameters.addValue("offset", (long) query.page() * query.size());
        return jdbc.query(sql.toString(), parameters, mapper);
    }
}
