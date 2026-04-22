package com.pulsestream.ingestion.service;

import com.pulsestream.ingestion.config.PulsestreamKafkaProperties;
import com.pulsestream.ingestion.model.TelemetryEvent;
import java.util.concurrent.CompletableFuture;

import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;
import org.springframework.util.StringUtils;

@Service
public class KafkaProducerService {

    private final KafkaTemplate<String, TelemetryEvent> telemetryKafkaTemplate;

    private final PulsestreamKafkaProperties kafkaProperties;

    public KafkaProducerService(
            KafkaTemplate<String, TelemetryEvent> telemetryKafkaTemplate,
            PulsestreamKafkaProperties kafkaProperties
    ) {
        this.telemetryKafkaTemplate = telemetryKafkaTemplate;
        this.kafkaProperties = kafkaProperties;
    }

    public CompletableFuture<SendResult<String, TelemetryEvent>> publishTelemetryEvent(TelemetryEvent telemetryEvent) {
        Assert.notNull(telemetryEvent, "telemetryEvent must not be null");

        return telemetryKafkaTemplate.send(
                kafkaProperties.getTopics().getRaw(),
                resolveMessageKey(telemetryEvent),
                telemetryEvent
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
}
