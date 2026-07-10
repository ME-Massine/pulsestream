package com.pulsestream.ingestion.service;

import com.pulsestream.ingestion.config.PulsestreamKafkaProperties;
import com.pulsestream.ingestion.exception.TelemetryPublishingException;
import com.pulsestream.ingestion.model.TelemetryEvent;
import java.time.Duration;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;
import org.springframework.util.StringUtils;

@Service
public class KafkaProducerService {

    private static final Logger log = LoggerFactory.getLogger(KafkaProducerService.class);

    private final KafkaTemplate<String, TelemetryEvent> telemetryKafkaTemplate;

    private final PulsestreamKafkaProperties kafkaProperties;

    public KafkaProducerService(
            KafkaTemplate<String, TelemetryEvent> telemetryKafkaTemplate,
            PulsestreamKafkaProperties kafkaProperties
    ) {
        this.telemetryKafkaTemplate = telemetryKafkaTemplate;
        this.kafkaProperties = kafkaProperties;
    }

    public void publishTelemetryEvent(TelemetryEvent telemetryEvent) {
        Assert.notNull(telemetryEvent, "telemetryEvent must not be null");

        String rawTopic = kafkaProperties.getTopics().getRaw();
        String messageKey = resolveMessageKey(telemetryEvent);

        try {
            sendBlocking(rawTopic, messageKey, telemetryEvent);
        } catch (KafkaSendFailure failure) {
            Throwable cause = failure.getCause();
            log.error(
                    "Failed to publish telemetry event to Kafka topic={} key={} eventId={}",
                    rawTopic,
                    messageKey,
                    telemetryEvent.eventId(),
                    cause
            );
            // Preserve the failed event in the DLQ so it is not lost. This is best-effort:
            // if the broker itself is unavailable the DLQ publish will also fail, which we
            // log rather than propagate so the service never crashes on a publish failure.
            routeToDeadLetterQueue(telemetryEvent, messageKey, cause);
            throw new TelemetryPublishingException("Failed to publish telemetry event to Kafka", cause);
        }
    }

    private void routeToDeadLetterQueue(TelemetryEvent telemetryEvent, String messageKey, Throwable cause) {
        String dlqTopic = kafkaProperties.getTopics().getDlq();

        try {
            sendBlocking(dlqTopic, messageKey, telemetryEvent);
            log.warn(
                    "Rerouted failed telemetry event to DLQ topic={} key={} eventId={} reason={}",
                    dlqTopic,
                    messageKey,
                    telemetryEvent.eventId(),
                    cause != null ? cause.toString() : "unknown"
            );
        } catch (KafkaSendFailure dlqFailure) {
            log.error(
                    "Failed to reroute telemetry event to DLQ topic={} key={} eventId={}; event may be lost",
                    dlqTopic,
                    messageKey,
                    telemetryEvent.eventId(),
                    dlqFailure.getCause()
            );
        }
    }

    private void sendBlocking(String topic, String messageKey, TelemetryEvent telemetryEvent) {
        long publishTimeoutMillis = publishTimeoutMillis();

        try {
            telemetryKafkaTemplate.send(topic, messageKey, telemetryEvent)
                    .get(publishTimeoutMillis, TimeUnit.MILLISECONDS);
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            throw new KafkaSendFailure(ex);
        } catch (ExecutionException ex) {
            throw new KafkaSendFailure(ex.getCause() != null ? ex.getCause() : ex);
        } catch (TimeoutException ex) {
            TimeoutException timeoutException =
                    new TimeoutException("Kafka publish did not complete within " + publishTimeoutMillis + " ms");
            timeoutException.initCause(ex);
            throw new KafkaSendFailure(timeoutException);
        } catch (RuntimeException ex) {
            throw new KafkaSendFailure(ex);
        }
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

    /**
     * Internal signal that a Kafka send did not complete successfully. It carries the
     * normalized underlying cause so callers can log it, decide whether to reroute the
     * event to the DLQ, and surface a controlled {@link TelemetryPublishingException}.
     */
    private static final class KafkaSendFailure extends RuntimeException {

        private KafkaSendFailure(Throwable cause) {
            super(cause);
        }
    }
}
