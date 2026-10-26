package com.pulsestream.ingestion.service;

import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.json.JsonMapper;
import com.pulsestream.ingestion.config.PulsestreamKafkaProperties;
import com.pulsestream.ingestion.exception.TelemetryPublishingException;
import com.pulsestream.ingestion.model.DeadLetterEvent;
import com.pulsestream.ingestion.model.TelemetryEvent;
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

@Service
public class KafkaProducerService {

    private static final Logger log = LoggerFactory.getLogger(KafkaProducerService.class);

    private static final String SOURCE_SERVICE = "ingestion-service";

    private final KafkaTemplate<String, TelemetryEvent> telemetryKafkaTemplate;

    private final KafkaTemplate<String, String> dlqKafkaTemplate;

    private final ObjectMapper objectMapper;

    private final PulsestreamKafkaProperties kafkaProperties;

    private final Clock clock;

    @Autowired
    public KafkaProducerService(
            KafkaTemplate<String, TelemetryEvent> telemetryKafkaTemplate,
            KafkaTemplate<String, String> dlqKafkaTemplate,
            ObjectMapper objectMapper,
            PulsestreamKafkaProperties kafkaProperties
    ) {
        this(telemetryKafkaTemplate, dlqKafkaTemplate, objectMapper, kafkaProperties, Clock.systemUTC());
    }

    KafkaProducerService(
            KafkaTemplate<String, TelemetryEvent> telemetryKafkaTemplate,
            KafkaTemplate<String, String> dlqKafkaTemplate,
            ObjectMapper objectMapper,
            PulsestreamKafkaProperties kafkaProperties,
            Clock clock
    ) {
        this.telemetryKafkaTemplate = telemetryKafkaTemplate;
        this.dlqKafkaTemplate = dlqKafkaTemplate;
        this.objectMapper = objectMapper;
        this.kafkaProperties = kafkaProperties;
        this.clock = clock;
    }

    public void publishTelemetryEvent(TelemetryEvent telemetryEvent) {
        Assert.notNull(telemetryEvent, "telemetryEvent must not be null");

        String rawTopic = kafkaProperties.getTopics().getRaw();
        String messageKey = resolveMessageKey(telemetryEvent);

        try {
            sendBlocking(telemetryKafkaTemplate, rawTopic, messageKey, telemetryEvent);
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
        DeadLetterEvent deadLetterEvent = new DeadLetterEvent(
                telemetryEvent,
                describeError(cause),
                SOURCE_SERVICE,
                Instant.now(clock)
        );
        // Render the DLQ value up-front as a String using logic that is independent of the
        // raw-topic JSON path. Even when the raw publish failed because the event could not
        // be serialized, the original payload and failure metadata are still preserved here
        // (using an independent JSON mapper if the configured mapper fails).
        String dlqValue = renderDeadLetterValue(deadLetterEvent);

        try {
            sendBlocking(dlqKafkaTemplate, dlqTopic, messageKey, dlqValue);
            log.warn(
                    "Rerouted failed telemetry event to DLQ topic={} key={} eventId={} reason={}",
                    dlqTopic,
                    messageKey,
                    telemetryEvent.eventId(),
                    deadLetterEvent.errorMessage()
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

    /**
     * Produces the string value published to the DLQ. Preferring JSON keeps the DLQ
     * record consistent with the raw topic, but because a raw-topic serialization
     * failure could recur here, serialization errors use an independent JSON mapper
     * so the shared DLQ contract and replayable original event are preserved.
     */
    private String renderDeadLetterValue(DeadLetterEvent deadLetterEvent) {
        try {
            return objectMapper.writeValueAsString(deadLetterEvent);
        } catch (Exception ex) {
            log.warn(
                    "Using independent JSON mapper for DLQ eventId={} due to serialization failure",
                    deadLetterEvent.event().eventId(),
                    ex
            );
            return JsonMapper.builder().build().writeValueAsString(deadLetterEvent);
        }
    }

    private String describeError(Throwable cause) {
        if (cause == null) {
            return "Unknown publishing failure";
        }
        return StringUtils.hasText(cause.getMessage())
                ? cause.getClass().getSimpleName() + ": " + cause.getMessage()
                : cause.getClass().getSimpleName();
    }

    private <V> void sendBlocking(
            KafkaTemplate<String, V> template,
            String topic,
            String messageKey,
            V value
    ) {
        long publishTimeoutMillis = publishTimeoutMillis();

        try {
            template.send(topic, messageKey, value)
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
        Assert.notNull(telemetryEvent.payload(), "telemetryEvent payload must not be null");
        return TelemetryOrderingKey.of(telemetryEvent.tenantId(), telemetryEvent.payload().deviceId());
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
