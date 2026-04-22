package com.pulsestream.ingestion.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import com.pulsestream.ingestion.model.TelemetryEvent;
import com.pulsestream.ingestion.model.TelemetryPayload;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.core.ProducerFactory;

import static org.assertj.core.api.Assertions.assertThat;

class KafkaProducerConfigurationTest {

    private final KafkaProducerConfiguration configuration = new KafkaProducerConfiguration();

    @Test
    @DisplayName("should serialize telemetry event timestamps as ISO-8601 using the configured object mapper")
    void shouldSerializeTelemetryEventTimestampsAsIso8601UsingConfiguredObjectMapper() {
        PulsestreamKafkaProperties properties = new PulsestreamKafkaProperties();
        ObjectMapper objectMapper = new ObjectMapper()
                .registerModule(new JavaTimeModule())
                .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);

        ProducerFactory<String, TelemetryEvent> producerFactory =
                configuration.telemetryProducerFactory(properties, objectMapper);

        assertThat(producerFactory).isInstanceOf(DefaultKafkaProducerFactory.class);

        @SuppressWarnings("unchecked")
        DefaultKafkaProducerFactory<String, TelemetryEvent> defaultProducerFactory =
                (DefaultKafkaProducerFactory<String, TelemetryEvent>) producerFactory;

        byte[] payload = defaultProducerFactory.getValueSerializer().serialize(
                properties.getTopics().getRaw(),
                new TelemetryEvent(
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
                )
        );

        assertThat(new String(payload, StandardCharsets.UTF_8))
                .contains("\"timestamp\":\"2026-03-31T12:00:00Z\"");
    }
}
