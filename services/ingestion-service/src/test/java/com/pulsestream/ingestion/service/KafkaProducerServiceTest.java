package com.pulsestream.ingestion.service;

import com.pulsestream.ingestion.config.PulsestreamKafkaProperties;
import com.pulsestream.ingestion.model.TelemetryEvent;
import com.pulsestream.ingestion.model.TelemetryPayload;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.concurrent.CompletableFuture;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class KafkaProducerServiceTest {

    @SuppressWarnings("unchecked")
    private final KafkaTemplate<String, TelemetryEvent> kafkaTemplate = mock(KafkaTemplate.class);

    private final PulsestreamKafkaProperties kafkaProperties = new PulsestreamKafkaProperties();

    private final KafkaProducerService kafkaProducerService =
            new KafkaProducerService(kafkaTemplate, kafkaProperties);

    @Test
    @DisplayName("should publish telemetry events to the configured raw topic")
    void shouldPublishTelemetryEventsToTheConfiguredRawTopic() {
        TelemetryEvent telemetryEvent = telemetryEvent("evt-001", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEvent>> sendFuture = new CompletableFuture<>();

        when(kafkaTemplate.send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent))
                .thenReturn(sendFuture);

        CompletableFuture<SendResult<String, TelemetryEvent>> result =
                kafkaProducerService.publishTelemetryEvent(telemetryEvent);

        assertThat(result).isSameAs(sendFuture);
        verify(kafkaTemplate).send(kafkaProperties.getTopics().getRaw(), "evt-001", telemetryEvent);
    }

    @Test
    @DisplayName("should fall back to tenant id when event id is blank")
    void shouldFallBackToTenantIdWhenEventIdIsBlank() {
        TelemetryEvent telemetryEvent = telemetryEvent(" ", "factory-01");
        CompletableFuture<SendResult<String, TelemetryEvent>> sendFuture = new CompletableFuture<>();

        when(kafkaTemplate.send(kafkaProperties.getTopics().getRaw(), "factory-01", telemetryEvent))
                .thenReturn(sendFuture);

        CompletableFuture<SendResult<String, TelemetryEvent>> result =
                kafkaProducerService.publishTelemetryEvent(telemetryEvent);

        assertThat(result).isSameAs(sendFuture);
        verify(kafkaTemplate).send(kafkaProperties.getTopics().getRaw(), "factory-01", telemetryEvent);
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
}
