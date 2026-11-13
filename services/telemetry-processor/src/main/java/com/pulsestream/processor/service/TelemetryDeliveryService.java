package com.pulsestream.processor.service;

import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.model.DeadLetterEvent;
import com.pulsestream.processor.model.TelemetryEnvelope;
import com.pulsestream.processor.model.TelemetryEvent;
import java.time.Instant;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.util.Assert;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.json.JsonMapper;

/** The listener may return only after a complete durable outcome commits. */
@Service
public class TelemetryDeliveryService {
    private final TransactionTemplate transaction;
    private final DeliveryOutbox outbox;
    private final TelemetryNormalizationService normalizer;
    private final AnomalyStateService state;
    private final TelemetryProcessingService normal;
    private final AnomalyProcessingService anomaly;
    private final TelemetryProcessorKafkaProperties kafka;
    private final ObjectMapper mapper;

    public TelemetryDeliveryService(PlatformTransactionManager manager, DeliveryOutbox outbox,
            TelemetryNormalizationService normalizer, AnomalyStateService state,
            TelemetryProcessingService normal, AnomalyProcessingService anomaly,
            TelemetryProcessorKafkaProperties kafka, ObjectMapper mapper) {
        this.transaction = new TransactionTemplate(manager);
        this.transaction.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.outbox = outbox;
        this.normalizer = normalizer;
        this.state = state;
        this.normal = normal;
        this.anomaly = anomaly;
        this.kafka = kafka;
        this.mapper = mapper;
    }

    public void consume(ConsumerRecord<String, TelemetryEvent> record) {
        Assert.notNull(record, "record is required");
        // A tombstone is not a telemetry event. Stop rather than silently acknowledging it.
        Assert.notNull(record.value(), "telemetry event is required");
        try {
            transaction.executeWithoutResult(status -> process(record));
        } catch (InvalidTelemetryException ex) {
            // The failed processing transaction has already rolled back, including state.
            transaction.executeWithoutResult(status -> deadLetter(record, ex.getCause()));
        }
    }

    private void process(ConsumerRecord<String, TelemetryEvent> record) {
        Long receipt = outbox.begin(record);
        if (receipt == null) return;
        var event = record.value();
        // Only known input validation failures qualify for durable DLQ routing.
        // Unexpected exceptions and infrastructure failures must stop the listener.
        if (event.payload() == null) {
            throw new InvalidTelemetryException(new IllegalArgumentException("telemetry payload must not be null"));
        }
        var result = state.detect(normalizer.normalize(event), record);
        boolean replayed = ReplayHeaders.isReplay(record.headers());
        TelemetryEnvelope output;
        String destination;
        if (result.anomalous()) {
            output = anomaly.process(event, result, replayed);
            destination = kafka.getTopics().getAnomalies();
        } else {
            output = normal.process(event, replayed);
            destination = kafka.getTopics().getProcessed();
        }
        outbox.enqueue(receipt, destination, output.eventId(), mapper.writeValueAsString(output));
    }

    private void deadLetter(ConsumerRecord<String, TelemetryEvent> record, Throwable cause) {
        Long receipt = outbox.begin(record);
        if (receipt == null) return;
        var event = record.value();
        var envelope = new DeadLetterEvent(event, cause.getClass().getSimpleName() + ": " + cause.getMessage(),
                "telemetry-processor", Instant.now());
        String json;
        try {
            json = mapper.writeValueAsString(envelope);
        } catch (RuntimeException ex) {
            json = JsonMapper.builder().build().writeValueAsString(envelope);
        }
        String key = event.eventId() == null ? event.tenantId() : event.eventId().trim();
        outbox.enqueue(receipt, kafka.getTopics().getDlq(), key, json);
    }

    private static final class InvalidTelemetryException extends RuntimeException {
        InvalidTelemetryException(Throwable cause) { super(cause); }
    }
}
