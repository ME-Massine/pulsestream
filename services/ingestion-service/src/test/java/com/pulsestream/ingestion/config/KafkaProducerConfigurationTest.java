package com.pulsestream.ingestion.config;

import tools.jackson.databind.cfg.DateTimeFeature;
import tools.jackson.databind.json.JsonMapper;
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
    @DisplayName("should serialize telemetry event timestamps as ISO-8601 using the configured JSON mapper")
    void shouldSerializeTelemetryEventTimestampsAsIso8601UsingConfiguredJsonMapper() {
        PulsestreamKafkaProperties properties = new PulsestreamKafkaProperties();
        properties.getProducer().getProperties().put("max.in.flight.requests.per.connection", "5");
        properties.getProducer().getProperties().put("partitioner.ignore.keys", "true");
        properties.getProducer().getProperties().put("partitioner.class", "custom.Partitioner");
        JsonMapper jsonMapper = JsonMapper.builder()
                .disable(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS)
                .build();

        ProducerFactory<String, TelemetryEvent> producerFactory =
                configuration.telemetryProducerFactory(properties, jsonMapper);

        assertThat(producerFactory).isInstanceOf(DefaultKafkaProducerFactory.class);

        @SuppressWarnings("unchecked")
        DefaultKafkaProducerFactory<String, TelemetryEvent> defaultProducerFactory =
                (DefaultKafkaProducerFactory<String, TelemetryEvent>) producerFactory;

        assertThat(defaultProducerFactory.getConfigurationProperties())
                .containsEntry(org.apache.kafka.clients.producer.ProducerConfig.MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION, 1)
                .containsEntry(org.apache.kafka.clients.producer.ProducerConfig.PARTITIONER_IGNORE_KEYS_CONFIG, false)
                .doesNotContainKey(org.apache.kafka.clients.producer.ProducerConfig.PARTITIONER_CLASS_CONFIG);

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
