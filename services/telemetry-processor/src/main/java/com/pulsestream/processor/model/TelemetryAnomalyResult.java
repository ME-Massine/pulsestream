package com.pulsestream.processor.model;

import java.util.List;

public record TelemetryAnomalyResult(
        NormalizedTelemetryEvent event,
        boolean anomalous,
        AnomalySeverity severity,
        List<String> reasons
) {
    public static TelemetryAnomalyResult normal(NormalizedTelemetryEvent event) {
        return new TelemetryAnomalyResult(event, false, AnomalySeverity.NONE, List.of());
    }

    public static TelemetryAnomalyResult anomalous(
            NormalizedTelemetryEvent event,
            AnomalySeverity severity,
            List<String> reasons
    ) {
        return new TelemetryAnomalyResult(event, true, severity, List.copyOf(reasons));
    }
}