package com.pulsestream.processor.config;

import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.common.serialization.StringSerializer;
import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.jackson.JacksonAutoConfiguration;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.core.ProducerFactory;

import static org.assertj.core.api.Assertions.assertThat;

class KafkaProducerConfigurationTest {

    private final ApplicationContextRunner contextRunner = new ApplicationContextRunner()
            .withConfiguration(org.springframework.boot.autoconfigure.AutoConfigurations.of(JacksonAutoConfiguration.class))
            .withUserConfiguration(TestConfiguration.class)
            .withPropertyValues(
                    "pulsestream.kafka.bootstrap-servers=localhost:9092",
                    "pulsestream.kafka.producer.client-id=telemetry-processor-producer",
                    "pulsestream.kafka.producer.acks=all",
                    "pulsestream.kafka.producer.retries=5",
                    "pulsestream.kafka.producer.delivery-timeout=45s"
            );

    @Test
    void shouldCreateKafkaProducerInfrastructureForProcessedTelemetryTopic() {
        contextRunner.run(context -> {
            assertThat(context).hasBean("telemetryProducerFactory");

            ProducerFactory<?, ?> producerFactory =
                    context.getBean("telemetryProducerFactory", ProducerFactory.class);

            assertThat(producerFactory.getConfigurationProperties())
                    .containsEntry(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092")
                    .containsEntry(ProducerConfig.CLIENT_ID_CONFIG, "telemetry-processor-producer")
                    .containsEntry(ProducerConfig.ACKS_CONFIG, "all")
                    .containsEntry(ProducerConfig.RETRIES_CONFIG, 5)
                    .containsEntry(ProducerConfig.DELIVERY_TIMEOUT_MS_CONFIG, 45000);
        });
    }

    @Test
    void shouldCreateDlqProducerInfrastructureUsingStringSerializer() {
        contextRunner.run(context -> {
            assertThat(context).hasBean("dlqProducerFactory");

            ProducerFactory<?, ?> dlqProducerFactory =
                    context.getBean("dlqProducerFactory", ProducerFactory.class);

            assertThat(dlqProducerFactory.getConfigurationProperties())
                    .containsEntry(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092")
                    .containsEntry(ProducerConfig.CLIENT_ID_CONFIG, "telemetry-processor-producer-dlq")
                    .containsEntry(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName())
                    .containsEntry(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());

            assertThat(context.getBean("dlqKafkaTemplate", KafkaTemplate.class)).isNotNull();
        });
    }

    @EnableConfigurationProperties(TelemetryProcessorKafkaProperties.class)
    static class TestConfiguration extends KafkaProducerConfiguration {
    }
}
