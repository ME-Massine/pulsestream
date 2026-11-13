package com.pulsestream.processor.config;

import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.common.serialization.StringSerializer;
import org.junit.jupiter.api.Test;
import org.springframework.boot.jackson.autoconfigure.JacksonAutoConfiguration;
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
                    "pulsestream.kafka.producer.delivery-timeout=45s",
                    "pulsestream.kafka.producer.properties.max.in.flight.requests.per.connection=1",
                    "pulsestream.kafka.producer.properties.partitioner.ignore.keys=true",
                    "pulsestream.kafka.producer.publish-timeout=5s"
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
                    .containsEntry(ProducerConfig.MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION, 1)
                    .containsEntry(ProducerConfig.PARTITIONER_IGNORE_KEYS_CONFIG, false)
                    .doesNotContainKey(ProducerConfig.PARTITIONER_CLASS_CONFIG)
                    .containsEntry(ProducerConfig.DELIVERY_TIMEOUT_MS_CONFIG, 45000);
        });
    }

    @Test
    void shouldCreateDlqProducerInfrastructureUsingStringSerializer() {
        contextRunner.run(context -> {
            assertThat(context).hasBean("outboxProducerFactory");

            ProducerFactory<?, ?> outboxProducerFactory =
                    context.getBean("outboxProducerFactory", ProducerFactory.class);

            assertThat(outboxProducerFactory.getConfigurationProperties())
                    .containsEntry(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092")
                    .containsEntry(ProducerConfig.CLIENT_ID_CONFIG, "telemetry-processor-producer-outbox")
                    .containsEntry(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName())
                    .containsEntry(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName())
                    .containsEntry(ProducerConfig.ACKS_CONFIG, "all")
                    .containsEntry(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true)
                    .containsEntry(ProducerConfig.MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION, 1);

            assertThat(context.getBean("outboxKafkaTemplate", KafkaTemplate.class)).isNotNull();
        });
    }

    @Test
    void defaultOutboxConfigurationCreatesAProducer() {
        contextRunner.withPropertyValues("pulsestream.kafka.producer.delivery-timeout=30s")
                .run(context -> {
                    for (String bean : new String[] {"outboxProducerFactory", "telemetryProducerFactory"}) {
                        var factory = context.getBean(bean, ProducerFactory.class);
                        var producer = factory.createProducer();
                        producer.close(java.time.Duration.ZERO);
                    }
                });
    }

    @Test
    void rejectsDurabilityOverrides() {
        for (String property : new String[] {
                "acknowledgements=1", "properties.acks=0", "properties.enable.idempotence=false",
                "properties.max.in.flight.requests.per.connection=5", "retries=0", "publish-timeout=0s"}) {
            contextRunner.withPropertyValues("pulsestream.kafka.producer." + property)
                    .run(context -> assertThat(context).hasFailed());
        }
    }

    @EnableConfigurationProperties(TelemetryProcessorKafkaProperties.class)
    static class TestConfiguration extends KafkaProducerConfiguration {
    }
}
