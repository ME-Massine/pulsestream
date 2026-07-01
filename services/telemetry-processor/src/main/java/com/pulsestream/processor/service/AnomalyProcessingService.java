package com.pulsestream.processor.service;

import com.pulsestream.processor.model.TelemetryAnomalyEvent;
import com.pulsestream.processor.model.TelemetryAnomalyResult;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import java.time.Clock;
import java.time.Instant;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;
import org.springframework.util.StringUtils;

/**
 * Builds the enriched anomaly envelope from a raw telemetry event and its detection result, then
 * publishes it to the anomalies topic. Mirrors {@link TelemetryProcessingService} so the anomalous
 * flow is kept clearly separate from the normal processed flow.
 */
@Service
public class AnomalyProcessingService {

    private static final String ANOMALY_EVENT_TYPE = "telemetry.anomaly";
    private static final String ANOMALY_SOURCE = "telemetry-processor";
    private static final String DEFAULT_VERSION = "1.0";

    private final AnomalyTelemetryPublisher anomalyPublisher;
    private final Clock clock;

    @Autowired
    public AnomalyProcessingService(AnomalyTelemetryPublisher anomalyPublisher) {
        this(anomalyPublisher, Clock.systemUTC());
    }

    AnomalyProcessingService(AnomalyTelemetryPublisher anomalyPublisher, Clock clock) {
        this.anomalyPublisher = anomalyPublisher;
        this.clock = clock;
    }

    public TelemetryAnomalyEvent process(TelemetryEvent rawEvent, TelemetryAnomalyResult anomalyResult) {
        Assert.notNull(rawEvent, "rawEvent must not be null");
        Assert.notNull(rawEvent.payload(), "rawEvent payload must not be null");
        Assert.notNull(anomalyResult, "anomalyResult must not be null");
        Assert.isTrue(anomalyResult.anomalous(), "anomalyResult must be anomalous");

        TelemetryAnomalyEvent anomalyEvent = new TelemetryAnomalyEvent(
                normalize(rawEvent.eventId()),
                normalize(rawEvent.tenantId()),
                ANOMALY_EVENT_TYPE,
                rawEvent.timestamp() != null ? rawEvent.timestamp() : Instant.now(clock),
                ANOMALY_SOURCE,
                defaultIfBlank(rawEvent.version(), DEFAULT_VERSION),
                normalize(rawEvent.payload()),
                anomalyResult.severity(),
                anomalyResult.reasons(),
                Instant.now(clock)
        );

        anomalyPublisher.publish(anomalyEvent);
        return anomalyEvent;
    }

    private TelemetryPayload normalize(TelemetryPayload payload) {
        return new TelemetryPayload(
                normalize(payload.deviceId()),
                normalize(payload.deviceType()),
                normalize(payload.metric()),
                payload.value(),
                normalize(payload.unit()),
                normalize(payload.location())
        );
    }

    private String normalize(String value) {
        return StringUtils.hasText(value) ? value.trim() : value;
    }

    private String defaultIfBlank(String value, String fallback) {
        return StringUtils.hasText(value) ? value.trim() : fallback;
    }
}
