package com.pulsestream.query.dto;

import java.util.List;

/** A bounded slice; no unbounded count query is required. */
public record TelemetryPage(List<ProcessedTelemetryResponse> content, int page, int size, boolean hasNext) {
    public TelemetryPage {
        content = List.copyOf(content);
    }
}
