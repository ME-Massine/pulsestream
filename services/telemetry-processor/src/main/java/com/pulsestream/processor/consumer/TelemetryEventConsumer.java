package com.pulsestream.processor.consumer;

import com.pulsestream.processor.model.NormalizedTelemetryEvent;
import com.pulsestream.processor.model.TelemetryAnomalyResult;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.service.AnomalyProcessingService;
import com.pulsestream.processor.service.DeadLetterPublisher;
import com.pulsestream.processor.service.TelemetryAnomalyDetectionService;
import com.pulsestream.processor.service.TelemetryNormalizationService;
import com.pulsestream.processor.service.TelemetryProcessingService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

@Service
public class TelemetryEventConsumer {

    private static final Logger log = LoggerFactory.getLogger(TelemetryEventConsumer.class);

    private final TelemetryNormalizationService normalizationService;
    private final TelemetryAnomalyDetectionService anomalyDetectionService;
    private final AnomalyProcessingService anomalyProcessingService;
    private final TelemetryProcessingService processingService;
    private final DeadLetterPublisher deadLetterPublisher;

    public TelemetryEventConsumer(
            TelemetryNormalizationService normalizationService,
            TelemetryAnomalyDetectionService anomalyDetectionService,
            AnomalyProcessingService anomalyProcessingService,
            TelemetryProcessingService processingService,
            DeadLetterPublisher deadLetterPublisher
    ) {
        this.normalizationService = normalizationService;
        this.anomalyDetectionService = anomalyDetectionService;
        this.anomalyProcessingService = anomalyProcessingService;
        this.processingService = processingService;
        this.deadLetterPublisher = deadLetterPublisher;
    }

    @KafkaListener(
            topics = "${pulsestream.kafka.topics.raw}",
            groupId = "${pulsestream.kafka.consumer.group-id}",
            containerFactory = "telemetryKafkaListenerContainerFactory"
    )
    public void consumeTelemetryEvent(TelemetryEvent telemetryEvent) {
        Assert.notNull(telemetryEvent, "telemetryEvent must not be null");

        try {
            processTelemetryEvent(telemetryEvent);
        } catch (RuntimeException ex) {
            log.error(
                    "Failed to process telemetry event eventId={} tenantId={}; routing to DLQ",
                    telemetryEvent.eventId(),
                    telemetryEvent.tenantId(),
                    ex
            );
            deadLetterPublisher.publish(telemetryEvent, ex);
        }
    }

    private void processTelemetryEvent(TelemetryEvent telemetryEvent) {
        NormalizedTelemetryEvent normalizedEvent =
                normalizationService.normalize(telemetryEvent);

        TelemetryAnomalyResult anomalyResult =
                anomalyDetectionService.detect(normalizedEvent);

        if (anomalyResult.anomalous()) {
            log.warn(
                    "Detected telemetry anomaly eventId={} tenantId={} metric={} unit={} value={} severity={} reasons={}",
                    normalizedEvent.eventId(),
                    normalizedEvent.tenantId(),
                    normalizedEvent.metric(),
                    normalizedEvent.unit(),
                    normalizedEvent.value(),
                    anomalyResult.severity(),
                    anomalyResult.reasons()
            );
            anomalyProcessingService.process(telemetryEvent, anomalyResult);
            return;
        }

        processingService.process(telemetryEvent);

        log.info(
                "Processed normal telemetry event eventId={} tenantId={} metric={} unit={}",
                normalizedEvent.eventId(),
                normalizedEvent.tenantId(),
                normalizedEvent.metric(),
                normalizedEvent.unit()
        );
    }
}