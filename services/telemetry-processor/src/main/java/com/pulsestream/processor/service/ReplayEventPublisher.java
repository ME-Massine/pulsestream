package com.pulsestream.processor.service;

import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.exception.TelemetryPublishingException;
import com.pulsestream.processor.model.TelemetryEnvelope;
import com.pulsestream.processor.model.TelemetryEvent;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;
import org.springframework.util.StringUtils;

/**
 * Republishes a replayed {@link TelemetryEvent} to {@code telemetry.events.raw}, preserving its
 * {@code eventId} so {@code telemetry-processor}'s existing raw-topic consumer picks it up like
 * any other event (see the event replay strategy, #122). A publish failure is surfaced as a
 * {@link TelemetryPublishingException} rather than swallowed, so the DLQ listener that triggered
 * the replay does not advance past the record on a failed republish.
 */
@Service
public class ReplayEventPublisher {

    private static final Logger log = LoggerFactory.getLogger(ReplayEventPublisher.class);

    public static final String DLQ_REPLAY_SOURCE = "dlq";

    private final KafkaTemplate<String, TelemetryEnvelope> telemetryKafkaTemplate;

    private final TelemetryProcessorKafkaProperties kafkaProperties;

    private final Clock clock;

    @Autowired
    public ReplayEventPublisher(
            KafkaTemplate<String, TelemetryEnvelope> telemetryKafkaTemplate,
            TelemetryProcessorKafkaProperties kafkaProperties
    ) {
        this(telemetryKafkaTemplate, kafkaProperties, Clock.systemUTC());
    }

    ReplayEventPublisher(
            KafkaTemplate<String, TelemetryEnvelope> telemetryKafkaTemplate,
            TelemetryProcessorKafkaProperties kafkaProperties,
            Clock clock
    ) {
        this.telemetryKafkaTemplate = telemetryKafkaTemplate;
        this.kafkaProperties = kafkaProperties;
        this.clock = clock;
    }

    /**
     * Republishes a DLQ-sourced event. This convenience overload preserves the existing replay
     * publisher contract while ensuring every current replay gets the same explicit source marker.
     */
    public void publish(TelemetryEvent telemetryEvent) {
        publish(telemetryEvent, DLQ_REPLAY_SOURCE);
    }

    public void publish(TelemetryEvent telemetryEvent, String replaySource) {
        Assert.notNull(telemetryEvent, "telemetryEvent must not be null");
        Assert.hasText(replaySource, "replaySource must not be blank");

        String topic = kafkaProperties.getTopics().getRaw();
        String messageKey = resolveMessageKey(telemetryEvent);
        long publishTimeoutMillis = publishTimeoutMillis();
        ProducerRecord<String, TelemetryEnvelope> replayRecord = new ProducerRecord<>(
                topic,
                messageKey,
                telemetryEvent
        );
        addReplayHeaders(replayRecord, replaySource);

        try {
            telemetryKafkaTemplate.send(replayRecord)
                    .get(publishTimeoutMillis, TimeUnit.MILLISECONDS);
            log.info(
                    "Republished replayed event to raw topic={} key={} eventId={} replaySource={}",
                    topic,
                    messageKey,
                    telemetryEvent.eventId(),
                    replaySource
            );
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            throw publishFailure(telemetryEvent, topic, messageKey, ex);
        } catch (ExecutionException ex) {
            throw publishFailure(telemetryEvent, topic, messageKey, ex.getCause() != null ? ex.getCause() : ex);
        } catch (TimeoutException ex) {
            TimeoutException timeoutException =
                    new TimeoutException("Kafka publish did not complete within " + publishTimeoutMillis + " ms");
            timeoutException.initCause(ex);
            throw publishFailure(telemetryEvent, topic, messageKey, timeoutException);
        } catch (RuntimeException ex) {
            throw publishFailure(telemetryEvent, topic, messageKey, ex);
        }
    }

    private void addReplayHeaders(ProducerRecord<String, TelemetryEnvelope> replayRecord, String replaySource) {
        replayRecord.headers().add(ReplayHeaders.REPLAY, "true".getBytes(StandardCharsets.UTF_8));
        replayRecord.headers().add(
                ReplayHeaders.REPLAYED_AT,
                Instant.now(clock).toString().getBytes(StandardCharsets.UTF_8)
        );
        replayRecord.headers().add(
                ReplayHeaders.REPLAY_SOURCE,
                replaySource.trim().getBytes(StandardCharsets.UTF_8)
        );
    }

    private String resolveMessageKey(TelemetryEvent telemetryEvent) {
        if (StringUtils.hasText(telemetryEvent.eventId())) {
            return telemetryEvent.eventId().trim();
        }

        Assert.hasText(telemetryEvent.tenantId(),
                "telemetryEvent must contain a non-blank tenantId when eventId is blank");

        return telemetryEvent.tenantId().trim();
    }

    private long publishTimeoutMillis() {
        Duration publishTimeout = kafkaProperties.getProducer().getPublishTimeout();
        Assert.notNull(publishTimeout, "Kafka producer publish timeout must not be null");
        Assert.isTrue(publishTimeout.toMillis() > 0,
                "Kafka producer publish timeout must be greater than zero");
        return publishTimeout.toMillis();
    }

    private TelemetryPublishingException publishFailure(
            TelemetryEvent telemetryEvent,
            String topic,
            String messageKey,
            Throwable cause
    ) {
        log.error(
                "Failed to republish replayed event to Kafka topic={} key={} eventId={}",
                topic,
                messageKey,
                telemetryEvent.eventId(),
                cause
        );
        return new TelemetryPublishingException("Failed to republish replayed event to Kafka", cause);
    }
}
