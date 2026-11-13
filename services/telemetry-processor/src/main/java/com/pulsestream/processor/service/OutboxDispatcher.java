package com.pulsestream.processor.service;

import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import io.micrometer.core.instrument.MeterRegistry;
import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

@Service
@ConditionalOnProperty(name = "pulsestream.outbox.enabled", havingValue = "true", matchIfMissing = true)
public class OutboxDispatcher {
    private static final Logger log = LoggerFactory.getLogger(OutboxDispatcher.class);
    private final JdbcTemplate jdbc;
    private final TransactionTemplate transaction;
    private final KafkaTemplate<String, String> outboxKafkaTemplate;
    private final TelemetryProcessorKafkaProperties properties;
    private final MeterRegistry metrics;

    public OutboxDispatcher(JdbcTemplate jdbc, PlatformTransactionManager manager,
            KafkaTemplate<String, String> outboxKafkaTemplate, TelemetryProcessorKafkaProperties properties,
            MeterRegistry metrics) {
        this.jdbc = jdbc;
        transaction = new TransactionTemplate(manager);
        this.outboxKafkaTemplate = outboxKafkaTemplate;
        this.properties = properties;
        this.metrics = metrics;
        metrics.gauge("pulsestream.delivery.pending", this, d -> d.measure("count(*)", ""));
        metrics.gauge("pulsestream.delivery.failed.pending", this, d -> d.measure("count(*)", "AND attempts > 0"));
        metrics.gauge("pulsestream.delivery.oldest.pending.seconds", this,
                d -> d.measure("COALESCE(EXTRACT(EPOCH FROM now() - min(created_at)), 0)", ""));
    }

    private double measure(String expression, String predicate) {
        try {
            return jdbc.queryForObject("SELECT " + expression + " FROM platform.delivery_outbox WHERE delivered_at IS NULL "
                    + predicate, Double.class);
        } catch (RuntimeException ex) {
            return Double.NaN; // A database outage must not masquerade as an empty backlog.
        }
    }

    @Scheduled(fixedDelayString = "${pulsestream.outbox.poll-interval:1000}")
    public void dispatch() {
        // Bound each poll while allowing independent source partitions to make progress.
        var partitions = jdbc.query("""
                SELECT source_topic, source_partition FROM (
                    SELECT DISTINCT ON (r.source_topic, r.source_partition)
                        r.source_topic, r.source_partition, o.next_attempt_at, o.id
                    FROM platform.processing_receipts r
                    JOIN platform.delivery_outbox o ON o.receipt_id = r.id WHERE o.delivered_at IS NULL
                    ORDER BY r.source_topic, r.source_partition, r.source_offset
                ) heads WHERE next_attempt_at <= now() ORDER BY next_attempt_at, id LIMIT 100
                """, (row, index) -> new Source(row.getString(1), row.getInt(2)));
        int remaining = 100;
        for (var source : partitions) {
            while (remaining > 0 && Boolean.TRUE.equals(transaction.execute(status -> deliver(source)))) {
                remaining--;
            }
        }
    }

    private boolean deliver(Source source) {
        // Hash collisions only serialize unrelated partitions; they cannot allow duplicate ownership.
        boolean locked = Boolean.TRUE.equals(jdbc.queryForObject(
                "SELECT pg_try_advisory_xact_lock(hashtext(?), ?)", Boolean.class,
                "pulsestream-outbox:" + source.topic(), source.partition()));
        if (!locked) return false;
        var rows = jdbc.query("""
                SELECT o.id, o.destination, o.message_key, o.payload, o.attempts, o.next_attempt_at <= now()
                FROM platform.delivery_outbox o JOIN platform.processing_receipts r ON r.id = o.receipt_id
                WHERE r.source_topic = ? AND r.source_partition = ? AND o.delivered_at IS NULL
                ORDER BY r.source_offset LIMIT 1 FOR UPDATE OF o
                """, (row, index) -> new Message(row.getLong(1), row.getString(2), row.getString(3),
                        row.getString(4), row.getInt(5), row.getBoolean(6)), source.topic(), source.partition());
        if (rows.isEmpty() || !rows.getFirst().due()) return false;
        var message = rows.getFirst();
        metrics.counter("pulsestream.delivery.attempts").increment();
        if (message.attempts() > 0) metrics.counter("pulsestream.delivery.retries").increment();
        try {
            outboxKafkaTemplate.send(message.destination(), message.key(), message.payload())
                    .get(properties.getProducer().getPublishTimeout().toMillis(), TimeUnit.MILLISECONDS);
        } catch (Exception ex) {
            if (ex instanceof InterruptedException) Thread.currentThread().interrupt();
            long backoff = Math.min(60, 1L << Math.min(message.attempts(), 6));
            jdbc.update("""
                    UPDATE platform.delivery_outbox SET attempts = attempts + 1, last_error = ?,
                        next_attempt_at = clock_timestamp() + (? * interval '1 second') WHERE id = ?
                    """, ex.getClass().getSimpleName(), backoff, message.id());
            metrics.counter("pulsestream.delivery.failures").increment();
            log.warn("Outbox delivery failed id={}; retry in {} seconds", message.id(), backoff, ex);
            return false;
        }
        // A DB failure here rolls back; Kafka may already contain the message. Retrying can duplicate it.
        jdbc.update("UPDATE platform.delivery_outbox SET delivered_at = clock_timestamp(), attempts = attempts + 1, last_error = NULL WHERE id = ?",
                message.id());
        org.springframework.transaction.support.TransactionSynchronizationManager.registerSynchronization(
                new org.springframework.transaction.support.TransactionSynchronization() {
                    @Override public void afterCommit() {
                        metrics.counter("pulsestream.delivery.delivered").increment();
                        if (message.attempts() > 0) metrics.counter("pulsestream.delivery.recovered").increment();
                    }
                });
        return true;
    }

    private record Source(String topic, int partition) { }
    private record Message(long id, String destination, String key, String payload, int attempts, boolean due) { }
}
