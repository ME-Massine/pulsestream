package com.pulsestream.processor.config;

import java.util.HashMap;
import java.util.Map;

import com.pulsestream.processor.model.DeadLetterEvent;
import com.pulsestream.processor.model.TelemetryEvent;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.config.ConcurrentKafkaListenerContainerFactory;
import org.springframework.kafka.core.ConsumerFactory;
import org.springframework.kafka.core.DefaultKafkaConsumerFactory;
import org.springframework.kafka.listener.CommonContainerStoppingErrorHandler;
import org.springframework.kafka.support.serializer.JsonDeserializer;

@Configuration
public class KafkaConsumerConfiguration {

    @Bean
    public ConsumerFactory<String, TelemetryEvent> telemetryConsumerFactory(
            TelemetryProcessorKafkaProperties kafkaProperties
    ) {
        Map<String, Object> consumerProperties = new HashMap<>();

        consumerProperties.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, kafkaProperties.getBootstrapServers());
        consumerProperties.put(ConsumerConfig.GROUP_ID_CONFIG, kafkaProperties.getConsumer().getGroupId());
        consumerProperties.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, kafkaProperties.getConsumer().getKeyDeserializer());
        consumerProperties.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, kafkaProperties.getConsumer().getValueDeserializer());
        consumerProperties.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, kafkaProperties.getConsumer().getAutoOffsetReset());
        consumerProperties.put(JsonDeserializer.VALUE_DEFAULT_TYPE, TelemetryEvent.class.getName());
        consumerProperties.put(JsonDeserializer.TRUSTED_PACKAGES, TelemetryEvent.class.getPackageName());

        consumerProperties.putAll(kafkaProperties.getConsumer().getProperties());

        return new DefaultKafkaConsumerFactory<>(consumerProperties);
    }

    @Bean
    public ConcurrentKafkaListenerContainerFactory<String, TelemetryEvent> telemetryKafkaListenerContainerFactory(
            ConsumerFactory<String, TelemetryEvent> telemetryConsumerFactory,
            TelemetryProcessorKafkaProperties kafkaProperties
    ) {
        ConcurrentKafkaListenerContainerFactory<String, TelemetryEvent> factory =
                new ConcurrentKafkaListenerContainerFactory<>();

        factory.setConsumerFactory(telemetryConsumerFactory);
        factory.setConcurrency(kafkaProperties.getConsumer().getConcurrency());

        return factory;
    }

    @Bean
    public ConsumerFactory<String, DeadLetterEvent> dlqConsumerFactory(
            TelemetryProcessorKafkaProperties kafkaProperties
    ) {
        Map<String, Object> consumerProperties = new HashMap<>();

        // Shared consumer properties are applied first so the DLQ-specific overrides below
        // (group id, deserialization target type) always win, even if the shared map also
        // configures a default type for the raw-topic consumer.
        consumerProperties.putAll(kafkaProperties.getConsumer().getProperties());
        consumerProperties.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, kafkaProperties.getBootstrapServers());
        consumerProperties.put(ConsumerConfig.GROUP_ID_CONFIG, kafkaProperties.getConsumer().getDlqGroupId());
        consumerProperties.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, kafkaProperties.getConsumer().getKeyDeserializer());
        consumerProperties.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, kafkaProperties.getConsumer().getValueDeserializer());
        consumerProperties.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, kafkaProperties.getConsumer().getAutoOffsetReset());
        consumerProperties.put(JsonDeserializer.VALUE_DEFAULT_TYPE, DeadLetterEvent.class.getName());
        consumerProperties.put(JsonDeserializer.TRUSTED_PACKAGES, DeadLetterEvent.class.getPackageName());

        return new DefaultKafkaConsumerFactory<>(consumerProperties);
    }

    @Bean
    public ConcurrentKafkaListenerContainerFactory<String, DeadLetterEvent> dlqKafkaListenerContainerFactory(
            ConsumerFactory<String, DeadLetterEvent> dlqConsumerFactory,
            TelemetryProcessorKafkaProperties kafkaProperties
    ) {
        ConcurrentKafkaListenerContainerFactory<String, DeadLetterEvent> factory =
                new ConcurrentKafkaListenerContainerFactory<>();

        factory.setConsumerFactory(dlqConsumerFactory);
        factory.setConcurrency(kafkaProperties.getConsumer().getConcurrency());

        // Bounded replay (#125) primarily stops when the listener reaches the per-partition end
        // offsets captured at trigger time. Idle events are retained as a fallback signal, but
        // DlqReplayService stops on idle only after every captured range has been scanned.
        factory.getContainerProperties().setIdleEventInterval(
                kafkaProperties.getConsumer().getDlqReplayIdleTimeout().toMillis()
        );

        // No-data-loss policy for replay (#124): when a republish fails, DeadLetterEventConsumer lets
        // the exception propagate. This handler stops the replay container without committing the
        // failed record's offset, so the record stays uncommitted and is redelivered when an operator
        // restarts the listener — the offset only advances after a successful republish. Without it,
        // Spring Kafka's default handler would eventually recover (skip) the record and let the offset
        // advance, silently dropping the DLQ record.
        factory.setCommonErrorHandler(new CommonContainerStoppingErrorHandler());

        return factory;
    }
}
