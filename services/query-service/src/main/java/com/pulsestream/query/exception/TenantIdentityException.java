package com.pulsestream.query.exception;

public class TenantIdentityException extends RuntimeException {
    public TenantIdentityException() {
        super("An authenticated tenant identity is required.");
    }
}
