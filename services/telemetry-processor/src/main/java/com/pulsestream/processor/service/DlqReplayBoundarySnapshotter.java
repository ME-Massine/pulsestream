package com.pulsestream.processor.service;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.model.DeadLetterEvent;
import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.common.PartitionInfo;
import org.apache.kafka.common.TopicPartition;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.kafka.core.ConsumerFactory;
import org.springframework.stereotype.Component;

/** Captures the exact DLQ offset ranges that exist when an operator starts a replay. */
@Component
public class DlqReplayBoundarySnapshotter {

    private final ConsumerFactory<String, DeadLetterEvent> dlqConsumerFactory;

    private final String dlqTopic;

    public DlqReplayBoundarySnapshotter(
            @Qualifier("dlqConsumerFactory") ConsumerFactory<String, DeadLetterEvent> dlqConsumerFactory,
            TelemetryProcessorKafkaProperties kafkaProperties
    ) {
        this.dlqConsumerFactory = dlqConsumerFactory;
        this.dlqTopic = kafkaProperties.getTopics().getDlq();
    }

    public Map<TopicPartition, DlqReplayPartitionRange> snapshot() {
        try (Consumer<String, DeadLetterEvent> consumer = dlqConsumerFactory.createConsumer()) {
            List<PartitionInfo> partitionInfos = consumer.partitionsFor(dlqTopic);
            if (partitionInfos == null || partitionInfos.isEmpty()) {
                throw new IllegalStateException("DLQ topic '" + dlqTopic + "' has no partitions");
            }

            Set<TopicPartition> partitions = partitionInfos.stream()
                    .map(info -> new TopicPartition(info.topic(), info.partition()))
                    .collect(Collectors.toSet());
            Map<TopicPartition, Long> beginningOffsets = consumer.beginningOffsets(partitions);
            Map<TopicPartition, Long> endOffsets = consumer.endOffsets(partitions);
            Map<TopicPartition, DlqReplayPartitionRange> ranges = new LinkedHashMap<>();

            for (TopicPartition partition : partitions) {
                Long beginningOffset = beginningOffsets.get(partition);
                Long endOffset = endOffsets.get(partition);
                if (beginningOffset == null || endOffset == null) {
                    throw new IllegalStateException(
                            "Kafka did not return a complete offset range for DLQ partition " + partition
                    );
                }
                ranges.put(partition, new DlqReplayPartitionRange(beginningOffset, endOffset));
            }

            return Map.copyOf(ranges);
        } catch (IllegalStateException ex) {
            throw ex;
        } catch (RuntimeException ex) {
            throw new IllegalStateException(
                    "Failed to capture replay boundary for DLQ topic '" + dlqTopic + "'",
                    ex
            );
        }
    }
}
