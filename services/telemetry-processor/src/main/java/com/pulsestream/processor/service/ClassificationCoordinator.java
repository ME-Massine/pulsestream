package com.pulsestream.processor.service;

import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.model.*;
import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.LinkedHashMap;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import tools.jackson.databind.ObjectMapper;

/** Serializes current event results independently of raw partition placement. */
@Service
@Transactional(propagation = Propagation.MANDATORY)
public class ClassificationCoordinator {
    private final JdbcTemplate jdbc;
    private final TelemetryProcessingService normal;
    private final AnomalyProcessingService anomaly;
    private final DeliveryOutbox outbox;
    private final TelemetryProcessorKafkaProperties kafka;
    private final ObjectMapper mapper;

    public ClassificationCoordinator(JdbcTemplate jdbc, TelemetryProcessingService normal,
            AnomalyProcessingService anomaly, DeliveryOutbox outbox,
            TelemetryProcessorKafkaProperties kafka, ObjectMapper mapper) {
        this.jdbc = jdbc;
        this.normal = normal;
        this.anomaly = anomaly;
        this.outbox = outbox;
        this.kafka = kafka;
        this.mapper = mapper;
    }

    public void apply(long receipt, TelemetryEvent input, TelemetryAnomalyResult detection, boolean replay) {
        String id = TelemetryEventNormalizer.normalize(input.eventId());
        String tenant = TelemetryEventNormalizer.normalize(input.tenantId());
        org.springframework.util.Assert.hasText(id, "eventId is required");
        org.springframework.util.Assert.hasText(tenant, "tenantId is required");
        jdbc.update("""
                INSERT INTO platform.event_classifications
                    (event_id, tenant_id, classification, revision, first_processed_at)
                VALUES (?, ?, 'UNRESOLVED', 0, now()) ON CONFLICT DO NOTHING
                """, id, tenant);
        var current = jdbc.queryForMap("SELECT * FROM platform.event_classifications WHERE event_id = ? FOR UPDATE", id);
        if (!tenant.equals(current.get("tenant_id"))) {
            throw new DataIntegrityViolationException("Event identifier belongs to another tenant");
        }
        long revision = ((Number) current.get("revision")).longValue();
        // A fresh placeholder has no projection. An unresolved legacy event requires explicit replay.
        boolean hasProjection = Boolean.TRUE.equals(jdbc.queryForObject("""
                SELECT EXISTS (SELECT 1 FROM platform.processed_telemetry WHERE event_id = ?)
                    OR EXISTS (SELECT 1 FROM platform.anomalies WHERE event_id = ?)
                """, Boolean.class, id, id));
        if (!replay && (revision > 0 || hasProjection)) return;
        Instant eventTime = input.timestamp();
        if (eventTime == null) {
            var times = jdbc.query("""
                    SELECT timestamp FROM platform.processed_telemetry WHERE event_id = ?
                    UNION ALL SELECT timestamp FROM platform.anomalies WHERE event_id = ?
                    ORDER BY timestamp LIMIT 1
                    """, (r, n) -> r.getTimestamp(1).toInstant(), id, id);
            eventTime = times.isEmpty() ? ((Timestamp) current.get("first_processed_at")).toInstant() : times.getFirst();
        }
        var event = new TelemetryEvent(id, tenant, input.eventType(), eventTime, input.source(), input.version(), input.payload());
        TelemetryEnvelope output = detection.anomalous() ? anomaly.build(event, detection) : normal.build(event);
        String classification = detection.anomalous() ? "ANOMALY" : "NORMAL";
        var semantic = new LinkedHashMap<String, Object>();
        semantic.put("classification", classification);
        semantic.put("eventTime", BigDecimal.valueOf(eventTime.getEpochSecond()).add(BigDecimal.valueOf(eventTime.getNano(), 9)));
        semantic.put("payload", output.payload());
        if (output instanceof TelemetryAnomalyEvent a) {
            semantic.put("severity", a.severity());
            semantic.put("reasons", a.reasons());
            semantic.put("anomalyType", "rule_violation");
            semantic.put("threshold", null);
        }
        String result = mapper.writeValueAsString(semantic);
        if (Boolean.TRUE.equals(jdbc.queryForObject("SELECT result = CAST(? AS jsonb) FROM platform.event_classifications WHERE event_id = ?",
                Boolean.class, result, id))) return;
        revision++;
        String obsolete = classification.equals("NORMAL") ? "anomalies" : "processed_telemetry";
        jdbc.update("DELETE FROM platform." + obsolete + " WHERE event_id = ? AND tenant_id = ?", id, tenant);
        if (output instanceof TelemetryAnomalyEvent a) anomaly.persistResult(a);
        else normal.persistResult((TelemetryEvent) output);
        String selected = detection.anomalous() ? "anomalies" : "processed_telemetry";
        jdbc.update("UPDATE platform." + selected + " SET ingested_at = ? WHERE event_id = ? AND tenant_id = ?",
                current.get("first_processed_at"), id, tenant);
        jdbc.update("""
                UPDATE platform.event_classifications SET classification = ?, revision = ?, result = CAST(? AS jsonb), changed_at = clock_timestamp()
                WHERE event_id = ?
                """, classification, revision, result, id);
        String previous = current.get("classification").toString();
        boolean retract = hasProjection && !previous.equals(classification);
        if (retract) {
            String destination = detection.anomalous() ? kafka.getTopics().getProcessed() : kafka.getTopics().getAnomalies();
            outbox.enqueue(receipt, destination, id, publication(output, classification, revision, true));
        }
        String destination = detection.anomalous() ? kafka.getTopics().getAnomalies() : kafka.getTopics().getProcessed();
        if (retract) outbox.enqueue(receipt, 1, destination, id, publication(output, classification, revision, false));
        else outbox.enqueue(receipt, destination, id, publication(output, classification, revision, false));
    }

    private String publication(TelemetryEnvelope output, String classification, long revision, boolean retract) {
        boolean anomalyTopic = retract ? classification.equals("NORMAL") : classification.equals("ANOMALY");
        var details = !retract && output instanceof TelemetryAnomalyEvent a ? a : null;
        return mapper.writeValueAsString(new ClassificationPublication(output.eventId(), output.tenantId(),
                anomalyTopic ? "telemetry.anomaly" : "telemetry.processed", output.timestamp(),
                "telemetry-processor", "2.0", retract ? "RETRACT" : "UPSERT", classification, revision,
                retract ? null : output.payload(), details == null ? null : details.severity(),
                details == null ? null : details.reasons(), details == null ? null : details.detectedAt()));
    }
}
