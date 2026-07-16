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

    @Test
    void shouldClaimIdleFallbackStopOnlyOnceWhileActive() {
        DlqReplaySession session = new DlqReplaySession();
        assertThat(session.claimIdleFallbackStop()).isFalse();

        session.begin(
                Set.of("evt-1"),
                Map.of(PARTITION, new DlqReplayPartitionRange(3, 5))
        );

        assertThat(session.claimIdleFallbackStop()).isTrue();
        assertThat(session.claimIdleFallbackStop()).isFalse();
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
