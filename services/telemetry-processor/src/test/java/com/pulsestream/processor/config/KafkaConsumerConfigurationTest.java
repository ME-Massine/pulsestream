package com.pulsestream.processor.config;

import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.junit.jupiter.api.Test;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.kafka.config.ConcurrentKafkaListenerContainerFactory;
import org.springframework.kafka.core.ConsumerFactory;

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
                    "pulsestream.kafka.topics.raw=telemetry.events.raw"
            );

    @Test
    void shouldCreateKafkaConsumerInfrastructureForRawTelemetryTopic() {
        contextRunner.run(context -> {
            assertThat(context).hasSingleBean(ConsumerFactory.class);
            assertThat(context).hasSingleBean(ConcurrentKafkaListenerContainerFactory.class);

            TelemetryProcessorKafkaProperties properties =
                    context.getBean(TelemetryProcessorKafkaProperties.class);

            assertThat(properties.getTopics().getRaw()).isEqualTo("telemetry.events.raw");
            assertThat(properties.getConsumer().getGroupId()).isEqualTo("telemetry-processor");
            assertThat(properties.getConsumer().getConcurrency()).isEqualTo(2);

            ConsumerFactory<?, ?> consumerFactory = context.getBean(ConsumerFactory.class);

            assertThat(consumerFactory.getConfigurationProperties())
                    .containsEntry(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092")
                    .containsEntry(ConsumerConfig.GROUP_ID_CONFIG, "telemetry-processor")
                    .containsEntry(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        });
    }

    @EnableConfigurationProperties(TelemetryProcessorKafkaProperties.class)
    static class TestConfiguration extends KafkaConsumerConfiguration {
    }
}