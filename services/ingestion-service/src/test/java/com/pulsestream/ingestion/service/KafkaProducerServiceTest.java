package com.pulsestream.ingestion.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pulsestream.ingestion.config.PulsestreamKafkaProperties;
import com.pulsestream.ingestion.exception.TelemetryPublishingException;
import com.pulsestream.ingestion.model.TelemetryEvent;
import com.pulsestream.ingestion.model.TelemetryPayload;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeoutException;

import org.apache.kafka.common.KafkaException;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class KafkaProducerServiceTest {

    private static final Instant FIXED_INSTANT = Instant.parse("2026-04-01T09:30:00Z");

    @SuppressWarnings("unchecked")
    private final KafkaTemplate<String, TelemetryEvent> kafkaTemplate = mock(KafkaTemplate.class);

    @SuppressWarnings("unchecked")
    private final KafkaTemplate<String, String> dlqKafkaTemplate = mock(KafkaTemplate.class);

    private final ObjectMapper objectMapper = new ObjectMapper().findAndRegisterModules();

    private final PulsestreamKafkaProperties kafkaProperties = new PulsestreamKafkaProperties();

    private final Clock fixedClock = Clock.fixed(FIXED_INSTANT, ZoneOffset.UTC);

    private final KafkaProducerService kafkaProducerService = new KafkaProducerService(
            kafkaTemplate, dlqKafkaTemplate, objectMapper, kafkaProperties, fixedClock
    );

    @Test
    @DisplayName("should publish telemetry events to the configured raw topic")
    void shouldPublishTelemetryEventsToTheConfiguredRawTopic() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEvent>> sendFuture = new CompletableFuture<>();
        sendFuture.complete(sendResult());

        when(kafkaTemplate.send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent))
                .thenReturn(sendFuture);

        assertThatCode(() -> kafkaProducerService.publishTelemetryEvent(telemetryEvent))
                .doesNotThrowAnyException();

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent);
    }

    @Test
    @DisplayName("should fall back to tenant id when event id is blank")
    void shouldFallBackToTenantIdWhenEventIdIsBlank() {
        TelemetryEvent telemetryEvent = telemetryEvent(" ", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEvent>> sendFuture = new CompletableFuture<>();
        sendFuture.complete(sendResult());

        when(kafkaTemplate.send(kafkaProperties.getTopics().getRaw(), "factory-01", telemetryEvent))
                .thenReturn(sendFuture);

        assertThatCode(() -> kafkaProducerService.publishTelemetryEvent(telemetryEvent))
                .doesNotThrowAnyException();

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getRaw(), "factory-01", telemetryEvent);
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send completes with failure")
    void shouldThrowControlledExceptionWhenKafkaSendCompletesWithFailure() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEvent>> sendFuture = new CompletableFuture<>();
        KafkaException kafkaException = new KafkaException("broker unavailable");
        sendFuture.completeExceptionally(kafkaException);

        when(kafkaTemplate.send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent))
                .thenReturn(sendFuture);

        assertThatThrownBy(() -> kafkaProducerService.publishTelemetryEvent(telemetryEvent))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCause(kafkaException);

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent);
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send fails immediately")
    void shouldThrowControlledExceptionWhenKafkaSendFailsImmediately() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        KafkaException kafkaException = new KafkaException("producer unavailable");

        when(kafkaTemplate.send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent))
                .thenThrow(kafkaException);

        assertThatThrownBy(() -> kafkaProducerService.publishTelemetryEvent(telemetryEvent))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCause(kafkaException);

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent);
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send does not complete before timeout")
    void shouldThrowControlledExceptionWhenKafkaSendDoesNotCompleteBeforeTimeout() {
        kafkaProperties.getProducer().setPublishTimeout(Duration.ofMillis(10));
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEvent>> sendFuture = new CompletableFuture<>();

        when(kafkaTemplate.send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent))
                .thenReturn(sendFuture);

        assertThatThrownBy(() -> kafkaProducerService.publishTelemetryEvent(telemetryEvent))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCauseInstanceOf(TimeoutException.class);

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent);
    }

    @Test
    @DisplayName("should reroute the failed event to the DLQ topic wrapped with error metadata")
    void shouldRerouteFailedEventToDeadLetterQueueWithMetadata() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        KafkaException kafkaException = new KafkaException("broker unavailable");

        CompletableFuture<SendResult<String, TelemetryEvent>> rawFuture = new CompletableFuture<>();
        rawFuture.completeExceptionally(kafkaException);
        CompletableFuture<SendResult<String, String>> dlqFuture = new CompletableFuture<>();
        dlqFuture.complete(dlqSendResult());

        when(kafkaTemplate.send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent))
                .thenReturn(rawFuture);
        when(dlqKafkaTemplate.send(eq(kafkaProperties.getTopics().getDlq()), eq("evt-001"), anyString()))
                .thenReturn(dlqFuture);

        assertThatThrownBy(() -> kafkaProducerService.publishTelemetryEvent(telemetryEvent))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCause(kafkaException);

        verify(kafkaTemplate).send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent);

        ArgumentCaptor<String> dlqValueCaptor = ArgumentCaptor.forClass(String.class);
        verify(dlqKafkaTemplate)
                .send(eq(kafkaProperties.getTopics().getDlq()), eq("evt-001"), dlqValueCaptor.capture());

        String dlqValue = dlqValueCaptor.getValue();
        // The original payload is preserved, wrapped with error metadata.
        assertThat(dlqValue).contains("evt-001").contains("sensor-1042");
        assertThat(dlqValue).contains("KafkaException: broker unavailable");
        assertThat(dlqValue).contains("ingestion-service");
        assertThat(dlqValue).contains("2026-04-01T09:30:00Z");
    }

    @Test
    @DisplayName("should preserve the payload and metadata in the DLQ even when the envelope cannot be serialized")
    void shouldRerouteToDeadLetterQueueWhenEnvelopeSerializationFails() throws JsonProcessingException {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        KafkaException kafkaException = new KafkaException("broker unavailable");

        ObjectMapper failingObjectMapper = mock(ObjectMapper.class);
        when(failingObjectMapper.writeValueAsString(any()))
                .thenThrow(new JsonProcessingException("boom") {});

        KafkaProducerService serviceWithFailingObjectMapper = new KafkaProducerService(
                kafkaTemplate, dlqKafkaTemplate, failingObjectMapper, kafkaProperties, fixedClock
        );

        CompletableFuture<SendResult<String, TelemetryEvent>> rawFuture = new CompletableFuture<>();
        rawFuture.completeExceptionally(kafkaException);
        CompletableFuture<SendResult<String, String>> dlqFuture = new CompletableFuture<>();
        dlqFuture.complete(dlqSendResult());

        when(kafkaTemplate.send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent))
                .thenReturn(rawFuture);
        when(dlqKafkaTemplate.send(eq(kafkaProperties.getTopics().getDlq()), eq("evt-001"), anyString()))
                .thenReturn(dlqFuture);

        assertThatThrownBy(() -> serviceWithFailingObjectMapper.publishTelemetryEvent(telemetryEvent))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCause(kafkaException);

        // Despite the serialization failure, the DLQ receives a fallback representation
        // that still carries the original event id, payload, and failure metadata.
        ArgumentCaptor<String> dlqValueCaptor = ArgumentCaptor.forClass(String.class);
        verify(dlqKafkaTemplate)
                .send(eq(kafkaProperties.getTopics().getDlq()), eq("evt-001"), dlqValueCaptor.capture());
        String dlqValue = dlqValueCaptor.getValue();
        assertThat(dlqValue).contains("evt-001").contains("sensor-1042");
        assertThat(dlqValue).contains("ingestion-service");
    }

    @Test
    @DisplayName("should not crash when the DLQ reroute also fails")
    void shouldNotCrashWhenDeadLetterQueueRerouteAlsoFails() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        KafkaException rawException = new KafkaException("broker unavailable");
        KafkaException dlqException = new KafkaException("dlq unavailable");

        CompletableFuture<SendResult<String, TelemetryEvent>> rawFuture = new CompletableFuture<>();
        rawFuture.completeExceptionally(rawException);
        CompletableFuture<SendResult<String, String>> dlqFuture = new CompletableFuture<>();
        dlqFuture.completeExceptionally(dlqException);

        when(kafkaTemplate.send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent))
                .thenReturn(rawFuture);
        when(dlqKafkaTemplate.send(eq(kafkaProperties.getTopics().getDlq()), eq("evt-001"), anyString()))
                .thenReturn(dlqFuture);

        assertThatThrownBy(() -> kafkaProducerService.publishTelemetryEvent(telemetryEvent))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCause(rawException);

        verify(dlqKafkaTemplate)
                .send(eq(kafkaProperties.getTopics().getDlq()), eq("evt-001"), anyString());
    }

    @Test
    @DisplayName("should reject blank tenant id when event id is blank")
    void shouldRejectBlankTenantIdWhenEventIdIsBlank() {
        TelemetryEvent telemetryEvent = telemetryEvent(" ", " ");

        assertThatThrownBy(() -> kafkaProducerService.publishTelemetryEvent(telemetryEvent))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("telemetryEvent must contain a non-blank tenantId when eventId is blank");
    }

    @Test
    @DisplayName("should reject null telemetry events")
    void shouldRejectNullTelemetryEvents() {
        assertThatThrownBy(() -> kafkaProducerService.publishTelemetryEvent(null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("telemetryEvent must not be null");
    }

    private TelemetryEvent telemetryEvent(String eventId, String tenantId) {
        return new TelemetryEvent(
                eventId,
                tenantId,
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

    @SuppressWarnings("unchecked")
    private SendResult<String, TelemetryEvent> sendResult() {
        return mock(SendResult.class);
    }

    @SuppressWarnings("unchecked")
    private SendResult<String, String> dlqSendResult() {
        return mock(SendResult.class);
    }
}
