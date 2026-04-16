package com.pulsestream.ingestion.dto;

/**
 * Shared validation messages for ingestion request DTOs.
 */
public final class ValidationMessages {

    public static final String EVENT_ID_REQUIRED = "eventId is required";
    public static final String TENANT_ID_REQUIRED = "tenantId is required";
    public static final String EVENT_TYPE_REQUIRED = "eventType is required";
    public static final String TIMESTAMP_REQUIRED = "timestamp is required";
    public static final String SOURCE_REQUIRED = "source is required";
    public static final String VERSION_REQUIRED = "version is required";
    public static final String PAYLOAD_REQUIRED = "payload is required";
    public static final String DEVICE_ID_REQUIRED = "deviceId is required";
    public static final String DEVICE_TYPE_REQUIRED = "deviceType is required";
    public static final String METRIC_REQUIRED = "metric is required";
    public static final String VALUE_REQUIRED = "value is required";
    public static final String UNIT_REQUIRED = "unit is required";
    public static final String LOCATION_REQUIRED = "location is required";

    private ValidationMessages() {
    }
}
