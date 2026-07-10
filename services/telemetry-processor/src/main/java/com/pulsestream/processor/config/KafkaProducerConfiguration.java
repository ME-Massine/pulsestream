package com.pulsestream.processor.config;

import com.fasterxml.jackson.databind.ObjectMapper;
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
import org.springframework.kafka.support.serializer.JsonSerializer;

@Configuration
public class KafkaProducerConfiguration {

    @Bean
    ProducerFactory<String, TelemetryEnvelope> telemetryProducerFactory(
            TelemetryProcessorKafkaProperties kafkaProperties,
            ObjectMapper objectMapper
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

        DefaultKafkaProducerFactory<String, TelemetryEnvelope> producerFactory =
                new DefaultKafkaProducerFactory<>(producerProperties);

        if (JsonSerializer.class.getName().equals(kafkaProperties.getProducer().getValueSerializer())) {
            producerFactory.setValueSerializer(new JsonSerializer<>(objectMapper));
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
     * Producer factory dedicated to the dead-letter queue. It uses a {@link StringSerializer}
     * for the value so a failed event is captured as a pre-rendered string, independent of the
     * JSON serializer used for the regular topics.
     */
    @Bean
    ProducerFactory<String, String> dlqProducerFactory(TelemetryProcessorKafkaProperties kafkaProperties) {
        Map<String, Object> producerProperties = new HashMap<>();
        producerProperties.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, kafkaProperties.getBootstrapServers());
        producerProperties.put(ProducerConfig.CLIENT_ID_CONFIG, kafkaProperties.getProducer().getClientId() + "-dlq");
        producerProperties.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        producerProperties.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        producerProperties.put(ProducerConfig.ACKS_CONFIG, kafkaProperties.getProducer().getAcknowledgements());
        producerProperties.put(ProducerConfig.RETRIES_CONFIG, kafkaProperties.getProducer().getRetries());
        producerProperties.put(
                ProducerConfig.DELIVERY_TIMEOUT_MS_CONFIG,
                Math.toIntExact(kafkaProperties.getProducer().getDeliveryTimeout().toMillis())
        );
        producerProperties.putAll(kafkaProperties.getProducer().getProperties());

        return new DefaultKafkaProducerFactory<>(producerProperties);
    }

    @Bean
    KafkaTemplate<String, String> dlqKafkaTemplate(ProducerFactory<String, String> dlqProducerFactory) {
        return new KafkaTemplate<>(dlqProducerFactory);
    }
}
