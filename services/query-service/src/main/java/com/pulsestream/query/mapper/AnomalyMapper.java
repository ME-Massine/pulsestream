package com.pulsestream.query.mapper;

import com.pulsestream.query.dto.AnomalyResponse;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.Arrays;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Component;
import tools.jackson.databind.ObjectMapper;

@Component
public class AnomalyMapper implements RowMapper<AnomalyResponse> {
    private final ObjectMapper mapper;

    public AnomalyMapper(ObjectMapper mapper) {
        this.mapper = mapper;
    }

    @Override
    public AnomalyResponse mapRow(ResultSet row, int rowNumber) throws SQLException {
        return new AnomalyResponse(row.getLong("id"), row.getString("event_id"), row.getString("tenant_id"),
                row.getTimestamp("timestamp").toInstant(), row.getString("device_id"), row.getString("device_type"),
                row.getString("metric"), row.getBigDecimal("value"), row.getString("unit"), row.getString("location"),
                row.getBigDecimal("threshold"), row.getString("anomaly_type"), row.getString("severity"),
                Arrays.asList(mapper.readValue(row.getString("reasons"), String[].class)),
                row.getTimestamp("detected_at").toInstant(), row.getTimestamp("ingested_at").toInstant());
    }
}
