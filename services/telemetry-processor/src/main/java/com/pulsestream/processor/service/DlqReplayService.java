package com.pulsestream.processor.service;

import java.util.Set;

import com.pulsestream.processor.consumer.DeadLetterEventConsumer;
import com.pulsestream.processor.model.DlqReplayStatus;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.context.event.EventListener;
import org.springframework.kafka.config.KafkaListenerEndpointRegistry;
import org.springframework.kafka.event.ListenerContainerIdleEvent;
import org.springframework.kafka.listener.MessageListenerContainer;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

/**
 * Triggers and reports on DLQ event replay (#125).
 * <p>
 * The DLQ replay listener ({@link DeadLetterEventConsumer#LISTENER_ID}) is registered with
 * {@code autoStartup=false}, so it stays stopped until an operator explicitly asks for a replay of a
 * specific set of {@code eventId}s. Replay is <strong>selective</strong> (only the requested events
 * are republished) and <strong>bounded</strong>:
 * <ul>
 *   <li>{@link #start(Set)} records the selected {@code eventId}s and starts the container, which
 *       re-scans the dead-letter backlog and republishes only the selected events back onto
 *       {@code telemetry.events.raw} (#124).</li>
 *   <li>Once the backlog is drained the container goes idle; {@link #onListenerContainerIdle} stops
 *       it automatically, so the listener does not stay running to sweep up future dead-letter
 *       records (the strategy requires "no automatic retry loop from the DLQ").</li>
 *   <li>{@link #stop()} halts an in-progress replay on demand. The container also stops itself on a
 *       failed republish (no-data-loss policy from #124) so the record is redelivered on the next
 *       start.</li>
 * </ul>
 * {@link #start(Set)} and {@link #stop()} are idempotent — issuing a trigger against a listener that
 * is already in the requested state is a safe no-op — so repeated or concurrent operator requests
 * do not fail.
 */
@Service
public class DlqReplayService {

    private static final Logger log = LoggerFactory.getLogger(DlqReplayService.class);

    private final ObjectProvider<KafkaListenerEndpointRegistry> listenerRegistryProvider;

    private final DlqReplaySession replaySession;

    public DlqReplayService(
            ObjectProvider<KafkaListenerEndpointRegistry> listenerRegistryProvider,
            DlqReplaySession replaySession
    ) {
        this.listenerRegistryProvider = listenerRegistryProvider;
        this.replaySession = replaySession;
    }

    /**
     * Starts a selective DLQ replay for the given {@code eventId}s. Only dead-letter records whose
     * {@code eventId} is in {@code eventIds} are republished; every other record is skipped. No-op if
     * a replay is already running.
     *
     * @param eventIds the {@code eventId}s to replay; must not be empty
     * @return the current observed listener state immediately after issuing the request; container
     *         start is asynchronous, so this may still show the previous state while it transitions
     */
    public DlqReplayStatus start(Set<String> eventIds) {
        Assert.notEmpty(eventIds, "eventIds selection must not be empty");
        MessageListenerContainer container = requireContainer();

        if (container.isRunning()) {
            log.info(
                    "DLQ replay listener '{}' is already running; start request is a no-op",
                    DeadLetterEventConsumer.LISTENER_ID
            );
            return statusOf(container);
        }

        Set<String> selection = Set.copyOf(eventIds);
        replaySession.begin(selection);
        log.info(
                "Starting DLQ replay listener '{}' to replay {} selected event(s)",
                DeadLetterEventConsumer.LISTENER_ID,
                selection.size()
        );
        container.start();

        return statusOf(container);
    }

    /**
     * Stops the DLQ replay listener so it no longer replays dead-letter events and clears the active
     * selection. No-op on the container if the listener is already stopped.
     *
     * @return the current observed listener state immediately after issuing the request; container
     *         stop is asynchronous, so this may still show the previous state while it transitions
     */
    public DlqReplayStatus stop() {
        MessageListenerContainer container = requireContainer();

        if (container.isRunning()) {
            log.info("Stopping DLQ replay listener '{}'", DeadLetterEventConsumer.LISTENER_ID);
            container.stop();
        } else {
            log.info(
                    "DLQ replay listener '{}' is already stopped; stop request is a no-op",
                    DeadLetterEventConsumer.LISTENER_ID
            );
        }

        replaySession.clear();
        return statusOf(container);
    }

    /**
     * Reports whether the DLQ replay listener is currently running and which events it is replaying.
     *
     * @return the current listener state
     */
    public DlqReplayStatus status() {
        return statusOf(requireContainer());
    }

    /**
     * Stops the replay listener once it has drained the current dead-letter backlog. Spring Kafka
     * publishes a {@link ListenerContainerIdleEvent} when the container has had no records for the
     * configured idle interval. Once the consumer has assigned partitions, this means the fixed
     * backlog has been fully scanned. Idle events published before assignment are ignored so a slow
     * consumer-group join cannot be mistaken for a successful drain. This bounds a replay run to the
     * backlog present when it was triggered rather than leaving the listener running to replay future
     * dead-letter records.
     * <p>
     * The idle event is delivered on the consumer thread, so the container is stopped asynchronously
     * (a synchronous {@code stop()} would deadlock waiting for that same thread to finish).
     */
    @EventListener
    public void onListenerContainerIdle(ListenerContainerIdleEvent event) {
        if (!DeadLetterEventConsumer.LISTENER_ID.equals(event.getListenerId())) {
            return;
        }

        if (event.getTopicPartitions() == null || event.getTopicPartitions().isEmpty()) {
            log.debug(
                    "Ignoring idle event for DLQ replay listener '{}' while awaiting partition assignment",
                    DeadLetterEventConsumer.LISTENER_ID
            );
            return;
        }

        MessageListenerContainer container = event.getContainer(MessageListenerContainer.class);
        if (container == null || !container.isRunning()) {
            return;
        }

        log.info(
                "DLQ replay listener '{}' drained the dead-letter backlog; stopping it",
                DeadLetterEventConsumer.LISTENER_ID
        );
        container.stop(replaySession::clear);
    }

    private DlqReplayStatus statusOf(MessageListenerContainer container) {
        return new DlqReplayStatus(
                DeadLetterEventConsumer.LISTENER_ID,
                container.isRunning(),
                replaySession.selectedEventIds()
        );
    }

    private MessageListenerContainer requireContainer() {
        KafkaListenerEndpointRegistry listenerRegistry = listenerRegistryProvider.getIfAvailable();

        if (listenerRegistry == null) {
            throw new IllegalStateException(
                    "Kafka listener registry is not available; DLQ replay cannot be triggered"
            );
        }

        MessageListenerContainer container =
                listenerRegistry.getListenerContainer(DeadLetterEventConsumer.LISTENER_ID);

        if (container == null) {
            throw new IllegalStateException(
                    "DLQ replay listener container '" + DeadLetterEventConsumer.LISTENER_ID
                            + "' is not registered"
            );
        }

        return container;
    }
}
