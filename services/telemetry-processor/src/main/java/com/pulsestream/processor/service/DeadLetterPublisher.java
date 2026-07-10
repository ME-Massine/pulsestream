package com.pulsestream.processor.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.model.DeadLetterEvent;
import com.pulsestream.processor.model.TelemetryEvent;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;
import org.springframework.util.StringUtils;

/**
 * Routes telemetry events that failed processing to the dead-letter topic, attaching the error
 * reason and failure timestamp. Publishing is best-effort: a DLQ send failure is logged rather
 * than propagated, so a broker outage on the DLQ path never crashes the consumer.
 */
@Service
public class DeadLetterPublisher {

    private static final Logger log = LoggerFactory.getLogger(DeadLetterPublisher.class);

    private final KafkaTemplate<String, String> dlqKafkaTemplate;
    private final TelemetryProcessorKafkaProperties kafkaProperties;
    private final ObjectMapper objectMapper;
    private final Clock clock;

    @Autowired
    public DeadLetterPublisher(
            KafkaTemplate<String, String> dlqKafkaTemplate,
            TelemetryProcessorKafkaProperties kafkaProperties,
            ObjectMapper objectMapper
    ) {
        this(dlqKafkaTemplate, kafkaProperties, objectMapper, Clock.systemUTC());
    }

    DeadLetterPublisher(
            KafkaTemplate<String, String> dlqKafkaTemplate,
            TelemetryProcessorKafkaProperties kafkaProperties,
            ObjectMapper objectMapper,
            Clock clock
    ) {
        this.dlqKafkaTemplate = dlqKafkaTemplate;
        this.kafkaProperties = kafkaProperties;
        this.objectMapper = objectMapper;
        this.clock = clock;
    }

    public void publish(TelemetryEvent event, Throwable cause) {
        Assert.notNull(event, "event must not be null");

        String dlqTopic = kafkaProperties.getTopics().getDlq();
        String messageKey = resolveMessageKey(event);
        DeadLetterEvent deadLetterEvent = new DeadLetterEvent(event, describe(cause), Instant.now(clock));
        String dlqValue = renderDeadLetterValue(deadLetterEvent);

        try {
            dlqKafkaTemplate.send(dlqTopic, messageKey, dlqValue)
                    .get(publishTimeoutMillis(), TimeUnit.MILLISECONDS);
            log.warn(
                    "Routed failed telemetry event to DLQ topic={} key={} eventId={} reason={}",
                    dlqTopic,
                    messageKey,
                    event.eventId(),
                    deadLetterEvent.errorReason()
            );
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            logDlqSendFailure(dlqTopic, messageKey, event, ex);
        } catch (ExecutionException ex) {
            logDlqSendFailure(dlqTopic, messageKey, event, ex.getCause() != null ? ex.getCause() : ex);
        } catch (TimeoutException | RuntimeException ex) {
            logDlqSendFailure(dlqTopic, messageKey, event, ex);
        }
    }

    private String renderDeadLetterValue(DeadLetterEvent deadLetterEvent) {
        try {
            return objectMapper.writeValueAsString(deadLetterEvent);
        } catch (Exception ex) {
            log.warn(
                    "Falling back to non-JSON DLQ representation for eventId={} due to serialization failure",
                    deadLetterEvent.event().eventId(),
                    ex
            );
            return String.valueOf(deadLetterEvent);
        }
    }

    private String describe(Throwable cause) {
        if (cause == null) {
            return "Unknown processing failure";
        }
        return StringUtils.hasText(cause.getMessage())
                ? cause.getClass().getSimpleName() + ": " + cause.getMessage()
                : cause.getClass().getSimpleName();
    }

    private String resolveMessageKey(TelemetryEvent event) {
        if (StringUtils.hasText(event.eventId())) {
            return event.eventId().trim();
        }

        Assert.hasText(event.tenantId(), "event must contain a non-blank tenantId when eventId is blank");

        return event.tenantId().trim();
    }

    private long publishTimeoutMillis() {
        Duration publishTimeout = kafkaProperties.getProducer().getPublishTimeout();
        Assert.notNull(publishTimeout, "Kafka producer publish timeout must not be null");
        Assert.isTrue(publishTimeout.toMillis() > 0,
                "Kafka producer publish timeout must be greater than zero");
        return publishTimeout.toMillis();
    }

    private void logDlqSendFailure(String dlqTopic, String messageKey, TelemetryEvent event, Throwable cause) {
        log.error(
                "Failed to route telemetry event to DLQ topic={} key={} eventId={}; event may be lost",
                dlqTopic,
                messageKey,
                event.eventId(),
                cause
        );
    }
}
