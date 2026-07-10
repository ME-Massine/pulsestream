package com.pulsestream.ingestion.controller;

import com.pulsestream.ingestion.dto.TelemetryIngestionRequestDto;
import com.pulsestream.ingestion.dto.TelemetryPayloadDto;
import com.pulsestream.ingestion.exception.TelemetryPublishingException;
import com.pulsestream.ingestion.mapper.TelemetryEventMapper;
import com.pulsestream.ingestion.model.TelemetryEvent;
import com.pulsestream.ingestion.service.KafkaProducerService;
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.common.CompletableResultCode;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.data.SpanData;
import io.opentelemetry.sdk.trace.export.SimpleSpanProcessor;
import io.opentelemetry.sdk.trace.export.SpanExporter;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Verifies that {@link TelemetryController} emits a span carrying request metadata
 * for every ingested telemetry event, using an in-memory {@link SpanExporter} instead
 * of a real OTLP backend.
 */
class TelemetryControllerTracingTest {

    private final List<SpanData> exportedSpans = new ArrayList<>();

    private TelemetryEventMapper telemetryEventMapper;
    private KafkaProducerService kafkaProducerService;
    private TelemetryController controller;

    @BeforeEach
    void setUp() {
        SpanExporter recordingExporter = new SpanExporter() {
            @Override
            public CompletableResultCode export(Collection<SpanData> spans) {
                exportedSpans.addAll(spans);
                return CompletableResultCode.ofSuccess();
            }

            @Override
            public CompletableResultCode flush() {
                return CompletableResultCode.ofSuccess();
            }

            @Override
            public CompletableResultCode shutdown() {
                return CompletableResultCode.ofSuccess();
            }
        };

        SdkTracerProvider tracerProvider = SdkTracerProvider.builder()
                .addSpanProcessor(SimpleSpanProcessor.create(recordingExporter))
                .build();
        OpenTelemetry openTelemetry = OpenTelemetrySdk.builder()
                .setTracerProvider(tracerProvider)
                .build();

        telemetryEventMapper = mock(TelemetryEventMapper.class);
        kafkaProducerService = mock(KafkaProducerService.class);
        controller = new TelemetryController(telemetryEventMapper, kafkaProducerService, openTelemetry);
    }

    @Test
    @DisplayName("should emit a span carrying request metadata when telemetry is ingested")
    void shouldEmitSpanWithRequestMetadata() {
        TelemetryIngestionRequestDto request = validRequest();
        when(telemetryEventMapper.toModel(request)).thenReturn(mock(TelemetryEvent.class));

        controller.ingestTelemetry(request);

        assertThat(exportedSpans).hasSize(1);
        SpanData span = exportedSpans.get(0);
        assertThat(span.getName()).isEqualTo("TelemetryController.ingestTelemetry");
        assertThat(span.getAttributes().get(AttributeKey.stringKey("pulsestream.event.id"))).isEqualTo("evt-001");
        assertThat(span.getAttributes().get(AttributeKey.stringKey("pulsestream.tenant.id"))).isEqualTo("factory-01");
        assertThat(span.getAttributes().get(AttributeKey.stringKey("pulsestream.event.type"))).isEqualTo("telemetry.reading");
        assertThat(span.getAttributes().get(AttributeKey.stringKey("pulsestream.event.source"))).isEqualTo("sensor-gateway");
        assertThat(span.getStatus().getStatusCode()).isEqualTo(StatusCode.UNSET);
    }

    @Test
    @DisplayName("should mark the span as an error when Kafka publishing fails")
    void shouldMarkSpanAsErrorWhenPublishingFails() {
        TelemetryIngestionRequestDto request = validRequest();
        TelemetryEvent telemetryEvent = mock(TelemetryEvent.class);
        when(telemetryEventMapper.toModel(request)).thenReturn(telemetryEvent);
        doThrow(new TelemetryPublishingException("Failed to publish telemetry event to Kafka", new RuntimeException("broker unavailable")))
                .when(kafkaProducerService).publishTelemetryEvent(telemetryEvent);

        org.junit.jupiter.api.Assertions.assertThrows(
                TelemetryPublishingException.class, () -> controller.ingestTelemetry(request));

        assertThat(exportedSpans).hasSize(1);
        assertThat(exportedSpans.get(0).getStatus().getStatusCode()).isEqualTo(StatusCode.ERROR);
    }

    private static TelemetryIngestionRequestDto validRequest() {
        return new TelemetryIngestionRequestDto(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                Instant.parse("2026-03-31T12:00:00Z"),
                "sensor-gateway",
                "1.0",
                new TelemetryPayloadDto(
                        "sensor-1042", "temperature-sensor", "temperature",
                        BigDecimal.valueOf(28.4), "C", "zone-a"));
    }
}
