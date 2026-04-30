package com.pulsestream.processor.config;

import org.junit.jupiter.api.Test;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

import static org.assertj.core.api.Assertions.assertThat;

class TelemetryProcessorKafkaPropertiesTest {

    private final ApplicationContextRunner contextRunner = new ApplicationContextRunner()
            .withUserConfiguration(TestConfiguration.class)
            .withPropertyValues(
                    "pulsestream.kafka.bootstrap-servers=localhost:9092",
                    "pulsestream.kafka.consumer.group-id=telemetry-processor",
                    "pulsestream.kafka.consumer.auto-offset-reset=earliest",
                    "pulsestream.kafka.consumer.concurrency=2",
                    "pulsestream.kafka.topics.raw=telemetry.events.raw"
            );

    @Test
    void shouldBindKafkaConsumerProperties() {
        contextRunner.run(context -> {
            TelemetryProcessorKafkaProperties properties =
                    context.getBean(TelemetryProcessorKafkaProperties.class);

            assertThat(properties.getBootstrapServers()).isEqualTo("localhost:9092");
            assertThat(properties.getConsumer().getGroupId()).isEqualTo("telemetry-processor");
            assertThat(properties.getConsumer().getAutoOffsetReset()).isEqualTo("earliest");
            assertThat(properties.getConsumer().getConcurrency()).isEqualTo(2);
            assertThat(properties.getTopics().getRaw()).isEqualTo("telemetry.events.raw");
        });
    }

    @EnableConfigurationProperties(TelemetryProcessorKafkaProperties.class)
    static class TestConfiguration {
    }
}