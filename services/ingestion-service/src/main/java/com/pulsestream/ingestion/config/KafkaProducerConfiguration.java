package com.pulsestream.ingestion.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.pulsestream.ingestion.model.TelemetryEvent;
import java.util.HashMap;
import java.util.Map;

import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.common.serialization.StringSerializer;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.core.ProducerFactory;
import org.springframework.kafka.support.serializer.JsonSerializer;

@Configuration
@EnableConfigurationProperties(PulsestreamKafkaProperties.class)
public class KafkaProducerConfiguration {

    @Bean
    ProducerFactory<String, TelemetryEvent> telemetryProducerFactory(
            PulsestreamKafkaProperties kafkaProperties,
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

        DefaultKafkaProducerFactory<String, TelemetryEvent> producerFactory =
                new DefaultKafkaProducerFactory<>(producerProperties);

        if (JsonSerializer.class.getName().equals(kafkaProperties.getProducer().getValueSerializer())) {
            producerFactory.setValueSerializer(new JsonSerializer<>(objectMapper));
        }

        return producerFactory;
    }

    @Bean
    KafkaTemplate<String, TelemetryEvent> telemetryKafkaTemplate(
            ProducerFactory<String, TelemetryEvent> telemetryProducerFactory
    ) {
        return new KafkaTemplate<>(telemetryProducerFactory);
    }

    /**
     * Producer factory dedicated to the dead-letter queue. It uses a
     * {@link StringSerializer} for the value so that a failed event can be
     * captured as a pre-rendered string, independently of the JSON serializer
     * that produces the raw topic value. This ensures a raw-topic serialization
     * failure is not simply repeated when the event is rerouted to the DLQ.
     */
    @Bean
    ProducerFactory<String, String> dlqProducerFactory(PulsestreamKafkaProperties kafkaProperties) {
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
    KafkaTemplate<String, String> dlqKafkaTemplate(
            ProducerFactory<String, String> dlqProducerFactory
    ) {
        return new KafkaTemplate<>(dlqProducerFactory);
    }
}
