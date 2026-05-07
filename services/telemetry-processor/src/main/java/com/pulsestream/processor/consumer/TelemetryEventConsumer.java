package com.pulsestream.processor.consumer;

import com.pulsestream.processor.model.NormalizedTelemetryEvent;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.service.TelemetryNormalizationService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

@Service
public class TelemetryEventConsumer {

    private static final Logger log = LoggerFactory.getLogger(TelemetryEventConsumer.class);

    private final TelemetryNormalizationService normalizationService;

    public TelemetryEventConsumer(TelemetryNormalizationService normalizationService) {
        this.normalizationService = normalizationService;
    }

    @KafkaListener(
            topics = "${pulsestream.kafka.topics.raw}",
            groupId = "${pulsestream.kafka.consumer.group-id}",
            containerFactory = "telemetryKafkaListenerContainerFactory"
    )
    public void consumeTelemetryEvent(TelemetryEvent telemetryEvent) {
        Assert.notNull(telemetryEvent, "telemetryEvent must not be null");

        NormalizedTelemetryEvent normalizedEvent =
                normalizationService.normalize(telemetryEvent);

        log.info(
                "Normalized telemetry event eventId={} tenantId={} metric={} unit={}",
                normalizedEvent.eventId(),
                normalizedEvent.tenantId(),
                normalizedEvent.metric(),
                normalizedEvent.unit()
        );
    }
}