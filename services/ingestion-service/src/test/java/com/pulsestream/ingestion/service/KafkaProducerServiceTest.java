package com.pulsestream.ingestion.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.pulsestream.ingestion.config.PulsestreamKafkaProperties;
import com.pulsestream.ingestion.exception.TelemetryPublishingException;
import com.pulsestream.ingestion.model.TelemetryEvent;
import com.pulsestream.ingestion.model.TelemetryPayload;
import com.pulsestream.ingestion.serialization.TelemetryEventSerializer;
import com.pulsestream.ingestion.serialization.TelemetrySerializationException;
import java.math.BigDecimal;
import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeoutException;

import org.apache.kafka.common.KafkaException;
import org.apache.kafka.common.errors.SerializationException;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class KafkaProducerServiceTest {

    @SuppressWarnings("unchecked")
    private final KafkaTemplate<String, TelemetryEvent> kafkaTemplate = mock(KafkaTemplate.class);

    @SuppressWarnings("unchecked")
    private final KafkaTemplate<String, String> dlqKafkaTemplate = mock(KafkaTemplate.class);

    private final TelemetryEventSerializer telemetryEventSerializer =
            new TelemetryEventSerializer(new ObjectMapper().findAndRegisterModules());

    private final PulsestreamKafkaProperties kafkaProperties = new PulsestreamKafkaProperties();

    private final KafkaProducerService kafkaProducerService =
            new KafkaProducerService(kafkaTemplate, dlqKafkaTemplate, telemetryEventSerializer, kafkaProperties);

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
    @DisplayName("should reroute the failed event to the DLQ topic when the raw publish fails")
    void shouldRerouteFailedEventToDeadLetterQueue() {
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
        // The original payload is preserved in the DLQ record.
        assertThat(dlqValueCaptor.getValue()).contains("evt-001").contains("sensor-1042");
    }

    @Test
    @DisplayName("should preserve the payload in the DLQ even when the event cannot be serialized")
    void shouldRerouteToDeadLetterQueueWhenRawSerializationFails() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");

        // The raw publish fails because the value cannot be serialized, and the shared
        // JSON serializer would fail identically when rendering the DLQ value.
        SerializationException serializationException = new SerializationException("cannot serialize event");
        TelemetryEventSerializer failingSerializer = mock(TelemetryEventSerializer.class);
        when(failingSerializer.serialize(telemetryEvent))
                .thenThrow(new TelemetrySerializationException("boom", serializationException));

        KafkaProducerService serviceWithFailingSerializer =
                new KafkaProducerService(kafkaTemplate, dlqKafkaTemplate, failingSerializer, kafkaProperties);

        when(kafkaTemplate.send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent))
                .thenThrow(serializationException);

        CompletableFuture<SendResult<String, String>> dlqFuture = new CompletableFuture<>();
        dlqFuture.complete(dlqSendResult());
        when(dlqKafkaTemplate.send(eq(kafkaProperties.getTopics().getDlq()), eq("evt-001"), anyString()))
                .thenReturn(dlqFuture);

        assertThatThrownBy(() -> serviceWithFailingSerializer.publishTelemetryEvent(telemetryEvent))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to publish telemetry event to Kafka")
                .hasCause(serializationException);

        // Despite the serialization failure, the DLQ receives a fallback representation
        // that still carries the original event id and payload.
        ArgumentCaptor<String> dlqValueCaptor = ArgumentCaptor.forClass(String.class);
        verify(dlqKafkaTemplate)
                .send(eq(kafkaProperties.getTopics().getDlq()), eq("evt-001"), dlqValueCaptor.capture());
        assertThat(dlqValueCaptor.getValue()).contains("evt-001").contains("sensor-1042");
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
