package com.pulsestream.processor.model;

import java.util.Set;

/**
 * State of the DLQ replay listener as reported by the replay trigger (#125).
 *
 * @param listenerId       the id of the replay listener container (see
 *                         {@code DeadLetterEventConsumer#LISTENER_ID})
 * @param running          {@code true} while the listener is consuming the dead-letter topic and
 *                         republishing selected events, {@code false} while it is stopped
 * @param selectedEventIds the {@code eventId}s selected for the current replay run, or an empty set
 *                         when no replay is active
 */
public record DlqReplayStatus(String listenerId, boolean running, Set<String> selectedEventIds) {

    public DlqReplayStatus {
        selectedEventIds = selectedEventIds == null ? Set.of() : Set.copyOf(selectedEventIds);
    }
}
