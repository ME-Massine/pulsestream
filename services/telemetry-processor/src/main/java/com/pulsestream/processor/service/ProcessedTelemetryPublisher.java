package com.pulsestream.processor.service;

import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.exception.TelemetryPublishingException;
import com.pulsestream.processor.model.TelemetryEvent;
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
public class ProcessedTelemetryPublisher {

    private static final Logger log = LoggerFactory.getLogger(ProcessedTelemetryPublisher.class);

    private final KafkaTemplate<String, TelemetryEvent> telemetryKafkaTemplate;

    private final TelemetryProcessorKafkaProperties kafkaProperties;

    public ProcessedTelemetryPublisher(
            KafkaTemplate<String, TelemetryEvent> telemetryKafkaTemplate,
            TelemetryProcessorKafkaProperties kafkaProperties
    ) {
        this.telemetryKafkaTemplate = telemetryKafkaTemplate;
        this.kafkaProperties = kafkaProperties;
    }

    public void publish(TelemetryEvent telemetryEvent) {
        Assert.notNull(telemetryEvent, "telemetryEvent must not be null");

        String topic = kafkaProperties.getTopics().getProcessed();
        String messageKey = resolveMessageKey(telemetryEvent);
        long publishTimeoutMillis = publishTimeoutMillis();

        try {
            telemetryKafkaTemplate.send(topic, messageKey, telemetryEvent)
                    .get(publishTimeoutMillis, TimeUnit.MILLISECONDS);
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
                "Failed to publish processed telemetry event to Kafka topic={} key={} eventId={}",
                topic,
                messageKey,
                telemetryEvent.eventId(),
                cause
        );
        return new TelemetryPublishingException("Failed to publish telemetry event to Kafka", cause);
    }
}
