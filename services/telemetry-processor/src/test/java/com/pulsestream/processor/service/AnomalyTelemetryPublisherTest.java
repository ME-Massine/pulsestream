package com.pulsestream.processor.service;

import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.exception.TelemetryPublishingException;
import com.pulsestream.processor.model.AnomalyEvent;
import com.pulsestream.processor.model.AnomalySeverity;
import com.pulsestream.processor.model.NormalizedTelemetryEvent;
import com.pulsestream.processor.model.TelemetryAnomalyResult;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import org.apache.kafka.common.KafkaException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeoutException;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class AnomalyTelemetryPublisherTest {

    @Mock
    private KafkaTemplate<String, AnomalyEvent> kafkaTemplate;

    private TelemetryProcessorKafkaProperties kafkaProperties;

    private AnomalyTelemetryPublisher anomalyTelemetryPublisher;

    @BeforeEach
    void setUp() {
        kafkaProperties = new TelemetryProcessorKafkaProperties();
        anomalyTelemetryPublisher = new AnomalyTelemetryPublisher(kafkaTemplate, kafkaProperties);
    }

    @Test
    @DisplayName("should publish anomaly event with metadata to configured anomalies topic")
    void shouldPublishAnomalyEventWithMetadataToConfiguredTopic() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        TelemetryAnomalyResult anomalyResult = anomalyResult(normalizedEvent(), AnomalySeverity.WARNING,
                List.of("temperature is above maximum threshold"));
        AnomalyEvent expectedAnomalyEvent = new AnomalyEvent(telemetryEvent, AnomalySeverity.WARNING,
                List.of("temperature is above maximum threshold"));
        CompletableFuture<SendResult<String, AnomalyEvent>> future = CompletableFuture.completedFuture(null);

        when(kafkaTemplate.send(kafkaProperties.getTopics().getAnomalies(), "evt-001", expectedAnomalyEvent))
                .thenReturn(future);

        assertThatCode(() -> anomalyTelemetryPublisher.publish(telemetryEvent, anomalyResult))
                .doesNotThrowAnyException();

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getAnomalies(), "evt-001", expectedAnomalyEvent);
    }

    @Test
    @DisplayName("should include severity and reasons in the published anomaly event")
    void shouldIncludeSeverityAndReasonsInPublishedAnomalyEvent() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-002", "factory-01");
        List<String> reasons = List.of("missing required field: deviceId");
        TelemetryAnomalyResult anomalyResult = anomalyResult(normalizedEvent(), AnomalySeverity.CRITICAL, reasons);
        AnomalyEvent expectedAnomalyEvent = new AnomalyEvent(telemetryEvent, AnomalySeverity.CRITICAL, reasons);
        CompletableFuture<SendResult<String, AnomalyEvent>> future = CompletableFuture.completedFuture(null);

        when(kafkaTemplate.send(eq(kafkaProperties.getTopics().getAnomalies()), eq("evt-002"), eq(expectedAnomalyEvent)))
                .thenReturn(future);

        assertThatCode(() -> anomalyTelemetryPublisher.publish(telemetryEvent, anomalyResult))
                .doesNotThrowAnyException();

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getAnomalies(), "evt-002", expectedAnomalyEvent);
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send completes with failure")
    void shouldThrowControlledExceptionWhenKafkaSendCompletesWithFailure() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        TelemetryAnomalyResult anomalyResult = anomalyResult(normalizedEvent(), AnomalySeverity.WARNING,
                List.of("temperature is above maximum threshold"));
        AnomalyEvent expectedAnomalyEvent = new AnomalyEvent(telemetryEvent, AnomalySeverity.WARNING,
                List.of("temperature is above maximum threshold"));
        CompletableFuture<SendResult<String, AnomalyEvent>> future = new CompletableFuture<>();
        KafkaException kafkaException = new KafkaException("broker unavailable");
        future.completeExceptionally(kafkaException);

        when(kafkaTemplate.send(kafkaProperties.getTopics().getAnomalies(), "evt-001", expectedAnomalyEvent))
                .thenReturn(future);

        assertThatThrownBy(() -> anomalyTelemetryPublisher.publish(telemetryEvent, anomalyResult))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCause(kafkaException);

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getAnomalies(), "evt-001", expectedAnomalyEvent);
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send fails immediately")
    void shouldThrowControlledExceptionWhenKafkaSendFailsImmediately() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        TelemetryAnomalyResult anomalyResult = anomalyResult(normalizedEvent(), AnomalySeverity.WARNING,
                List.of("temperature is above maximum threshold"));
        AnomalyEvent expectedAnomalyEvent = new AnomalyEvent(telemetryEvent, AnomalySeverity.WARNING,
                List.of("temperature is above maximum threshold"));
        KafkaException kafkaException = new KafkaException("producer unavailable");

        when(kafkaTemplate.send(kafkaProperties.getTopics().getAnomalies(), "evt-001", expectedAnomalyEvent))
                .thenThrow(kafkaException);

        assertThatThrownBy(() -> anomalyTelemetryPublisher.publish(telemetryEvent, anomalyResult))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCause(kafkaException);

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getAnomalies(), "evt-001", expectedAnomalyEvent);
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send does not complete before timeout")
    void shouldThrowControlledExceptionWhenKafkaSendDoesNotCompleteBeforeTimeout() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        TelemetryAnomalyResult anomalyResult = anomalyResult(normalizedEvent(), AnomalySeverity.WARNING,
                List.of("temperature is above maximum threshold"));
        AnomalyEvent expectedAnomalyEvent = new AnomalyEvent(telemetryEvent, AnomalySeverity.WARNING,
                List.of("temperature is above maximum threshold"));
        CompletableFuture<SendResult<String, AnomalyEvent>> future = new CompletableFuture<>();

        when(kafkaTemplate.send(kafkaProperties.getTopics().getAnomalies(), "evt-001", expectedAnomalyEvent))
                .thenReturn(future);

        assertThatThrownBy(() -> anomalyTelemetryPublisher.publish(telemetryEvent, anomalyResult))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCauseInstanceOf(TimeoutException.class);

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getAnomalies(), "evt-001", expectedAnomalyEvent);
    }

    @Test
    @DisplayName("should use tenant identifier as message key when event id is blank")
    void shouldUseTenantIdentifierAsMessageKeyWhenEventIdIsBlank() {
        TelemetryEvent telemetryEvent = telemetryEvent(" ", "factory-01");
        TelemetryAnomalyResult anomalyResult = anomalyResult(normalizedEvent(), AnomalySeverity.WARNING,
                List.of("temperature is above maximum threshold"));
        AnomalyEvent expectedAnomalyEvent = new AnomalyEvent(telemetryEvent, AnomalySeverity.WARNING,
                List.of("temperature is above maximum threshold"));
        CompletableFuture<SendResult<String, AnomalyEvent>> future = CompletableFuture.completedFuture(null);

        when(kafkaTemplate.send(kafkaProperties.getTopics().getAnomalies(), "factory-01", expectedAnomalyEvent))
                .thenReturn(future);

        assertThatCode(() -> anomalyTelemetryPublisher.publish(telemetryEvent, anomalyResult))
                .doesNotThrowAnyException();

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getAnomalies(), "factory-01", expectedAnomalyEvent);
    }

    @Test
    @DisplayName("should reject blank tenant id when event id is blank")
    void shouldRejectBlankTenantIdWhenEventIdIsBlank() {
        TelemetryEvent telemetryEvent = telemetryEvent(" ", " ");
        TelemetryAnomalyResult anomalyResult = anomalyResult(normalizedEvent(), AnomalySeverity.WARNING,
                List.of("temperature is above maximum threshold"));

        assertThatThrownBy(() -> anomalyTelemetryPublisher.publish(telemetryEvent, anomalyResult))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("telemetryEvent must contain a non-blank tenantId when eventId is blank");
    }

    @Test
    @DisplayName("should reject null telemetry event")
    void shouldRejectNullTelemetryEvent() {
        TelemetryAnomalyResult anomalyResult = anomalyResult(normalizedEvent(), AnomalySeverity.WARNING, List.of());

        assertThatThrownBy(() -> anomalyTelemetryPublisher.publish(null, anomalyResult))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("telemetryEvent must not be null");
    }

    @Test
    @DisplayName("should reject null anomaly result")
    void shouldRejectNullAnomalyResult() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");

        assertThatThrownBy(() -> anomalyTelemetryPublisher.publish(telemetryEvent, null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("anomalyResult must not be null");
    }

    private TelemetryEvent telemetryEvent(String eventId, String tenantId) {
        return new TelemetryEvent(
                eventId,
                tenantId,
                "telemetry.anomaly",
                Instant.parse("2026-03-15T12:05:21Z"),
                "telemetry-processor",
                "1.0",
                new TelemetryPayload(
                        "sensor_1042",
                        "temperature-sensor",
                        "temperature",
                        BigDecimal.valueOf(95.0),
                        "C",
                        "zone-a"
                )
        );
    }

    private NormalizedTelemetryEvent normalizedEvent() {
        return new NormalizedTelemetryEvent(
                "evt-001",
                "factory-01",
                "telemetry.anomaly",
                Instant.parse("2026-03-15T12:05:21Z"),
                "telemetry-processor",
                "1.0",
                "sensor_1042",
                "temperature-sensor",
                "temperature",
                BigDecimal.valueOf(95.0),
                "c",
                "zone-a"
        );
    }

    private TelemetryAnomalyResult anomalyResult(
            NormalizedTelemetryEvent event,
            AnomalySeverity severity,
            List<String> reasons
    ) {
        return TelemetryAnomalyResult.anomalous(event, severity, reasons);
    }
}
