package com.pulsestream.processor.messaging;

import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.service.TelemetryProcessingService;

import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

@Component
public class TelemetryEventListener {

    private final TelemetryProcessingService telemetryProcessingService;

    public TelemetryEventListener(TelemetryProcessingService telemetryProcessingService) {
        this.telemetryProcessingService = telemetryProcessingService;
    }

    @KafkaListener(
            topics = "${pulsestream.kafka.topics.raw}",
            containerFactory = "telemetryKafkaListenerContainerFactory"
    )
    public void onTelemetryEvent(TelemetryEvent telemetryEvent) {
        telemetryProcessingService.process(telemetryEvent);
    }
}
