package com.pulsestream.processor.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.model.TelemetryPayload;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.concurrent.CompletableFuture;

import org.apache.kafka.common.KafkaException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class DeadLetterPublisherTest {

    @Mock
    private KafkaTemplate<String, String> dlqKafkaTemplate;

    private TelemetryProcessorKafkaProperties kafkaProperties;

    private DeadLetterPublisher deadLetterPublisher;

    private final ObjectMapper objectMapper = new ObjectMapper().findAndRegisterModules();

    private static final Instant FIXED_INSTANT = Instant.parse("2026-04-01T09:30:00Z");

    @BeforeEach
    void setUp() {
        kafkaProperties = new TelemetryProcessorKafkaProperties();
        Clock fixedClock = Clock.fixed(FIXED_INSTANT, ZoneOffset.UTC);
        deadLetterPublisher = new DeadLetterPublisher(
                dlqKafkaTemplate, kafkaProperties, objectMapper, fixedClock
        );
    }

    @Test
    @DisplayName("should publish the failed event to the DLQ topic with the shared envelope contract")
    void shouldPublishFailedEventToDlqTopicWithMetadata() throws JsonProcessingException {
        TelemetryEvent event = telemetryEvent("evt-001", "factory-01");
        RuntimeException cause = new IllegalStateException("normalization exploded");
        CompletableFuture<SendResult<String, String>> future = CompletableFuture.completedFuture(null);

        when(dlqKafkaTemplate.send(eq(kafkaProperties.getTopics().getDlq()), eq("evt-001"), anyString()))
                .thenReturn(future);

        assertThatCode(() -> deadLetterPublisher.publish(event, cause)).doesNotThrowAnyException();

        ArgumentCaptor<String> valueCaptor = ArgumentCaptor.forClass(String.class);
        verify(dlqKafkaTemplate).send(eq(kafkaProperties.getTopics().getDlq()), eq("evt-001"), valueCaptor.capture());

        // Parse the generated JSON and assert the shared DLQ envelope contract (same field
        // names as the ingestion-service producer) rather than relying on substring matches,
        // so a field rename that breaks cross-service consistency fails this test.
        JsonNode dlqNode = objectMapper.readTree(valueCaptor.getValue());
        assertThat(dlqNode.hasNonNull("event")).isTrue();
        assertThat(dlqNode.path("event").path("eventId").asText()).isEqualTo("evt-001");
        assertThat(dlqNode.path("errorMessage").asText())
                .isEqualTo("IllegalStateException: normalization exploded");
        assertThat(dlqNode.path("sourceService").asText()).isEqualTo("telemetry-processor");
        assertThat(dlqNode.path("failedAt").asText()).isEqualTo("2026-04-01T09:30:00Z");
    }

    @Test
    @DisplayName("should not crash when the DLQ send itself fails")
    void shouldNotCrashWhenDlqSendFails() {
        TelemetryEvent event = telemetryEvent("evt-001", "factory-01");
        RuntimeException cause = new IllegalStateException("processing exploded");
        KafkaException dlqFailure = new KafkaException("dlq broker unavailable");

        when(dlqKafkaTemplate.send(eq(kafkaProperties.getTopics().getDlq()), eq("evt-001"), anyString()))
                .thenThrow(dlqFailure);

        assertThatCode(() -> deadLetterPublisher.publish(event, cause)).doesNotThrowAnyException();

        verify(dlqKafkaTemplate).send(eq(kafkaProperties.getTopics().getDlq()), eq("evt-001"), anyString());
    }

    @Test
    @DisplayName("should use tenant identifier as message key when event id is blank")
    void shouldUseTenantIdentifierAsMessageKeyWhenEventIdIsBlank() {
        TelemetryEvent event = telemetryEvent(" ", "factory-01");
        RuntimeException cause = new IllegalStateException("boom");
        CompletableFuture<SendResult<String, String>> future = CompletableFuture.completedFuture(null);

        when(dlqKafkaTemplate.send(eq(kafkaProperties.getTopics().getDlq()), eq("factory-01"), anyString()))
                .thenReturn(future);

        assertThatCode(() -> deadLetterPublisher.publish(event, cause)).doesNotThrowAnyException();

        verify(dlqKafkaTemplate).send(eq(kafkaProperties.getTopics().getDlq()), eq("factory-01"), anyString());
    }

    @Test
    @DisplayName("should not crash and should use a null key when both event id and tenant id are blank")
    void shouldNotCrashWhenEventIdAndTenantIdAreBlank() {
        TelemetryEvent event = telemetryEvent(" ", " ");
        RuntimeException cause = new IllegalStateException("boom");
        CompletableFuture<SendResult<String, String>> future = CompletableFuture.completedFuture(null);

        when(dlqKafkaTemplate.send(eq(kafkaProperties.getTopics().getDlq()), eq(null), anyString()))
                .thenReturn(future);

        assertThatCode(() -> deadLetterPublisher.publish(event, cause)).doesNotThrowAnyException();

        verify(dlqKafkaTemplate).send(eq(kafkaProperties.getTopics().getDlq()), eq(null), anyString());
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
}
