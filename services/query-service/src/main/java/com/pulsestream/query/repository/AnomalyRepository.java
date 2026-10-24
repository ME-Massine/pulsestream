package com.pulsestream.query.repository;

import com.pulsestream.query.dto.AnomalyResponse;
import com.pulsestream.query.mapper.AnomalyMapper;
import com.pulsestream.query.service.AnomalyQuery;
import java.sql.Timestamp;
import java.util.List;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

@Repository
public class AnomalyRepository {
    private final NamedParameterJdbcTemplate jdbc;
    private final AnomalyMapper mapper;

    public AnomalyRepository(NamedParameterJdbcTemplate jdbc, AnomalyMapper mapper) {
        this.jdbc = jdbc;
        this.mapper = mapper;
    }

    public List<AnomalyResponse> find(String tenantId, AnomalyQuery query) {
        var filters = query.telemetry();
        StringBuilder sql = new StringBuilder("""
                SELECT id, event_id, tenant_id, timestamp, device_id, device_type, metric, value,
                    unit, location, threshold, anomaly_type, severity, reasons, detected_at, ingested_at
                FROM platform.anomalies WHERE tenant_id = :tenantId
                """);
        var parameters = new MapSqlParameterSource("tenantId", tenantId);
        if (filters.deviceId() != null) {
            sql.append(" AND device_id = :deviceId");
            parameters.addValue("deviceId", filters.deviceId());
        }
        if (query.severity() != null) {
            sql.append(" AND severity = :severity");
            parameters.addValue("severity", query.severity());
        }
        if (query.metric() != null) {
            sql.append(" AND metric = :metric");
            parameters.addValue("metric", query.metric());
        }
        if (filters.from() != null) {
            sql.append(" AND timestamp >= :from");
            parameters.addValue("from", Timestamp.from(filters.from()));
        }
        if (filters.to() != null) {
            sql.append(" AND timestamp < :to");
            parameters.addValue("to", Timestamp.from(filters.to()));
        }
        sql.append(" ORDER BY timestamp DESC, id DESC LIMIT :limit OFFSET :offset");
        parameters.addValue("limit", filters.size() + 1);
        parameters.addValue("offset", (long) filters.page() * filters.size());
        return jdbc.query(sql.toString(), parameters, mapper);
    }
}
