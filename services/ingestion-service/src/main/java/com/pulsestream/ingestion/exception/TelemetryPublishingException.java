package com.pulsestream.ingestion.exception;

public class TelemetryPublishingException extends RuntimeException {

    public TelemetryPublishingException(String message, Throwable cause) {
        super(message, cause);
    }
}
