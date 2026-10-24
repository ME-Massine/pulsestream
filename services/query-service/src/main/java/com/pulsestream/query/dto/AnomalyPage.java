package com.pulsestream.query.dto;

import java.util.List;

public record AnomalyPage(List<AnomalyResponse> content, int page, int size, boolean hasNext) {
    public AnomalyPage {
        content = List.copyOf(content);
    }
}
