package com.pulsestream.processor.exception;

/** State failures must stop raw consumption without acknowledging or dead-lettering the record. */
public class AnomalyStateException extends RuntimeException {
    public AnomalyStateException(String message) { super(message); }
    public AnomalyStateException(String message, Throwable cause) { super(message, cause); }
}
