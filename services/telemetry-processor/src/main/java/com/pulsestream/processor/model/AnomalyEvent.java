package com.pulsestream.processor.model;

import java.util.List;

public record AnomalyEvent(
        TelemetryEvent event,
        AnomalySeverity severity,
        List<String> reasons
) {}
