package com.pulsestream.ingestion.mapper;

import com.pulsestream.ingestion.dto.TelemetryIngestionRequestDto;
import com.pulsestream.ingestion.dto.TelemetryPayloadDto;
import com.pulsestream.ingestion.model.TelemetryEvent;
import com.pulsestream.ingestion.model.TelemetryPayload;
import org.springframework.stereotype.Component;

@Component
public class TelemetryEventMapper {

    public TelemetryEvent toModel(TelemetryIngestionRequestDto request) {
        return new TelemetryEvent(
                request.eventId(),
                request.tenantId(),
                request.eventType(),
                request.timestamp(),
                request.source(),
                request.version(),
                toPayloadModel(request.payload())
        );
    }

    private TelemetryPayload toPayloadModel(TelemetryPayloadDto payload) {
        if (payload == null) {
            return null;
        }

        return new TelemetryPayload(
                payload.deviceId(),
                payload.deviceType(),
                payload.metric(),
                payload.value(),
                payload.unit(),
                payload.location()
        );
    }
}