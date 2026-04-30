package com.pulsestream.processor.service;

import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.exception.TelemetryPublishingException;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeoutException;

import org.apache.kafka.common.KafkaException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class ProcessedTelemetryPublisherTest {

    @Mock
    private KafkaTemplate<String, TelemetryEvent> kafkaTemplate;

    private TelemetryProcessorKafkaProperties kafkaProperties;

    private ProcessedTelemetryPublisher processedTelemetryPublisher;

    @BeforeEach
    void setUp() {
        kafkaProperties = new TelemetryProcessorKafkaProperties();
        processedTelemetryPublisher = new ProcessedTelemetryPublisher(kafkaTemplate, kafkaProperties);
    }

    @Test
    @DisplayName("should publish processed telemetry event to configured topic")
    void shouldPublishProcessedTelemetryEventToConfiguredTopic() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEvent>> future = CompletableFuture.completedFuture(null);

        when(kafkaTemplate.send(kafkaProperties.getTopics().getProcessed(), "evt-001", telemetryEvent))
                .thenReturn(future);

        assertThatCode(() -> processedTelemetryPublisher.publish(telemetryEvent))
                .doesNotThrowAnyException();

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getProcessed(), "evt-001", telemetryEvent);
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send completes with failure")
    void shouldThrowControlledExceptionWhenKafkaSendCompletesWithFailure() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEvent>> future = new CompletableFuture<>();
        KafkaException kafkaException = new KafkaException("broker unavailable");
        future.completeExceptionally(kafkaException);

        when(kafkaTemplate.send(kafkaProperties.getTopics().getProcessed(), "evt-001", telemetryEvent))
                .thenReturn(future);

        assertThatThrownBy(() -> processedTelemetryPublisher.publish(telemetryEvent))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCause(kafkaException);

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getProcessed(), "evt-001", telemetryEvent);
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send fails immediately")
    void shouldThrowControlledExceptionWhenKafkaSendFailsImmediately() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        KafkaException kafkaException = new KafkaException("producer unavailable");

        when(kafkaTemplate.send(kafkaProperties.getTopics().getProcessed(), "evt-001", telemetryEvent))
                .thenThrow(kafkaException);

        assertThatThrownBy(() -> processedTelemetryPublisher.publish(telemetryEvent))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCause(kafkaException);

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getProcessed(), "evt-001", telemetryEvent);
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send does not complete before timeout")
    void shouldThrowControlledExceptionWhenKafkaSendDoesNotCompleteBeforeTimeout() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEvent>> future = new CompletableFuture<>();

        when(kafkaTemplate.send(kafkaProperties.getTopics().getProcessed(), "evt-001", telemetryEvent))
                .thenReturn(future);

        assertThatThrownBy(() -> processedTelemetryPublisher.publish(telemetryEvent))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCauseInstanceOf(TimeoutException.class);

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getProcessed(), "evt-001", telemetryEvent);
    }

    @Test
    @DisplayName("should use tenant identifier as message key when event id is blank")
    void shouldUseTenantIdentifierAsMessageKeyWhenEventIdIsBlank() {
        TelemetryEvent telemetryEvent = telemetryEvent(" ", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEvent>> future = CompletableFuture.completedFuture(null);

        when(kafkaTemplate.send(kafkaProperties.getTopics().getProcessed(), "factory-01", telemetryEvent))
                .thenReturn(future);

        assertThatCode(() -> processedTelemetryPublisher.publish(telemetryEvent))
                .doesNotThrowAnyException();

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getProcessed(), "factory-01", telemetryEvent);
    }

    @Test
    @DisplayName("should reject blank tenant id when event id is blank")
    void shouldRejectBlankTenantIdWhenEventIdIsBlank() {
        TelemetryEvent telemetryEvent = telemetryEvent(" ", " ");

        assertThatThrownBy(() -> processedTelemetryPublisher.publish(telemetryEvent))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("telemetryEvent must contain a non-blank tenantId when eventId is blank");
    }

    @Test
    @DisplayName("should reject null telemetry events")
    void shouldRejectNullTelemetryEvents() {
        assertThatThrownBy(() -> processedTelemetryPublisher.publish(null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("telemetryEvent must not be null");
    }

    private TelemetryEvent telemetryEvent(String eventId, String tenantId) {
        return new TelemetryEvent(
                eventId,
                tenantId,
                "telemetry.processed",
                Instant.parse("2026-03-15T12:05:21Z"),
                "telemetry-processor",
                "1.0",
                new TelemetryPayload(
                        "sensor_1042",
                        "temperature-sensor",
                        "temperature",
                        BigDecimal.valueOf(28.4),
                        "C",
                        "zone-a"
                )
        );
    }
}
