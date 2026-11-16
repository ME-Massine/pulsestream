package com.pulsestream.processor.service;

import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.model.ClassificationPublication;
import com.pulsestream.processor.model.TelemetryAnomalyEvent;
import com.pulsestream.processor.model.TelemetryAnomalyResult;
import com.pulsestream.processor.model.TelemetryEnvelope;
import com.pulsestream.processor.model.TelemetryEvent;
import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.LinkedHashMap;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.Assert;
import tools.jackson.databind.ObjectMapper;

/**
 * Serializes current event results independently of raw partition placement.
 *
 * <p>The event's classification row lock orders every database write and its outbox rows. The outbox
 * dispatcher then delivers the rows of one event in commit order across source partitions, so a topic
 * consumer never sees an older revision after a newer one from this processor.
 */
@Service
@Transactional(propagation = Propagation.MANDATORY)
public class ClassificationCoordinator {
    private static final String NORMAL = "NORMAL";
    private static final String ANOMALY = "ANOMALY";
    private static final String DELETE_NORMAL =
            "DELETE FROM platform.processed_telemetry WHERE event_id = ? AND tenant_id = ?";
    private static final String DELETE_ANOMALY =
            "DELETE FROM platform.anomalies WHERE event_id = ? AND tenant_id = ?";

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
        Assert.hasText(id, "eventId is required");
        Assert.hasText(tenant, "tenantId is required");
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
        // A classified event ignores ordinary redelivery. An unresolved one (a fresh placeholder, a legacy
        // contradiction or a row written before this version) takes the first record that reaches it, so
        // it never stays hidden from queries until an operator replays it.
        if (!replay && revision > 0) {
            if (detection.anomalous()) anomaly.recordDuplicate(); // Keeps the documented duplicate outcome counter.
            return;
        }
        Instant eventTime = input.timestamp();
        if (eventTime == null) {
            var times = jdbc.query("""
                    SELECT timestamp FROM platform.processed_telemetry WHERE event_id = ?
                    UNION ALL SELECT timestamp FROM platform.anomalies WHERE event_id = ?
                    ORDER BY timestamp LIMIT 1
                    """, (r, n) -> r.getTimestamp(1).toInstant(), id, id);
            eventTime = times.isEmpty() ? ((Timestamp) current.get("first_processed_at")).toInstant() : times.getFirst();
        }
        // PostgreSQL stores microseconds; compare and persist exactly what is stored.
        eventTime = eventTime.truncatedTo(ChronoUnit.MICROS);
        var event = new TelemetryEvent(id, tenant, input.eventType(), eventTime, input.source(), input.version(), input.payload());
        boolean anomalous = detection.anomalous();
        TelemetryEnvelope output = anomalous ? anomaly.build(event, detection) : normal.build(event);
        String classification = anomalous ? ANOMALY : NORMAL;
        String result = mapper.writeValueAsString(semantic(classification, eventTime, output));
        if (Boolean.TRUE.equals(jdbc.queryForObject(
                "SELECT result = CAST(? AS jsonb) FROM platform.event_classifications WHERE event_id = ?",
                Boolean.class, result, id))) {
            restoreMissingProjection(output, id, ((Timestamp) current.get("first_processed_at")).toInstant());
            return;
        }
        long previousRevision = revision;
        revision++;
        // Retract what was published for the opposite class. That is known from a deleted projection row or,
        // if the row was lost, from the previous resolved classification. An unresolved event publishes nothing.
        String previous = current.get("classification").toString();
        boolean deleted = jdbc.update(anomalous ? DELETE_NORMAL : DELETE_ANOMALY, id, tenant) > 0;
        boolean retract = deleted || (previousRevision > 0 && !previous.equals(classification));
        Instant ingestedAt = ((Timestamp) current.get("first_processed_at")).toInstant();
        if (output instanceof TelemetryAnomalyEvent a) anomaly.persistAuthoritative(a, ingestedAt);
        else normal.persistAuthoritative((TelemetryEvent) output, ingestedAt);
        jdbc.update("""
                UPDATE platform.event_classifications
                SET classification = ?, revision = ?, result = CAST(? AS jsonb), changed_at = clock_timestamp()
                WHERE event_id = ?
                """, classification, revision, result, id);
        if (retract) {
            String obsolete = anomalous ? kafka.getTopics().getProcessed() : kafka.getTopics().getAnomalies();
            outbox.enqueue(receipt, obsolete, id, publication(output, classification, revision, true));
        }
        String destination = anomalous ? kafka.getTopics().getAnomalies() : kafka.getTopics().getProcessed();
        String upsert = publication(output, classification, revision, false);
        if (retract) outbox.enqueue(receipt, 1, destination, id, upsert);
        else outbox.enqueue(receipt, destination, id, upsert);
    }

    /**
     * An unchanged replay is the repair path for a selected projection row that was lost. Downstream
     * already holds this revision, so only the database row is rewritten and nothing is published.
     */
    private void restoreMissingProjection(TelemetryEnvelope output, String id, Instant ingestedAt) {
        String table = output instanceof TelemetryAnomalyEvent ? "anomalies" : "processed_telemetry";
        if (Boolean.TRUE.equals(jdbc.queryForObject(
                "SELECT EXISTS (SELECT 1 FROM platform." + table + " WHERE event_id = ?)", Boolean.class, id))) return;
        if (output instanceof TelemetryAnomalyEvent a) anomaly.persistAuthoritative(a, ingestedAt);
        else normal.persistAuthoritative((TelemetryEvent) output, ingestedAt);
    }

    /**
     * The comparable result. It holds only what detection and normalization decide; the anomaly type and
     * threshold are fixed by the projection write and are never part of a classification change.
     */
    private static LinkedHashMap<String, Object> semantic(String classification, Instant eventTime,
            TelemetryEnvelope output) {
        var semantic = new LinkedHashMap<String, Object>();
        semantic.put("classification", classification);
        semantic.put("eventTime", BigDecimal.valueOf(eventTime.getEpochSecond())
                .add(BigDecimal.valueOf(eventTime.getNano(), 9)));
        semantic.put("payload", output.payload());
        if (output instanceof TelemetryAnomalyEvent a) {
            semantic.put("severity", a.severity());
            semantic.put("reasons", a.reasons());
        }
        return semantic;
    }

    private String publication(TelemetryEnvelope output, String classification, long revision, boolean retract) {
        boolean anomalyTopic = retract ? classification.equals(NORMAL) : classification.equals(ANOMALY);
        var details = !retract && output instanceof TelemetryAnomalyEvent a ? a : null;
        return mapper.writeValueAsString(new ClassificationPublication(output.eventId(), output.tenantId(),
                anomalyTopic ? "telemetry.anomaly" : "telemetry.processed", output.timestamp(),
                "telemetry-processor", "2.0", retract ? "RETRACT" : "UPSERT", classification, revision,
                retract ? null : output.payload(), details == null ? null : details.severity(),
                details == null ? null : details.reasons(), details == null ? null : details.detectedAt()));
    }
}
