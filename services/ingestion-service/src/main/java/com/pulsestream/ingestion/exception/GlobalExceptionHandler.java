package com.pulsestream.ingestion.exception;

import jakarta.servlet.http.HttpServletRequest;
import java.time.Instant;
import java.util.List;
import java.util.stream.Collectors;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

/**
 * Global exception handler for standardized error reporting across the service.
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    /**
     * Handles validation errors from JSR-303 annotations.
     */
    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ErrorResponse> handleValidationException(
            MethodArgumentNotValidException ex, HttpServletRequest request) {

        List<ErrorResponse.ValidationError> validationErrors = ex.getBindingResult()
                .getFieldErrors()
                .stream()
                .map(error -> new ErrorResponse.ValidationError(
                        error.getField(),
                        error.getDefaultMessage()))
                .collect(Collectors.toList());

        ErrorResponse response = new ErrorResponse(
                Instant.now(),
                HttpStatus.BAD_REQUEST.value(),
                "Bad Request",
                "Validation failed",
                request.getRequestURI(),
                validationErrors
        );

        log.warn("Validation failure at {}", request.getRequestURI());
        return ResponseEntity.badRequest().body(response);
    }

    /**
     * Handles cases where the JSON payload is malformed or missing.
     */
    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<ErrorResponse> handleMessageNotReadable(
            HttpMessageNotReadableException ex, HttpServletRequest request) {

        ErrorResponse response = new ErrorResponse(
                Instant.now(),
                HttpStatus.BAD_REQUEST.value(),
                "Bad Request",
                "Malformed JSON request body or missing required payload.",
                request.getRequestURI(),
                List.of()
        );

        log.warn("Malformed JSON received at {}: {}", request.getRequestURI(), ex.getMessage());
        return ResponseEntity.badRequest().body(response);
    }

    /**
     * Handles Kafka publishing failures after request validation has succeeded.
     */
    @ExceptionHandler(TelemetryPublishingException.class)
    public ResponseEntity<ErrorResponse> handleTelemetryPublishingException(
            TelemetryPublishingException ex, HttpServletRequest request) {

        ErrorResponse response = new ErrorResponse(
                Instant.now(),
                HttpStatus.SERVICE_UNAVAILABLE.value(),
                "Service Unavailable",
                "Telemetry event could not be accepted because publishing is currently unavailable.",
                request.getRequestURI(),
                List.of()
        );

        log.warn("Kafka publishing failure while processing request to {}", request.getRequestURI(), ex);
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(response);
    }

    /**
     * Catch-all handler for any other unhandled exceptions.
     */
    @ExceptionHandler(Exception.class)
    public ResponseEntity<ErrorResponse> handleGenericException(
            Exception ex, HttpServletRequest request) {

        log.error("Unhandled exception occurred while processing request to {}", request.getRequestURI(), ex);

        ErrorResponse response = new ErrorResponse(
                Instant.now(),
                HttpStatus.INTERNAL_SERVER_ERROR.value(),
                "Internal Server Error",
                "An unexpected error occurred. Please contact system administrator.",
                request.getRequestURI(),
                List.of()
        );

        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(response);
    }
}
