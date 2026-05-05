package com.pulsestream.processor.consumer;

import com.pulsestream.processor.model.TelemetryEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

@Service
public class TelemetryEventConsumer {

    private static final Logger log = LoggerFactory.getLogger(TelemetryEventConsumer.class);

    @KafkaListener(
            topics = "${pulsestream.kafka.topics.raw}",
            groupId = "${pulsestream.kafka.consumer.group-id}",
            containerFactory = "telemetryKafkaListenerContainerFactory"
    )
    public void consumeTelemetryEvent(TelemetryEvent telemetryEvent) {
        Assert.notNull(telemetryEvent, "telemetryEvent must not be null");

        log.info(
                "Received telemetry event eventId={} tenantId={} eventType={} source={}",
                telemetryEvent.eventId(),
                telemetryEvent.tenantId(),
                telemetryEvent.eventType(),
                telemetryEvent.source()
        );
    }
}