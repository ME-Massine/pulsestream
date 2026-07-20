package com.pulsestream.processor.model;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.math.BigDecimal;
import java.time.Instant;

/**
 * JPA entity mapping a processed telemetry event to the {@code platform.processed_telemetry} table.
 *
 * <p>The schema is owned by {@code infrastructure/docker/postgres/init.sql}; this mapping is kept
 * consistent with those columns (Hibernate {@code ddl-auto} is {@code none}, so the entity never
 * generates or mutates the schema).
 */
@Entity
@Table(name = "processed_telemetry")
public class ProcessedTelemetryEntity {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "event_id", nullable = false, unique = true, length = 50)
    private String eventId;

    @Column(name = "tenant_id", nullable = false, length = 100)
    private String tenantId;

    @Column(name = "event_type", nullable = false, length = 50)
    private String eventType;

    @Column(name = "timestamp", nullable = false)
    private Instant timestamp;

    @Column(name = "source", nullable = false, length = 100)
    private String source;

    @Column(name = "device_id", nullable = false, length = 100)
    private String deviceId;

    @Column(name = "device_type", nullable = false, length = 100)
    private String deviceType;

    @Column(name = "metric", nullable = false, length = 100)
    private String metric;

    @Column(name = "value", nullable = false, precision = 18, scale = 4)
    private BigDecimal value;

    @Column(name = "unit", nullable = false, length = 20)
    private String unit;

    @Column(name = "location", nullable = false, length = 100)
    private String location;

    @Column(name = "ingested_at", nullable = false)
    private Instant ingestedAt;

    protected ProcessedTelemetryEntity() {
        // Required by JPA.
    }

    public ProcessedTelemetryEntity(
            String eventId,
            String tenantId,
            String eventType,
            Instant timestamp,
            String source,
            String deviceId,
            String deviceType,
            String metric,
            BigDecimal value,
            String unit,
            String location,
            Instant ingestedAt
    ) {
        this.eventId = eventId;
        this.tenantId = tenantId;
        this.eventType = eventType;
        this.timestamp = timestamp;
        this.source = source;
        this.deviceId = deviceId;
        this.deviceType = deviceType;
        this.metric = metric;
        this.value = value;
        this.unit = unit;
        this.location = location;
        this.ingestedAt = ingestedAt;
    }

    public Long getId() {
        return id;
    }

    public String getEventId() {
        return eventId;
    }

    public String getTenantId() {
        return tenantId;
    }

    public String getEventType() {
        return eventType;
    }

    public Instant getTimestamp() {
        return timestamp;
    }

    public String getSource() {
        return source;
    }

    public String getDeviceId() {
        return deviceId;
    }

    public String getDeviceType() {
        return deviceType;
    }

    public String getMetric() {
        return metric;
    }

    public BigDecimal getValue() {
        return value;
    }

    public String getUnit() {
        return unit;
    }

    public String getLocation() {
        return location;
    }

    public Instant getIngestedAt() {
        return ingestedAt;
    }

    /**
     * Replaces the stored projection with the newest processing result for the same event.
     */
    public void updateFrom(ProcessedTelemetryEntity replacement) {
        if (!eventId.equals(replacement.eventId)) {
            throw new IllegalArgumentException("replacement must have the same eventId");
        }

        tenantId = replacement.tenantId;
        eventType = replacement.eventType;
        timestamp = replacement.timestamp;
        source = replacement.source;
        deviceId = replacement.deviceId;
        deviceType = replacement.deviceType;
        metric = replacement.metric;
        value = replacement.value;
        unit = replacement.unit;
        location = replacement.location;
        ingestedAt = replacement.ingestedAt;
    }
}
