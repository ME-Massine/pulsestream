package com.pulsestream.processor.service;

import com.pulsestream.processor.model.TelemetryAnomalyEvent;
import com.pulsestream.processor.model.TelemetryAnomalyResult;
import com.pulsestream.processor.model.TelemetryEvent;
import java.time.Clock;
import java.time.Instant;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

/**
 * Builds the enriched anomaly envelope from a raw telemetry event and its detection result, then
 * persists it within the delivery coordinator's transaction. Mirrors {@link TelemetryProcessingService} so the anomalous
 * flow is kept clearly separate from the normal processed flow.
 */
@Service
public class AnomalyProcessingService {

    private static final String ANOMALY_EVENT_TYPE = "telemetry.anomaly";
    private static final String ANOMALY_SOURCE = "telemetry-processor";
    private static final String DEFAULT_VERSION = "1.0";

    private final AnomalyPersistenceService persistenceService;
    private final Clock clock;

    @Autowired
    public AnomalyProcessingService(AnomalyPersistenceService persistenceService) {
        this(persistenceService, Clock.systemUTC());
    }

    AnomalyProcessingService(AnomalyPersistenceService persistenceService, Clock clock) {
        this.persistenceService = persistenceService;
        this.clock = clock;
    }

    public TelemetryAnomalyEvent process(TelemetryEvent rawEvent, TelemetryAnomalyResult anomalyResult) {
        return process(rawEvent, anomalyResult, false);
    }

    public TelemetryAnomalyEvent process(TelemetryEvent rawEvent, TelemetryAnomalyResult anomalyResult, boolean replayed) {
        Assert.notNull(rawEvent, "rawEvent must not be null");
        Assert.notNull(rawEvent.payload(), "rawEvent payload must not be null");
        Assert.notNull(anomalyResult, "anomalyResult must not be null");
        Assert.isTrue(anomalyResult.anomalous(), "anomalyResult must be anomalous");

        TelemetryAnomalyEvent anomalyEvent = new TelemetryAnomalyEvent(
                TelemetryEventNormalizer.normalize(rawEvent.eventId()),
                TelemetryEventNormalizer.normalize(rawEvent.tenantId()),
                ANOMALY_EVENT_TYPE,
                rawEvent.timestamp() != null ? rawEvent.timestamp() : Instant.now(clock),
                ANOMALY_SOURCE,
                DEFAULT_VERSION,
                TelemetryEventNormalizer.normalizePayload(rawEvent.payload()),
                anomalyResult.severity(),
                anomalyResult.reasons(),
                Instant.now(clock)
        );

        persistenceService.persist(anomalyEvent, replayed);
        return anomalyEvent;
    }
}
