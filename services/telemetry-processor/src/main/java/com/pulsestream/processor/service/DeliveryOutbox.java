package com.pulsestream.processor.service;

import com.pulsestream.processor.exception.AnomalyStateException;
import com.pulsestream.processor.model.TelemetryEvent;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import tools.jackson.databind.ObjectMapper;

@Repository
@Transactional(propagation = Propagation.MANDATORY)
public class DeliveryOutbox {
    private final JdbcTemplate jdbc;
    private final ObjectMapper mapper = tools.jackson.databind.json.JsonMapper.builder().build();

    public DeliveryOutbox(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** Null means this exact source delivery already committed. */
    public Long begin(ConsumerRecord<String, TelemetryEvent> record) {
        String fingerprint = fingerprint(record);
        var inserted = jdbc.query("""
                INSERT INTO platform.processing_receipts (source_topic, source_partition, source_offset, input_hash)
                VALUES (?, ?, ?, ?) ON CONFLICT (source_topic, source_partition, source_offset) DO NOTHING
                RETURNING id
                """, (row, index) -> row.getLong(1), record.topic(), record.partition(), record.offset(), fingerprint);
        if (!inserted.isEmpty()) return inserted.getFirst();
        String existing = jdbc.queryForObject("""
                SELECT input_hash FROM platform.processing_receipts
                WHERE source_topic = ? AND source_partition = ? AND source_offset = ?
                """, String.class, record.topic(), record.partition(), record.offset());
        if (!fingerprint.equals(existing)) {
            throw new AnomalyStateException("Source coordinate changed; topic recreation requires explicit migration");
        }
        return null;
    }

    public void enqueue(long receipt, String destination, String key, String payload) {
        int inserted = jdbc.update("""
                INSERT INTO platform.delivery_outbox
                    (receipt_id, destination, message_key, payload, source_topic, source_partition, source_offset)
                SELECT id, ?, ?, ?, source_topic, source_partition, source_offset
                FROM platform.processing_receipts WHERE id = ?
                """, destination, key, payload, receipt);
        if (inserted != 1) throw new DataIntegrityViolationException("Missing source receipt for outbox enqueue");
    }

    private String fingerprint(ConsumerRecord<String, TelemetryEvent> record) {
        // Include headers: the replay marker changes projection semantics.
        var input = new StringBuilder(mapper.writeValueAsString(record.value()))
                .append('\n').append(mapper.writeValueAsString(record.key())).append('\n').append(record.timestamp());
        for (var header : record.headers()) {
            input.append('\n').append(mapper.writeValueAsString(header.key())).append(':')
                    .append(header.value() == null ? "null" : HexFormat.of().formatHex(header.value()));
        }
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(input.toString().getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException ex) {
            throw new IllegalStateException(ex);
        }
    }
}
