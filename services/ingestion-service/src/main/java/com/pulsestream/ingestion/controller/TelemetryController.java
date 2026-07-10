package com.pulsestream.ingestion.controller;

import com.pulsestream.ingestion.dto.TelemetryIngestionRequestDto;
import com.pulsestream.ingestion.mapper.TelemetryEventMapper;
import com.pulsestream.ingestion.model.TelemetryEvent;
import com.pulsestream.ingestion.service.KafkaProducerService;
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/events")
public class TelemetryController {

    private final TelemetryEventMapper telemetryEventMapper;
    private final KafkaProducerService kafkaProducerService;
    private final Tracer tracer;

    public TelemetryController(
            TelemetryEventMapper telemetryEventMapper,
            KafkaProducerService kafkaProducerService,
            OpenTelemetry openTelemetry
    ) {
        this.telemetryEventMapper = telemetryEventMapper;
        this.kafkaProducerService = kafkaProducerService;
        this.tracer = openTelemetry.getTracer(TelemetryController.class.getName());
    }

    @PostMapping
    @ResponseStatus(HttpStatus.ACCEPTED)
    public void ingestTelemetry(@Valid @RequestBody TelemetryIngestionRequestDto request) {
        Span span = tracer.spanBuilder("TelemetryController.ingestTelemetry").startSpan();
        span.setAttribute("pulsestream.event.id", request.eventId());
        span.setAttribute("pulsestream.tenant.id", request.tenantId());
        span.setAttribute("pulsestream.event.type", request.eventType());
        span.setAttribute("pulsestream.event.source", request.source());

        try (Scope scope = span.makeCurrent()) {
            TelemetryEvent telemetryEvent = telemetryEventMapper.toModel(request);
            kafkaProducerService.publishTelemetryEvent(telemetryEvent);
        } catch (RuntimeException ex) {
            span.recordException(ex);
            span.setStatus(StatusCode.ERROR, ex.getMessage());
            throw ex;
        } finally {
            span.end();
        }
    }
}