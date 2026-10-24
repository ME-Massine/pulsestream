package com.pulsestream.query.mapper;

import com.pulsestream.query.dto.ProcessedTelemetryResponse;
import java.sql.ResultSet;
import java.sql.SQLException;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Component;

@Component
public class ProcessedTelemetryMapper implements RowMapper<ProcessedTelemetryResponse> {
    @Override
    public ProcessedTelemetryResponse mapRow(ResultSet row, int rowNumber) throws SQLException {
        return new ProcessedTelemetryResponse(row.getLong("id"), row.getString("event_id"),
                row.getString("tenant_id"), row.getString("event_type"), row.getTimestamp("timestamp").toInstant(),
                row.getString("source"), row.getString("device_id"), row.getString("device_type"),
                row.getString("metric"), row.getBigDecimal("value"), row.getString("unit"),
                row.getString("location"), row.getTimestamp("ingested_at").toInstant());
    }
}
