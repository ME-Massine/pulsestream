package com.pulsestream.ingestion.controller;

import com.pulsestream.ingestion.dto.TelemetryIngestionRequestDto;
import com.pulsestream.ingestion.mapper.TelemetryEventMapper;
import com.pulsestream.ingestion.model.TelemetryEvent;
import com.pulsestream.ingestion.service.KafkaProducerService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/events")
public class TelemetryController {

    private final TelemetryEventMapper telemetryEventMapper;
    private final KafkaProducerService kafkaProducerService;

    public TelemetryController(
            TelemetryEventMapper telemetryEventMapper,
            KafkaProducerService kafkaProducerService
    ) {
        this.telemetryEventMapper = telemetryEventMapper;
        this.kafkaProducerService = kafkaProducerService;
    }


    @PostMapping
    @ResponseStatus(HttpStatus.ACCEPTED)
    public void ingestTelemetry(@Valid @RequestBody TelemetryIngestionRequestDto request) {
        TelemetryEvent telemetryEvent = telemetryEventMapper.toModel(request);
        kafkaProducerService.publishTelemetryEvent(telemetryEvent);
    }
}