package com.pulsestream.ingestion.service;

import com.pulsestream.ingestion.config.PulsestreamKafkaProperties;
import com.pulsestream.ingestion.exception.TelemetryPublishingException;
import com.pulsestream.ingestion.model.TelemetryEvent;
import java.util.concurrent.CompletionException;

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

        String topic = kafkaProperties.getTopics().getRaw();
        String messageKey = resolveMessageKey(telemetryEvent);

        try {
            telemetryKafkaTemplate.send(topic, messageKey, telemetryEvent).join();
        } catch (CompletionException ex) {
            throw publishFailure(telemetryEvent, topic, messageKey, ex.getCause() != null ? ex.getCause() : ex);
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

    private TelemetryPublishingException publishFailure(
            TelemetryEvent telemetryEvent,
            String topic,
            String messageKey,
            Throwable cause
    ) {
        log.error(
                "Failed to publish telemetry event to Kafka topic={} key={} eventId={}",
                topic,
                messageKey,
                telemetryEvent.eventId(),
                cause
        );
        return new TelemetryPublishingException("Failed to publish telemetry event to Kafka", cause);
    }
}
