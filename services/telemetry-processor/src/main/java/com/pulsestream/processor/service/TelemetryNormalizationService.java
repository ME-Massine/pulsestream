package com.pulsestream.processor.service;

import com.pulsestream.processor.model.NormalizedTelemetryEvent;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

import java.util.Locale;

@Service
public class TelemetryNormalizationService {

    public NormalizedTelemetryEvent normalize(TelemetryEvent event) {
        Assert.notNull(event, "telemetry event must not be null");
        Assert.notNull(event.payload(), "telemetry payload must not be null");

        TelemetryPayload payload = event.payload();

        return new NormalizedTelemetryEvent(
                trim(event.eventId()),
                trim(event.tenantId()),
                normalizeToken(event.eventType()),
                event.timestamp(),
                trim(event.source()),
                trim(event.version()),
                trim(payload.deviceId()),
                normalizeToken(payload.deviceType()),
                normalizeToken(payload.metric()),
                payload.value(),
                normalizeToken(payload.unit()),
                trim(payload.location())
        );
    }

    private String trim(String value) {
        return value == null ? null : value.trim();
    }

    private String normalizeToken(String value) {
        return value == null ? null : value.trim().toLowerCase(Locale.ROOT);
    }
}