package com.pulsestream.ingestion.serialization;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pulsestream.ingestion.model.TelemetryEvent;
import org.springframework.stereotype.Component;

@Component
public class TelemetryEventSerializer {

    private final ObjectMapper objectMapper;

    public TelemetryEventSerializer(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    public String serialize(TelemetryEvent event) {
        try {
            return objectMapper.writeValueAsString(event);
        } catch (JsonProcessingException ex) {
            throw new TelemetrySerializationException("Failed to serialize telemetry event", ex);
        }
    }
}