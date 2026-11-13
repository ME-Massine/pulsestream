package com.pulsestream.processor.config;

import tools.jackson.databind.json.JsonMapper;
import com.pulsestream.processor.model.TelemetryEnvelope;
import java.util.HashMap;
import java.util.Map;

import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.common.serialization.StringSerializer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.core.ProducerFactory;
import org.springframework.kafka.support.serializer.JacksonJsonSerializer;

@Configuration
public class KafkaProducerConfiguration {

    @Bean
    ProducerFactory<String, TelemetryEnvelope> telemetryProducerFactory(
            TelemetryProcessorKafkaProperties kafkaProperties,
            JsonMapper jsonMapper
    ) {
        Map<String, Object> producerProperties = new HashMap<>();
        producerProperties.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, kafkaProperties.getBootstrapServers());
        producerProperties.put(ProducerConfig.CLIENT_ID_CONFIG, kafkaProperties.getProducer().getClientId());
        producerProperties.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, kafkaProperties.getProducer().getKeySerializer());
        producerProperties.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, kafkaProperties.getProducer().getValueSerializer());
        producerProperties.put(ProducerConfig.ACKS_CONFIG, kafkaProperties.getProducer().getAcknowledgements());
        producerProperties.put(ProducerConfig.RETRIES_CONFIG, kafkaProperties.getProducer().getRetries());
        producerProperties.put(
                ProducerConfig.DELIVERY_TIMEOUT_MS_CONFIG,
                Math.toIntExact(kafkaProperties.getProducer().getDeliveryTimeout().toMillis())
        );
        producerProperties.putAll(kafkaProperties.getProducer().getProperties());
        // Sends are awaited individually; Kafka's default linger must not exceed the 30s delivery budget.
        producerProperties.putIfAbsent(ProducerConfig.LINGER_MS_CONFIG, 0);

        // Replay must preserve the same per-device ordering guarantee as ingestion.
        producerProperties.put(ProducerConfig.MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION, 1);
        producerProperties.remove(ProducerConfig.PARTITIONER_CLASS_CONFIG);
        producerProperties.put(ProducerConfig.PARTITIONER_IGNORE_KEYS_CONFIG, false);

        DefaultKafkaProducerFactory<String, TelemetryEnvelope> producerFactory =
                new DefaultKafkaProducerFactory<>(producerProperties);

        if (JacksonJsonSerializer.class.getName().equals(kafkaProperties.getProducer().getValueSerializer())) {
            producerFactory.setValueSerializer(new JacksonJsonSerializer<>(jsonMapper));
        }

        return producerFactory;
    }

    @Bean
    KafkaTemplate<String, TelemetryEnvelope> telemetryKafkaTemplate(
            ProducerFactory<String, TelemetryEnvelope> telemetryProducerFactory
    ) {
        return new KafkaTemplate<>(telemetryProducerFactory);
    }

    /**
     * Outbox sends the JSON committed with the projection, without reserializing envelopes.
     */
    @Bean
    ProducerFactory<String, String> outboxProducerFactory(TelemetryProcessorKafkaProperties kafkaProperties) {
        Map<String, Object> producerProperties = new HashMap<>();
        producerProperties.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, kafkaProperties.getBootstrapServers());
        producerProperties.put(ProducerConfig.CLIENT_ID_CONFIG, kafkaProperties.getProducer().getClientId() + "-outbox");
        producerProperties.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        producerProperties.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        producerProperties.put(ProducerConfig.ACKS_CONFIG, kafkaProperties.getProducer().getAcknowledgements());
        producerProperties.put(ProducerConfig.RETRIES_CONFIG, kafkaProperties.getProducer().getRetries());
        producerProperties.put(
                ProducerConfig.DELIVERY_TIMEOUT_MS_CONFIG,
                Math.toIntExact(kafkaProperties.getProducer().getDeliveryTimeout().toMillis())
        );
        producerProperties.putAll(kafkaProperties.getProducer().getProperties());
        // Sends are awaited individually; Kafka's default linger must not exceed the 30s delivery budget.
        producerProperties.putIfAbsent(ProducerConfig.LINGER_MS_CONFIG, 0);

        producerProperties.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        producerProperties.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        requireDurableProducer(producerProperties);
        long timeout = kafkaProperties.getProducer().getPublishTimeout().toMillis();
        if (timeout <= 0) throw new IllegalArgumentException("Outbox publish timeout must be positive");
        producerProperties.put(ProducerConfig.MAX_BLOCK_MS_CONFIG, timeout);
        producerProperties.remove(ProducerConfig.PARTITIONER_CLASS_CONFIG);
        producerProperties.put(ProducerConfig.PARTITIONER_IGNORE_KEYS_CONFIG, false);
        return new DefaultKafkaProducerFactory<>(producerProperties);
    }

    @Bean
    KafkaTemplate<String, String> outboxKafkaTemplate(ProducerFactory<String, String> outboxProducerFactory) {
        return new KafkaTemplate<>(outboxProducerFactory);
    }

    private void requireDurableProducer(Map<String, Object> config) {
        if (!"all".equals(String.valueOf(config.get(ProducerConfig.ACKS_CONFIG)))
                && !"-1".equals(String.valueOf(config.get(ProducerConfig.ACKS_CONFIG)))) {
            throw new IllegalArgumentException("Outbox producer requires acks=all");
        }
        Object idempotence = config.get(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG);
        if (idempotence != null && !Boolean.parseBoolean(idempotence.toString())) {
            throw new IllegalArgumentException("Outbox producer requires idempotence");
        }
        Object inFlight = config.get(ProducerConfig.MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION);
        if (inFlight != null && !"1".equals(inFlight.toString())) {
            throw new IllegalArgumentException("Outbox producer requires one in-flight request");
        }
        if (Integer.parseInt(config.get(ProducerConfig.RETRIES_CONFIG).toString()) < 1) {
            throw new IllegalArgumentException("Outbox producer requires retries");
        }
        config.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);
        config.put(ProducerConfig.MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION, 1);
    }

}
