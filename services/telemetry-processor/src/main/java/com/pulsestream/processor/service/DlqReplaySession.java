package com.pulsestream.processor.service;

import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import org.apache.kafka.common.TopicPartition;
import org.springframework.stereotype.Component;

/**
 * Holds the state of the single in-flight DLQ replay run (#125).
 * <p>
 * A DLQ replay is <em>selective</em>: an operator triggers it with an explicit set of
 * {@code eventId}s (per the event replay strategy, "replay targets specific failed events by
 * {@code eventId}"). This session is the shared handoff between {@code DlqReplayService} (which
 * records the selection when a replay is triggered) and
 * {@code com.pulsestream.processor.consumer.DeadLetterEventConsumer} (which republishes only the
 * selected records and skips everything else). It also holds the inclusive/exclusive partition
 * ranges captured at trigger time, ensuring records appended during replay cannot extend the run.
 * When no replay is active the selection is empty, so the listener republishes nothing even if it
 * happens to be running.
 */
@Component
public class DlqReplaySession {

    private final AtomicReference<Set<String>> selectedEventIds = new AtomicReference<>(Set.of());

    private final AtomicReference<Map<TopicPartition, DlqReplayPartitionRange>> partitionRanges =
            new AtomicReference<>(Map.of());

    private final ConcurrentMap<TopicPartition, Long> scannedOffsets = new ConcurrentHashMap<>();

    private final AtomicBoolean completionClaimed = new AtomicBoolean();

    /**
     * Records the selection and trigger-time partition ranges for a new replay run.
     *
     * @param eventIds the {@code eventId}s the operator asked to replay; copied defensively
     * @param ranges the inclusive/exclusive offset ranges present when the replay was triggered
     */
    public void begin(
            Set<String> eventIds,
            Map<TopicPartition, DlqReplayPartitionRange> ranges
    ) {
        Map<TopicPartition, DlqReplayPartitionRange> immutableRanges = Map.copyOf(ranges);
        scannedOffsets.clear();
        immutableRanges.forEach((partition, range) ->
                scannedOffsets.put(partition, range.startOffset()));
        partitionRanges.set(immutableRanges);
        completionClaimed.set(false);
        selectedEventIds.set(Set.copyOf(eventIds));
    }

    /**
     * Clears the selection and offset boundary once a replay run finishes, stops, or fails.
     */
    public void clear() {
        selectedEventIds.set(Set.of());
        partitionRanges.set(Map.of());
        scannedOffsets.clear();
        completionClaimed.set(false);
    }

    /**
     * @return {@code true} while a replay selection is active
     */
    public boolean isActive() {
        return !selectedEventIds.get().isEmpty() && !completionClaimed.get();
    }

    /**
     * @param eventId the {@code eventId} of a dead-letter record read from the DLQ
     * @param partition the record's topic partition
     * @param offset the record's Kafka offset
     * @return {@code true} if this event was selected and was present when this replay started
     */
    public boolean shouldReplay(String eventId, TopicPartition partition, long offset) {
        DlqReplayPartitionRange range = partitionRanges.get().get(partition);
        return isActive()
                && eventId != null
                && selectedEventIds.get().contains(eventId)
                && range != null
                && range.contains(offset);
    }

    /** Records successful handling of one DLQ record, selected or skipped. */
    public void recordProcessed(TopicPartition partition, long offset) {
        DlqReplayPartitionRange range = partitionRanges.get().get(partition);
        if (range == null) {
            return;
        }

        long nextOffset = Math.min(offset + 1, range.endOffset());
        scannedOffsets.merge(partition, nextOffset, Math::max);
    }

    /**
     * Atomically claims completion once every partition has reached its trigger-time end offset.
     * Only the caller that changes the completion state receives {@code true}.
     */
    public boolean claimCompletionIfBoundaryReached() {
        if (!isActive()) {
            return false;
        }

        boolean boundaryReached = partitionRanges.get().entrySet().stream()
                .allMatch(entry -> scannedOffsets.getOrDefault(
                        entry.getKey(),
                        entry.getValue().startOffset()
                ) >= entry.getValue().endOffset());

        return boundaryReached && completionClaimed.compareAndSet(false, true);
    }

    /**
     * @return the {@code eventId}s selected for the current replay run, or an empty set when idle
     */
    public Set<String> selectedEventIds() {
        return selectedEventIds.get();
    }
}
