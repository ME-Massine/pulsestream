package com.pulsestream.processor.consumer;

import com.pulsestream.processor.model.AnomalySeverity;
import com.pulsestream.processor.model.NormalizedTelemetryEvent;
import com.pulsestream.processor.model.TelemetryAnomalyResult;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import com.pulsestream.processor.service.AnomalyTelemetryPublisher;
import com.pulsestream.processor.service.TelemetryAnomalyDetectionService;
import com.pulsestream.processor.service.TelemetryNormalizationService;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.kafka.annotation.KafkaListener;

import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class TelemetryEventConsumerTest {

    private final TelemetryNormalizationService normalizationService =
            mock(TelemetryNormalizationService.class);
    private final TelemetryAnomalyDetectionService anomalyDetectionService =
            mock(TelemetryAnomalyDetectionService.class);
    private final AnomalyTelemetryPublisher anomalyPublisher =
            mock(AnomalyTelemetryPublisher.class);

    private final TelemetryEventConsumer consumer =
            new TelemetryEventConsumer(normalizationService, anomalyDetectionService, anomalyPublisher);

    @Test
    @DisplayName("should consume telemetry event and invoke normalization and anomaly detection without throwing")
    void shouldConsumeTelemetryEventAndInvokeNormalizationAndAnomalyDetectionWithoutThrowing() {
        TelemetryEvent event = telemetryEvent();
        NormalizedTelemetryEvent normalizedEvent = normalizedTelemetryEvent();
        TelemetryAnomalyResult anomalyResult = TelemetryAnomalyResult.normal(normalizedEvent);

        when(normalizationService.normalize(event)).thenReturn(normalizedEvent);
        when(anomalyDetectionService.detect(normalizedEvent)).thenReturn(anomalyResult);

        consumer.consumeTelemetryEvent(event);

        verify(normalizationService).normalize(event);
        verify(anomalyDetectionService).detect(normalizedEvent);
    }

    @Test
    @DisplayName("should publish anomalous event to anomaly topic and not continue normal processing")
    void shouldPublishAnomalousEventAndNotContinueNormalProcessing() {
        TelemetryEvent event = telemetryEvent();
        NormalizedTelemetryEvent normalizedEvent = normalizedTelemetryEvent();
        TelemetryAnomalyResult anomalyResult = TelemetryAnomalyResult.anomalous(
                normalizedEvent, AnomalySeverity.WARNING, List.of("temperature is above maximum threshold")
        );

        when(normalizationService.normalize(event)).thenReturn(normalizedEvent);
        when(anomalyDetectionService.detect(normalizedEvent)).thenReturn(anomalyResult);

        consumer.consumeTelemetryEvent(event);

        verify(anomalyPublisher).publish(event);
    }

    @Test
    @DisplayName("should not publish to anomaly topic when event is normal")
    void shouldNotPublishToAnomalyTopicWhenEventIsNormal() {
        TelemetryEvent event = telemetryEvent();
        NormalizedTelemetryEvent normalizedEvent = normalizedTelemetryEvent();
        TelemetryAnomalyResult anomalyResult = TelemetryAnomalyResult.normal(normalizedEvent);

        when(normalizationService.normalize(event)).thenReturn(normalizedEvent);
        when(anomalyDetectionService.detect(normalizedEvent)).thenReturn(anomalyResult);

        consumer.consumeTelemetryEvent(event);

        verify(anomalyPublisher, never()).publish(event);
    }

    @Test
    @DisplayName("should reject null telemetry event")
    void shouldRejectNullTelemetryEvent() {
        assertThatThrownBy(() -> consumer.consumeTelemetryEvent(null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("telemetryEvent must not be null");

        verifyNoInteractions(normalizationService);
        verifyNoInteractions(anomalyDetectionService);
        verifyNoInteractions(anomalyPublisher);
    }

    @Test
    @DisplayName("should listen to configured raw telemetry topic")
    void shouldListenToConfiguredRawTelemetryTopic() throws NoSuchMethodException {
        Method method = TelemetryEventConsumer.class.getMethod(
                "consumeTelemetryEvent",
                TelemetryEvent.class
        );

        KafkaListener kafkaListener = method.getAnnotation(KafkaListener.class);

        assertThat(kafkaListener).isNotNull();
        assertThat(kafkaListener.topics()).containsExactly("${pulsestream.kafka.topics.raw}");
        assertThat(kafkaListener.groupId()).isEqualTo("${pulsestream.kafka.consumer.group-id}");
        assertThat(kafkaListener.containerFactory()).isEqualTo("telemetryKafkaListenerContainerFactory");
    }

    private TelemetryEvent telemetryEvent() {
        return new TelemetryEvent(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                Instant.parse("2026-03-31T12:00:00Z"),
                "sensor-gateway",
                "1.0",
                new TelemetryPayload(
                        "sensor-1042",
                        "temperature-sensor",
                        "temperature",
                        new BigDecimal("28.4"),
                        "C",
                        "zone-a"
                )
        );
    }

    private NormalizedTelemetryEvent normalizedTelemetryEvent() {
        return new NormalizedTelemetryEvent(
                "evt-001",
                "factory-01",
                "telemetry.reading",
                Instant.parse("2026-03-31T12:00:00Z"),
                "sensor-gateway",
                "1.0",
                "sensor-1042",
                "temperature-sensor",
                "temperature",
                new BigDecimal("28.4"),
                "c",
                "zone-a"
        );
    }
}