package com.pulsestream.processor.service;

import java.util.List;
import java.util.Map;
import java.util.Set;

import org.apache.kafka.common.TopicPartition;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class DlqReplaySessionTest {

    private static final TopicPartition PARTITION =
            new TopicPartition("telemetry.events.dlq", 0);

    private static final TopicPartition PARTITION_1 =
            new TopicPartition("telemetry.events.dlq", 1);

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

    @Test
    void shouldClaimIdleFallbackStopOnlyOnceWhileActive() {
        DlqReplaySession session = new DlqReplaySession();
        assertThat(session.claimIdleFallbackStop(List.of(PARTITION))).isFalse();

        session.begin(
                Set.of("evt-1"),
                Map.of(PARTITION, new DlqReplayPartitionRange(3, 5))
        );

        assertThat(session.claimIdleFallbackStop(List.of(PARTITION))).isTrue();
        assertThat(session.claimIdleFallbackStop(List.of(PARTITION))).isFalse();
        assertThat(session.isActive()).isFalse();
    }

    @Test
    void shouldNotClaimIdleFallbackStopWhileAnotherPartitionIsStillScanning() {
        DlqReplaySession session = new DlqReplaySession();
        session.begin(
                Set.of("evt-1"),
                Map.of(
                        PARTITION, new DlqReplayPartitionRange(0, 1),
                        PARTITION_1, new DlqReplayPartitionRange(0, 1)
                )
        );

        // One child drains and idles while the sibling child has not scanned its partition yet.
        session.recordProcessed(PARTITION, 0);
        assertThat(session.claimIdleFallbackStop(List.of(PARTITION))).isFalse();
        assertThat(session.isActive()).isTrue();

        // The sibling child now idles too (its tail record can no longer be delivered), so every
        // trigger-time partition is settled and the fallback stop is finally claimed exactly once.
        assertThat(session.claimIdleFallbackStop(List.of(PARTITION_1))).isTrue();
        assertThat(session.claimIdleFallbackStop(List.of(PARTITION_1))).isFalse();
        assertThat(session.isActive()).isFalse();
    }

    @Test
    void shouldClaimIdleFallbackStopWhenIdleChildCoversTheOnlyUnscannedPartition() {
        DlqReplaySession session = new DlqReplaySession();
        session.begin(
                Set.of("evt-1"),
                Map.of(
                        PARTITION, new DlqReplayPartitionRange(0, 1),
                        PARTITION_1, new DlqReplayPartitionRange(0, 1)
                )
        );

        // PARTITION reached its boundary through normal processing; only PARTITION_1 is stalled.
        session.recordProcessed(PARTITION, 0);
        assertThat(session.claimIdleFallbackStop(List.of(PARTITION_1))).isTrue();
        assertThat(session.isActive()).isFalse();
    }

    @Test
    void clearScopedToARunShouldNotWipeANewerRun() {
        DlqReplaySession session = new DlqReplaySession();
        session.begin(
                Set.of("evt-1"),
                Map.of(PARTITION, new DlqReplayPartitionRange(3, 5))
        );
        long firstRunId = session.currentRunId();

        session.begin(
                Set.of("evt-2"),
                Map.of(PARTITION, new DlqReplayPartitionRange(5, 7))
        );

        session.clearIfRunIs(firstRunId);
        assertThat(session.isActive()).isTrue();
        assertThat(session.selectedEventIds()).containsExactly("evt-2");

        session.clearIfRunIs(session.currentRunId());
        assertThat(session.isActive()).isFalse();
        assertThat(session.selectedEventIds()).isEmpty();
    }
}
