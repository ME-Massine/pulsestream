package com.pulsestream.processor.service;

import java.util.List;
import java.util.Map;

import com.pulsestream.processor.config.TelemetryProcessorKafkaProperties;
import com.pulsestream.processor.model.DeadLetterEvent;
import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.common.Node;
import org.apache.kafka.common.PartitionInfo;
import org.apache.kafka.common.TopicPartition;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.kafka.core.ConsumerFactory;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class DlqReplayBoundarySnapshotterTest {

    private static final String DLQ_TOPIC = "telemetry.events.dlq";

    private static final TopicPartition PARTITION = new TopicPartition(DLQ_TOPIC, 0);

    @Mock
    private ConsumerFactory<String, DeadLetterEvent> consumerFactory;

    @Mock
    private Consumer<String, DeadLetterEvent> consumer;

    private DlqReplayBoundarySnapshotter snapshotter;

    @BeforeEach
    void setUp() {
        TelemetryProcessorKafkaProperties properties = new TelemetryProcessorKafkaProperties();
        properties.getTopics().setDlq(DLQ_TOPIC);
        snapshotter = new DlqReplayBoundarySnapshotter(consumerFactory, properties);
    }

    @Test
    void shouldCaptureBeginningAndEndOffsetsForEveryDlqPartition() {
        when(consumerFactory.createConsumer()).thenReturn(consumer);
        when(consumer.partitionsFor(DLQ_TOPIC)).thenReturn(List.of(partitionInfo(0)));
        when(consumer.beginningOffsets(java.util.Set.of(PARTITION))).thenReturn(Map.of(PARTITION, 3L));
        when(consumer.endOffsets(java.util.Set.of(PARTITION))).thenReturn(Map.of(PARTITION, 8L));

        Map<TopicPartition, DlqReplayPartitionRange> result = snapshotter.snapshot();

        assertThat(result).containsEntry(PARTITION, new DlqReplayPartitionRange(3, 8));
        verify(consumer).close();
    }

    @Test
    void shouldFailClearlyWhenTheDlqTopicHasNoPartitions() {
        when(consumerFactory.createConsumer()).thenReturn(consumer);
        when(consumer.partitionsFor(DLQ_TOPIC)).thenReturn(List.of());

        assertThatThrownBy(snapshotter::snapshot)
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining(DLQ_TOPIC)
                .hasMessageContaining("no partitions");

        verify(consumer).close();
    }

    private PartitionInfo partitionInfo(int partition) {
        return new PartitionInfo(DLQ_TOPIC, partition, null, new Node[0], new Node[0]);
    }
}
