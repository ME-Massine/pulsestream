package com.pulsestream.processor.service;

import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.exception.TelemetryPublishingException;
import com.pulsestream.processor.model.TelemetryAnomalyEvent;
import com.pulsestream.processor.model.TelemetryEnvelope;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;
import org.springframework.util.StringUtils;

import java.time.Duration;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

@Service
public class AnomalyTelemetryPublisher {

    private static final Logger log = LoggerFactory.getLogger(AnomalyTelemetryPublisher.class);

    private final KafkaTemplate<String, TelemetryEnvelope> telemetryKafkaTemplate;

    private final TelemetryProcessorKafkaProperties kafkaProperties;

    public AnomalyTelemetryPublisher(
            KafkaTemplate<String, TelemetryEnvelope> telemetryKafkaTemplate,
            TelemetryProcessorKafkaProperties kafkaProperties
    ) {
        this.telemetryKafkaTemplate = telemetryKafkaTemplate;
        this.kafkaProperties = kafkaProperties;
    }

    public void publish(TelemetryAnomalyEvent anomalyEvent) {
        Assert.notNull(anomalyEvent, "anomalyEvent must not be null");

        String topic = kafkaProperties.getTopics().getAnomalies();
        String messageKey = resolveMessageKey(anomalyEvent);
        long publishTimeoutMillis = publishTimeoutMillis();

        try {
            telemetryKafkaTemplate.send(topic, messageKey, anomalyEvent)
                    .get(publishTimeoutMillis, TimeUnit.MILLISECONDS);
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            throw publishFailure(anomalyEvent, topic, messageKey, ex);
        } catch (ExecutionException ex) {
            throw publishFailure(anomalyEvent, topic, messageKey, ex.getCause() != null ? ex.getCause() : ex);
        } catch (TimeoutException ex) {
            TimeoutException timeoutException =
                    new TimeoutException("Kafka publish did not complete within " + publishTimeoutMillis + " ms");
            timeoutException.initCause(ex);
            throw publishFailure(anomalyEvent, topic, messageKey, timeoutException);
        } catch (RuntimeException ex) {
            throw publishFailure(anomalyEvent, topic, messageKey, ex);
        }
    }

    private String resolveMessageKey(TelemetryEnvelope anomalyEvent) {
        if (StringUtils.hasText(anomalyEvent.eventId())) {
            return anomalyEvent.eventId().trim();
        }

        Assert.hasText(anomalyEvent.tenantId(),
                "anomalyEvent must contain a non-blank tenantId when eventId is blank");

        return anomalyEvent.tenantId().trim();
    }

    private long publishTimeoutMillis() {
        Duration publishTimeout = kafkaProperties.getProducer().getPublishTimeout();
        Assert.notNull(publishTimeout, "Kafka producer publish timeout must not be null");
        Assert.isTrue(publishTimeout.toMillis() > 0,
                "Kafka producer publish timeout must be greater than zero");
        return publishTimeout.toMillis();
    }

    private TelemetryPublishingException publishFailure(
            TelemetryAnomalyEvent anomalyEvent,
            String topic,
            String messageKey,
            Throwable cause
    ) {
        log.error(
                "Failed to publish anomalous telemetry event to Kafka topic={} key={} eventId={}",
                topic,
                messageKey,
                anomalyEvent.eventId(),
                cause
        );
        return new TelemetryPublishingException("Failed to publish telemetry event to Kafka", cause);
    }
}
