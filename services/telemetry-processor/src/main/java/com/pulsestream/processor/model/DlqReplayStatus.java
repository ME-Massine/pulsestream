package com.pulsestream.processor.model;

/**
 * State of the DLQ replay listener as reported by the replay trigger (#125).
 *
 * @param listenerId the id of the replay listener container (see
 *                   {@code DeadLetterEventConsumer#LISTENER_ID})
 * @param running    {@code true} while the listener is consuming the dead-letter topic and
 *                   republishing events, {@code false} while it is stopped
 */
public record DlqReplayStatus(String listenerId, boolean running) {
}
