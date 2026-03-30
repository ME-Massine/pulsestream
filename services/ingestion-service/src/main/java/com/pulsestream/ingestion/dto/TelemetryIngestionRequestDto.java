package com.pulsestream.ingestion.dto;

import com.fasterxml.jackson.annotation.JsonFormat;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.time.Instant;

/**
 * Request DTO for telemetry events received by the ingestion API.
 */
public class TelemetryIngestionRequestDto {

    @NotBlank
    private String eventId;

    @NotBlank
    private String tenantId;

    @NotBlank
    private String eventType;

    @NotNull
    @JsonFormat(shape = JsonFormat.Shape.STRING)
    private Instant timestamp;

    @NotBlank
    private String source;

    @NotBlank
    private String version;

    @NotNull
    @Valid
    private TelemetryPayloadDto payload;

    public String getEventId() {
        return eventId;
    }

    public void setEventId(String eventId) {
        this.eventId = eventId;
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public String getEventType() {
        return eventType;
    }

    public void setEventType(String eventType) {
        this.eventType = eventType;
    }

    public Instant getTimestamp() {
        return timestamp;
    }

    public void setTimestamp(Instant timestamp) {
        this.timestamp = timestamp;
    }

    public String getSource() {
        return source;
    }

    public void setSource(String source) {
        this.source = source;
    }

    public String getVersion() {
        return version;
    }

    public void setVersion(String version) {
        this.version = version;
    }

    public TelemetryPayloadDto getPayload() {
        return payload;
    }

    public void setPayload(TelemetryPayloadDto payload) {
        this.payload = payload;
    }
}
