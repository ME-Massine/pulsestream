package com.pulsestream.processor.service;

import java.util.Set;
import java.util.concurrent.atomic.AtomicReference;

import org.springframework.stereotype.Component;

/**
 * Holds the state of the single in-flight DLQ replay run (#125).
 * <p>
 * A DLQ replay is <em>selective</em>: an operator triggers it with an explicit set of
 * {@code eventId}s (per the event replay strategy, "replay targets specific failed events by
 * {@code eventId}"). This session is the shared handoff between {@code DlqReplayService} (which
 * records the selection when a replay is triggered) and
 * {@code com.pulsestream.processor.consumer.DeadLetterEventConsumer} (which republishes only the
 * selected records and skips everything else). When no replay is active the selection is empty, so
 * the listener republishes nothing even if it happens to be running.
 */
@Component
public class DlqReplaySession {

    private final AtomicReference<Set<String>> selectedEventIds = new AtomicReference<>(Set.of());

    /**
     * Records the selection for a new replay run.
     *
     * @param eventIds the {@code eventId}s the operator asked to replay; copied defensively
     */
    public void begin(Set<String> eventIds) {
        selectedEventIds.set(Set.copyOf(eventIds));
    }

    /**
     * Clears the selection once a replay run finishes (drained, stopped, or failed).
     */
    public void clear() {
        selectedEventIds.set(Set.of());
    }

    /**
     * @return {@code true} while a replay selection is active
     */
    public boolean isActive() {
        return !selectedEventIds.get().isEmpty();
    }

    /**
     * @param eventId the {@code eventId} of a dead-letter record read from the DLQ
     * @return {@code true} if this event was selected for the current replay run
     */
    public boolean isSelected(String eventId) {
        return eventId != null && selectedEventIds.get().contains(eventId);
    }

    /**
     * @return the {@code eventId}s selected for the current replay run, or an empty set when idle
     */
    public Set<String> selectedEventIds() {
        return selectedEventIds.get();
    }
}
