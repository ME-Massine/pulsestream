package com.pulsestream.ingestion.controller;

import com.pulsestream.ingestion.dto.TelemetryIngestionRequestDto;
import com.pulsestream.ingestion.mapper.TelemetryEventMapper;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/events")
public class TelemetryController {

    private final TelemetryEventMapper telemetryEventMapper;

    public TelemetryController(TelemetryEventMapper telemetryEventMapper) {
        this.telemetryEventMapper = telemetryEventMapper;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.ACCEPTED)
    public void ingestTelemetry(@Valid @RequestBody TelemetryIngestionRequestDto request) {
        telemetryEventMapper.toModel(request);
    }
}