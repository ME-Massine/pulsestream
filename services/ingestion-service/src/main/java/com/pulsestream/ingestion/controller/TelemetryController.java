package com.pulsestream.ingestion.controller;

import com.pulsestream.ingestion.dto.TelemetryIngestionRequestDto;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/events")
public class TelemetryController {

    @PostMapping
    @ResponseStatus(HttpStatus.ACCEPTED)
    public void ingestTelemetry(@Valid @RequestBody TelemetryIngestionRequestDto request) {
    }
}
