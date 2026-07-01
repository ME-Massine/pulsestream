package com.pulsestream.processor.service;

import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.exception.TelemetryPublishingException;
import com.pulsestream.processor.model.AnomalySeverity;
import com.pulsestream.processor.model.TelemetryAnomalyEvent;
import com.pulsestream.processor.model.TelemetryEnvelope;
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
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class AnomalyTelemetryPublisherTest {

    @Mock
    private KafkaTemplate<String, TelemetryEnvelope> kafkaTemplate;

    private TelemetryProcessorKafkaProperties kafkaProperties;

    private AnomalyTelemetryPublisher anomalyTelemetryPublisher;

    @BeforeEach
    void setUp() {
        kafkaProperties = new TelemetryProcessorKafkaProperties();
        anomalyTelemetryPublisher = new AnomalyTelemetryPublisher(kafkaTemplate, kafkaProperties);
    }

    @Test
    @DisplayName("should publish anomaly event to configured anomalies topic")
    void shouldPublishAnomalyEventToConfiguredTopic() {
        TelemetryAnomalyEvent anomalyEvent = anomalyEvent("evt-001", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEnvelope>> future = CompletableFuture.completedFuture(null);

        when(kafkaTemplate.send(kafkaProperties.getTopics().getAnomalies(), "evt-001", anomalyEvent))
                .thenReturn(future);

        assertThatCode(() -> anomalyTelemetryPublisher.publish(anomalyEvent))
                .doesNotThrowAnyException();

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getAnomalies(), "evt-001", anomalyEvent);
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send completes with failure")
    void shouldThrowControlledExceptionWhenKafkaSendCompletesWithFailure() {
        TelemetryAnomalyEvent anomalyEvent = anomalyEvent("evt-001", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEnvelope>> future = new CompletableFuture<>();
        KafkaException kafkaException = new KafkaException("broker unavailable");
        future.completeExceptionally(kafkaException);

        when(kafkaTemplate.send(kafkaProperties.getTopics().getAnomalies(), "evt-001", anomalyEvent))
                .thenReturn(future);

        assertThatThrownBy(() -> anomalyTelemetryPublisher.publish(anomalyEvent))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCause(kafkaException);

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getAnomalies(), "evt-001", anomalyEvent);
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send fails immediately")
    void shouldThrowControlledExceptionWhenKafkaSendFailsImmediately() {
        TelemetryAnomalyEvent anomalyEvent = anomalyEvent("evt-001", "factory-01");
        KafkaException kafkaException = new KafkaException("producer unavailable");

        when(kafkaTemplate.send(kafkaProperties.getTopics().getAnomalies(), "evt-001", anomalyEvent))
                .thenThrow(kafkaException);

        assertThatThrownBy(() -> anomalyTelemetryPublisher.publish(anomalyEvent))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCause(kafkaException);

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getAnomalies(), "evt-001", anomalyEvent);
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send does not complete before timeout")
    void shouldThrowControlledExceptionWhenKafkaSendDoesNotCompleteBeforeTimeout() {
        TelemetryAnomalyEvent anomalyEvent = anomalyEvent("evt-001", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEnvelope>> future = new CompletableFuture<>();

        when(kafkaTemplate.send(kafkaProperties.getTopics().getAnomalies(), "evt-001", anomalyEvent))
                .thenReturn(future);

        assertThatThrownBy(() -> anomalyTelemetryPublisher.publish(anomalyEvent))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCauseInstanceOf(TimeoutException.class);

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getAnomalies(), "evt-001", anomalyEvent);
    }

    @Test
    @DisplayName("should use tenant identifier as message key when event id is blank")
    void shouldUseTenantIdentifierAsMessageKeyWhenEventIdIsBlank() {
        TelemetryAnomalyEvent anomalyEvent = anomalyEvent(" ", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEnvelope>> future = CompletableFuture.completedFuture(null);

        when(kafkaTemplate.send(kafkaProperties.getTopics().getAnomalies(), "factory-01", anomalyEvent))
                .thenReturn(future);

        assertThatCode(() -> anomalyTelemetryPublisher.publish(anomalyEvent))
                .doesNotThrowAnyException();

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getAnomalies(), "factory-01", anomalyEvent);
    }

    @Test
    @DisplayName("should reject blank tenant id when event id is blank")
    void shouldRejectBlankTenantIdWhenEventIdIsBlank() {
        TelemetryAnomalyEvent anomalyEvent = anomalyEvent(" ", " ");

        assertThatThrownBy(() -> anomalyTelemetryPublisher.publish(anomalyEvent))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("anomalyEvent must contain a non-blank tenantId when eventId is blank");
    }

    @Test
    @DisplayName("should reject null anomaly events")
    void shouldRejectNullAnomalyEvents() {
        assertThatThrownBy(() -> anomalyTelemetryPublisher.publish(null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("anomalyEvent must not be null");
    }

    private TelemetryAnomalyEvent anomalyEvent(String eventId, String tenantId) {
        return new TelemetryAnomalyEvent(
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
                ),
                AnomalySeverity.WARNING,
                List.of("temperature is above maximum threshold"),
                Instant.parse("2026-03-15T12:05:22Z")
        );
    }
}
