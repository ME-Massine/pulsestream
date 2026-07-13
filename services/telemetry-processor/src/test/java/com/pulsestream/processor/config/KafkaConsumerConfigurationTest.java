package com.pulsestream.processor.config;

import com.pulsestream.processor.model.DeadLetterEvent;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.junit.jupiter.api.Test;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.kafka.core.ConsumerFactory;
import org.springframework.kafka.support.serializer.JsonDeserializer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;

class KafkaConsumerConfigurationTest {

    private final ApplicationContextRunner contextRunner = new ApplicationContextRunner()
            .withUserConfiguration(TestConfiguration.class)
            .withPropertyValues(
                    "pulsestream.kafka.bootstrap-servers=localhost:9092",
                    "pulsestream.kafka.consumer.group-id=telemetry-processor",
                    "pulsestream.kafka.consumer.key-deserializer=org.apache.kafka.common.serialization.StringDeserializer",
                    "pulsestream.kafka.consumer.value-deserializer=org.springframework.kafka.support.serializer.JsonDeserializer",
                    "pulsestream.kafka.consumer.auto-offset-reset=earliest",
                    "pulsestream.kafka.consumer.concurrency=2",
                    "pulsestream.kafka.consumer.properties.spring.json.trusted.packages=com.pulsestream.processor.dto",
                    "pulsestream.kafka.consumer.properties.spring.json.use.type.headers=false",
                    "pulsestream.kafka.topics.raw=telemetry.events.raw",
                    "pulsestream.kafka.consumer.dlq-group-id=telemetry-processor-dlq-replay",
                    "pulsestream.kafka.topics.dlq=telemetry.events.dlq"
            );

    @Test
    void shouldCreateKafkaConsumerInfrastructureForRawTelemetryTopic() {
        contextRunner.run(context -> {
            assertThat(context).hasBean("telemetryConsumerFactory");
            assertThat(context).hasBean("telemetryKafkaListenerContainerFactory");

            TelemetryProcessorKafkaProperties properties =
                    context.getBean(TelemetryProcessorKafkaProperties.class);

            assertThat(properties.getTopics().getRaw()).isEqualTo("telemetry.events.raw");
            assertThat(properties.getConsumer().getGroupId()).isEqualTo("telemetry-processor");
            assertThat(properties.getConsumer().getConcurrency()).isEqualTo(2);

            ConsumerFactory<?, ?> consumerFactory =
                    (ConsumerFactory<?, ?>) context.getBean("telemetryConsumerFactory");

            assertThat(consumerFactory.getConfigurationProperties())
                    .containsEntry(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092")
                    .containsEntry(ConsumerConfig.GROUP_ID_CONFIG, "telemetry-processor")
                    .containsEntry(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest")
                    .containsEntry(JsonDeserializer.VALUE_DEFAULT_TYPE, "com.pulsestream.processor.model.TelemetryEvent");
        });
    }

    @Test
    void shouldCreateKafkaConsumerInfrastructureForDlqTopicWithItsOwnGroupAndType() {
        contextRunner.run(context -> {
            assertThat(context).hasBean("dlqConsumerFactory");
            assertThat(context).hasBean("dlqKafkaListenerContainerFactory");

            TelemetryProcessorKafkaProperties properties =
                    context.getBean(TelemetryProcessorKafkaProperties.class);

            assertThat(properties.getTopics().getDlq()).isEqualTo("telemetry.events.dlq");
            assertThat(properties.getConsumer().getDlqGroupId()).isEqualTo("telemetry-processor-dlq-replay");

            ConsumerFactory<?, ?> dlqConsumerFactory =
                    (ConsumerFactory<?, ?>) context.getBean("dlqConsumerFactory");

            assertThat(dlqConsumerFactory.getConfigurationProperties())
                    .containsEntry(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092")
                    .containsEntry(ConsumerConfig.GROUP_ID_CONFIG, "telemetry-processor-dlq-replay")
                    .containsEntry(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest")
                    .containsEntry(JsonDeserializer.VALUE_DEFAULT_TYPE, "com.pulsestream.processor.model.DeadLetterEvent");
        });
    }

    @Test
    void shouldDeserializeProducerShapedJsonIntoDeadLetterEvent() {
        contextRunner.run(context -> {
            ConsumerFactory<?, ?> dlqConsumerFactory =
                    (ConsumerFactory<?, ?>) context.getBean("dlqConsumerFactory");

            // JSON exactly as the ingestion-service / telemetry-processor DLQ producers
            // serialize the shared DeadLetterEvent envelope (no type headers).
            String producerJson = """
                    {
                      "event": {
                        "eventId": "evt-001",
                        "tenantId": "factory-01",
                        "eventType": "telemetry.reading",
                        "timestamp": "2026-03-31T12:00:00Z",
                        "source": "sensor-gateway",
                        "version": "1.0",
                        "payload": {
                          "deviceId": "sensor-1042",
                          "deviceType": "temperature-sensor",
                          "metric": "temperature",
                          "value": 28.4,
                          "unit": "C",
                          "location": "zone-a"
                        }
                      },
                      "errorMessage": "normalization exploded",
                      "sourceService": "ingestion-service",
                      "failedAt": "2026-04-01T09:30:00Z"
                    }
                    """;

            try (JsonDeserializer<?> deserializer = new JsonDeserializer<>()) {
                deserializer.configure(dlqConsumerFactory.getConfigurationProperties(), false);

                Object deserialized = deserializer.deserialize(
                        "telemetry.events.dlq",
                        producerJson.getBytes(StandardCharsets.UTF_8)
                );

                assertThat(deserialized).isInstanceOf(DeadLetterEvent.class);

                DeadLetterEvent deadLetterEvent = (DeadLetterEvent) deserialized;
                assertThat(deadLetterEvent.errorMessage()).isEqualTo("normalization exploded");
                assertThat(deadLetterEvent.sourceService()).isEqualTo("ingestion-service");
                assertThat(deadLetterEvent.failedAt()).isEqualTo(Instant.parse("2026-04-01T09:30:00Z"));
                assertThat(deadLetterEvent.event().eventId()).isEqualTo("evt-001");
                assertThat(deadLetterEvent.event().tenantId()).isEqualTo("factory-01");
                assertThat(deadLetterEvent.event().timestamp()).isEqualTo(Instant.parse("2026-03-31T12:00:00Z"));
                assertThat(deadLetterEvent.event().payload().deviceId()).isEqualTo("sensor-1042");
                assertThat(deadLetterEvent.event().payload().value()).isEqualByComparingTo(new BigDecimal("28.4"));
            }
        });
    }

    @EnableConfigurationProperties(TelemetryProcessorKafkaProperties.class)
    static class TestConfiguration extends KafkaConsumerConfiguration {
    }
}