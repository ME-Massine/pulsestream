package com.pulsestream.processor.config;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

import com.pulsestream.processor.model.DeadLetterEvent;
import com.pulsestream.processor.model.TelemetryEvent;
import com.pulsestream.processor.service.DlqReplaySession;
import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.config.ConcurrentKafkaListenerContainerFactory;
import org.springframework.kafka.core.ConsumerFactory;
import org.springframework.kafka.core.DefaultKafkaConsumerFactory;
import org.springframework.kafka.listener.CommonContainerStoppingErrorHandler;
import org.springframework.kafka.listener.MessageListenerContainer;
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
            TelemetryProcessorKafkaProperties kafkaProperties,
            DlqReplaySession replaySession
    ) {
        ConcurrentKafkaListenerContainerFactory<String, DeadLetterEvent> factory =
                new ConcurrentKafkaListenerContainerFactory<>();

        factory.setConsumerFactory(dlqConsumerFactory);
        factory.setConcurrency(kafkaProperties.getConsumer().getConcurrency());

        // Bounded replay (#125) primarily stops when the listener reaches the per-partition end
        // offsets captured at trigger time. Idle events are the fallback: DlqReplayService stops
        // the listener on idle once every captured range has been scanned, and also stops it when
        // the listener goes idle before reaching the boundary (tail records no longer deliverable).
        factory.getContainerProperties().setIdleEventInterval(
                kafkaProperties.getConsumer().getDlqReplayIdleTimeout().toMillis()
        );

        // No-data-loss policy for replay (#124): when a republish fails, DeadLetterEventConsumer lets
        // the exception propagate. This handler stops the replay container without committing the
        // failed record's offset, so the record stays uncommitted and is redelivered when an operator
        // restarts the listener — the offset only advances after a successful republish. Without it,
        // Spring Kafka's default handler would eventually recover (skip) the record and let the offset
        // advance, silently dropping the DLQ record.
        factory.setCommonErrorHandler(new DlqReplaySessionClearingErrorHandler(replaySession));

        return factory;
    }

    /**
     * {@link CommonContainerStoppingErrorHandler} that also ends the replay session (#125) when it
     * stops the container on a failed republish. Without the clear, the session would keep the run
     * marked active with its selection after the container died, so the actuator status would report
     * a selection with {@code running=false} and the idle fallback could never fire. The failed
     * record's offset stays uncommitted, so it is redelivered when an operator triggers the next
     * replay for it.
     */
    static final class DlqReplaySessionClearingErrorHandler extends CommonContainerStoppingErrorHandler {

        private final DlqReplaySession replaySession;

        DlqReplaySessionClearingErrorHandler(DlqReplaySession replaySession) {
            this.replaySession = replaySession;
        }

        @Override
        public void handleRemaining(
                Exception thrownException,
                List<ConsumerRecord<?, ?>> records,
                Consumer<?, ?> consumer,
                MessageListenerContainer container
        ) {
            try {
                super.handleRemaining(thrownException, records, consumer, container);
            } finally {
                replaySession.clear();
            }
        }

        @Override
        public void handleBatch(
                Exception thrownException,
                ConsumerRecords<?, ?> data,
                Consumer<?, ?> consumer,
                MessageListenerContainer container,
                Runnable invokeListener
        ) {
            try {
                super.handleBatch(thrownException, data, consumer, container, invokeListener);
            } finally {
                replaySession.clear();
            }
        }

        @Override
        public void handleOtherException(
                Exception thrownException,
                Consumer<?, ?> consumer,
                MessageListenerContainer container,
                boolean batchListener
        ) {
            try {
                super.handleOtherException(thrownException, consumer, container, batchListener);
            } finally {
                replaySession.clear();
            }
        }
    }
}
