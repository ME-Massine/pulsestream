package com.pulsestream.ingestion.controller;

import com.pulsestream.ingestion.dto.TelemetryIngestionRequestDto;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * REST controller exposing the telemetry ingestion endpoint.
 */
@RestController
@RequestMapping("/api/telemetry")
public class TelemetryIngestionController {

    /**
     * Ingest a telemetry event into the processing pipeline.
     *
     * <p>Validation is applied to the request body via Jakarta Bean Validation
     * annotations on {@link TelemetryIngestionRequestDto}. Invalid requests
     * are rejected with {@code 400 Bad Request} by Spring's default
     * validation handling.</p>
     *
     * @param request the telemetry ingestion request
     * @return 202 Accepted when the payload is valid and accepted for processing
     */
    @PostMapping
    public ResponseEntity<Void> ingest(@Valid @RequestBody TelemetryIngestionRequestDto request) {
        // At this point the payload is structurally valid.
        // Further business processing and publishing are out of scope.
        return ResponseEntity.status(HttpStatus.ACCEPTED).build();
    }
}
