package com.pulsestream.processor.service;

import java.util.Map;
import java.util.Set;

import org.apache.kafka.common.TopicPartition;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class DlqReplaySessionTest {

    private static final TopicPartition PARTITION =
            new TopicPartition("telemetry.events.dlq", 0);

    @Test
    void shouldReplayOnlySelectedRecordsInsideTheTriggerTimeRange() {
        DlqReplaySession session = new DlqReplaySession();
        session.begin(
                Set.of("evt-1"),
                Map.of(PARTITION, new DlqReplayPartitionRange(3, 5))
        );

        assertThat(session.shouldReplay("evt-1", PARTITION, 3)).isTrue();
        assertThat(session.shouldReplay("evt-1", PARTITION, 4)).isTrue();
        assertThat(session.shouldReplay("evt-1", PARTITION, 5)).isFalse();
        assertThat(session.shouldReplay("evt-2", PARTITION, 4)).isFalse();
    }

    @Test
    void shouldClaimCompletionOnlyAfterEveryTriggerTimeOffsetIsProcessed() {
        DlqReplaySession session = new DlqReplaySession();
        session.begin(
                Set.of("evt-1"),
                Map.of(PARTITION, new DlqReplayPartitionRange(3, 5))
        );

        session.recordProcessed(PARTITION, 3);
        assertThat(session.claimCompletionIfBoundaryReached()).isFalse();

        session.recordProcessed(PARTITION, 4);
        assertThat(session.claimCompletionIfBoundaryReached()).isTrue();
        assertThat(session.claimCompletionIfBoundaryReached()).isFalse();
        assertThat(session.isActive()).isFalse();
    }
}
