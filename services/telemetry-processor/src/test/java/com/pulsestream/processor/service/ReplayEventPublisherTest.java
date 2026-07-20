package com.pulsestream.processor.service;

import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.exception.TelemetryPublishingException;
import com.pulsestream.processor.model.TelemetryEnvelope;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeoutException;

import org.apache.kafka.common.KafkaException;
import org.apache.kafka.clients.producer.ProducerRecord;
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
import static org.mockito.ArgumentMatchers.any;

@ExtendWith(MockitoExtension.class)
class ReplayEventPublisherTest {

    @Mock
    private KafkaTemplate<String, TelemetryEnvelope> kafkaTemplate;

    private TelemetryProcessorKafkaProperties kafkaProperties;

    private ReplayEventPublisher replayEventPublisher;

    @BeforeEach
    void setUp() {
        kafkaProperties = new TelemetryProcessorKafkaProperties();
        replayEventPublisher = new ReplayEventPublisher(
                kafkaTemplate,
                kafkaProperties,
                Clock.fixed(Instant.parse("2026-04-01T09:30:00Z"), ZoneOffset.UTC)
        );
    }

    @Test
    @DisplayName("should republish the replayed event to the configured raw topic keyed by eventId")
    void shouldRepublishReplayedEventToRawTopic() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEnvelope>> future = CompletableFuture.completedFuture(null);

        when(kafkaTemplate.send(org.mockito.ArgumentMatchers.<ProducerRecord<String, TelemetryEnvelope>>any()))
                .thenReturn(future);

        assertThatCode(() -> replayEventPublisher.publish(telemetryEvent, ReplayEventPublisher.DLQ_REPLAY_SOURCE))
                .doesNotThrowAnyException();

        verify(kafkaTemplate).send(org.mockito.ArgumentMatchers.<ProducerRecord<String, TelemetryEnvelope>>argThat(record ->
                record.topic().equals(kafkaProperties.getTopics().getRaw())
                        && record.key().equals("evt-001")
                        && record.value().equals(telemetryEvent)
                        && new String(record.headers().lastHeader(ReplayHeaders.REPLAY).value(), StandardCharsets.UTF_8)
                                .equals("true")
                        && new String(record.headers().lastHeader(ReplayHeaders.REPLAYED_AT).value(), StandardCharsets.UTF_8)
                                .equals("2026-04-01T09:30:00Z")
                        && new String(record.headers().lastHeader(ReplayHeaders.REPLAY_SOURCE).value(), StandardCharsets.UTF_8)
                                .equals(ReplayEventPublisher.DLQ_REPLAY_SOURCE)
        ));
    }

    @Test
    @DisplayName("should use tenant identifier as message key when event id is blank")
    void shouldUseTenantIdentifierAsMessageKeyWhenEventIdIsBlank() {
        TelemetryEvent telemetryEvent = telemetryEvent(" ", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEnvelope>> future = CompletableFuture.completedFuture(null);

        when(kafkaTemplate.send(org.mockito.ArgumentMatchers.<ProducerRecord<String, TelemetryEnvelope>>any()))
                .thenReturn(future);

        assertThatCode(() -> replayEventPublisher.publish(telemetryEvent, ReplayEventPublisher.DLQ_REPLAY_SOURCE))
                .doesNotThrowAnyException();

        verify(kafkaTemplate).send(org.mockito.ArgumentMatchers.<ProducerRecord<String, TelemetryEnvelope>>argThat(record ->
                record.key().equals("factory-01") && record.value().equals(telemetryEvent)
        ));
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send completes with failure")
    void shouldThrowControlledExceptionWhenKafkaSendCompletesWithFailure() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEnvelope>> future = new CompletableFuture<>();
        KafkaException kafkaException = new KafkaException("broker unavailable");
        future.completeExceptionally(kafkaException);

        when(kafkaTemplate.send(org.mockito.ArgumentMatchers.<ProducerRecord<String, TelemetryEnvelope>>any()))
                .thenReturn(future);

        assertThatThrownBy(() -> replayEventPublisher.publish(telemetryEvent, ReplayEventPublisher.DLQ_REPLAY_SOURCE))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to republish replayed event to Kafka")
                .hasCause(kafkaException);

        verify(kafkaTemplate).send(org.mockito.ArgumentMatchers.<ProducerRecord<String, TelemetryEnvelope>>any());
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send fails immediately")
    void shouldThrowControlledExceptionWhenKafkaSendFailsImmediately() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        KafkaException kafkaException = new KafkaException("producer unavailable");

        when(kafkaTemplate.send(org.mockito.ArgumentMatchers.<ProducerRecord<String, TelemetryEnvelope>>any()))
                .thenThrow(kafkaException);

        assertThatThrownBy(() -> replayEventPublisher.publish(telemetryEvent, ReplayEventPublisher.DLQ_REPLAY_SOURCE))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to republish replayed event to Kafka")
                .hasCause(kafkaException);

        verify(kafkaTemplate).send(org.mockito.ArgumentMatchers.<ProducerRecord<String, TelemetryEnvelope>>any());
    }

    @Test
    @DisplayName("should throw controlled exception when Kafka send does not complete before timeout")
    void shouldThrowControlledExceptionWhenKafkaSendDoesNotCompleteBeforeTimeout() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEnvelope>> future = new CompletableFuture<>();

        when(kafkaTemplate.send(org.mockito.ArgumentMatchers.<ProducerRecord<String, TelemetryEnvelope>>any()))
                .thenReturn(future);

        assertThatThrownBy(() -> replayEventPublisher.publish(telemetryEvent, ReplayEventPublisher.DLQ_REPLAY_SOURCE))
                .isInstanceOf(TelemetryPublishingException.class)
                .hasMessage("Failed to republish replayed event to Kafka")
                .hasCauseInstanceOf(TimeoutException.class);

        verify(kafkaTemplate).send(org.mockito.ArgumentMatchers.<ProducerRecord<String, TelemetryEnvelope>>any());
    }

    @Test
    @DisplayName("should reject blank tenant id when event id is blank")
    void shouldRejectBlankTenantIdWhenEventIdIsBlank() {
        TelemetryEvent telemetryEvent = telemetryEvent(" ", " ");

        assertThatThrownBy(() -> replayEventPublisher.publish(telemetryEvent, ReplayEventPublisher.DLQ_REPLAY_SOURCE))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("telemetryEvent must contain a non-blank tenantId when eventId is blank");
    }

    @Test
    @DisplayName("should reject null telemetry events")
    void shouldRejectNullTelemetryEvents() {
        assertThatThrownBy(() -> replayEventPublisher.publish(null, ReplayEventPublisher.DLQ_REPLAY_SOURCE))
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
                        BigDecimal.valueOf(28.4),
                        "C",
                        "zone-a"
                )
        );
    }
}
