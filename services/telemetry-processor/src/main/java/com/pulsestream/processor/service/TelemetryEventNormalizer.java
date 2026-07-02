package com.pulsestream.processor.service;

import com.pulsestream.processor.model.TelemetryPayload;
import org.springframework.util.StringUtils;

/**
 * Shared trim-based field normalization for outbound telemetry envelopes.
 *
 * <p>Both the processed flow ({@link TelemetryProcessingService}) and the anomaly flow
 * ({@link AnomalyProcessingService}) derive their published events from the same raw payload, so the
 * field-cleaning rules live here to keep the two paths consistent.
 */
final class TelemetryEventNormalizer {

    private TelemetryEventNormalizer() {
    }

    static TelemetryPayload normalizePayload(TelemetryPayload payload) {
        return new TelemetryPayload(
                normalize(payload.deviceId()),
                normalize(payload.deviceType()),
                normalize(payload.metric()),
                payload.value(),
                normalize(payload.unit()),
                normalize(payload.location())
        );
    }

    static String normalize(String value) {
        return StringUtils.hasText(value) ? value.trim() : value;
    }

    static String defaultIfBlank(String value, String fallback) {
        return StringUtils.hasText(value) ? value.trim() : fallback;
    }
}
