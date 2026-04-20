package com.pulsestream.ingestion.config;

import java.util.HashMap;
import java.util.Map;

import org.apache.kafka.clients.producer.ProducerConfig;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.core.ProducerFactory;

@Configuration
@EnableConfigurationProperties(PulsestreamKafkaProperties.class)
public class KafkaProducerConfiguration {

    @Bean
    ProducerFactory<String, Object> telemetryProducerFactory(PulsestreamKafkaProperties kafkaProperties) {
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

        return new DefaultKafkaProducerFactory<>(producerProperties);
    }

    @Bean
    KafkaTemplate<String, Object> telemetryKafkaTemplate(ProducerFactory<String, Object> telemetryProducerFactory) {
        return new KafkaTemplate<>(telemetryProducerFactory);
    }
}
