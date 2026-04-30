package com.pulsestream.processor.config;

import java.util.HashMap;
import java.util.Map;

import com.pulsestream.processor.model.TelemetryEvent;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.config.ConcurrentKafkaListenerContainerFactory;
import org.springframework.kafka.core.ConsumerFactory;
import org.springframework.kafka.core.DefaultKafkaConsumerFactory;

@Configuration
public class KafkaConsumerConfiguration {

    @Bean
    public ConsumerFactory<String, Object> telemetryConsumerFactory(
            TelemetryProcessorKafkaProperties kafkaProperties
    ) {
        Map<String, Object> consumerProperties = new HashMap<>();

        consumerProperties.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, kafkaProperties.getBootstrapServers());
        consumerProperties.put(ConsumerConfig.GROUP_ID_CONFIG, kafkaProperties.getConsumer().getGroupId());
        consumerProperties.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, kafkaProperties.getConsumer().getKeyDeserializer());
        consumerProperties.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, kafkaProperties.getConsumer().getValueDeserializer());
        consumerProperties.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, kafkaProperties.getConsumer().getAutoOffsetReset());

        consumerProperties.putAll(kafkaProperties.getConsumer().getProperties());

        return new DefaultKafkaConsumerFactory<>(consumerProperties);
    }

    @Bean
    public ConcurrentKafkaListenerContainerFactory<String, Object> telemetryKafkaListenerContainerFactory(
            ConsumerFactory<String, Object> telemetryConsumerFactory,
            TelemetryProcessorKafkaProperties kafkaProperties
    ) {
        ConcurrentKafkaListenerContainerFactory<String, Object> factory =
                new ConcurrentKafkaListenerContainerFactory<>();

        factory.setConsumerFactory(telemetryConsumerFactory);
        factory.setConcurrency(kafkaProperties.getConsumer().getConcurrency());

        return factory;
    }
}