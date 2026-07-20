package com.pulsestream.processor.service;

import java.util.Map;
import java.util.Set;

import com.pulsestream.processor.consumer.DeadLetterEventConsumer;
import com.pulsestream.processor.model.DlqReplayStatus;
import org.apache.kafka.common.TopicPartition;
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
 *   <li>{@link #start(Set)} records the selected {@code eventId}s and snapshots each DLQ
 *       partition's beginning and end offsets before starting the container. The listener re-scans
 *       those ranges and republishes only the selected events to {@code telemetry.events.raw}
 *       (#124).</li>
 *   <li>The listener stops as soon as it reaches every captured end offset. Records appended after
 *       the trigger cannot extend the run, preserving the strategy's "no automatic retry loop from
 *       the DLQ" requirement. {@link #onListenerContainerIdle} is the fallback: it stops the
 *       listener when the boundary is already scanned, and also stops it (with a warning) when the
 *       listener goes idle before reaching the boundary — for example because tail records in the
 *       captured ranges were removed by retention — so a replay can never run forever. Idle events
 *       are published per consumer child, so completion and fallback tracking are partition-aware:
 *       with replay concurrency above one, one idle child does not end the run while a sibling child
 *       is still scanning another partition.</li>
 *   <li>{@link #stop()} halts an in-progress replay on demand. The container also stops itself on a
 *       failed republish (no-data-loss policy from #124) so the record is redelivered on the next
 *       start.</li>
 * </ul>
 * {@link #start(Set)} and {@link #stop()} are serialized and idempotent — issuing a trigger against
 * a listener that is already in the requested state (or still transitioning out of it) is a safe
 * no-op — so repeated or concurrent operator requests do not fail and cannot interleave their
 * snapshot-and-begin steps.
 */
@Service
public class DlqReplayService {

    private static final Logger log = LoggerFactory.getLogger(DlqReplayService.class);

    private final ObjectProvider<KafkaListenerEndpointRegistry> listenerRegistryProvider;

    private final DlqReplaySession replaySession;

    private final DlqReplayBoundarySnapshotter boundarySnapshotter;

    public DlqReplayService(
            ObjectProvider<KafkaListenerEndpointRegistry> listenerRegistryProvider,
            DlqReplaySession replaySession,
            DlqReplayBoundarySnapshotter boundarySnapshotter
    ) {
        this.listenerRegistryProvider = listenerRegistryProvider;
        this.replaySession = replaySession;
        this.boundarySnapshotter = boundarySnapshotter;
    }

    /**
     * Starts a selective DLQ replay for the given {@code eventId}s. Only dead-letter records whose
     * {@code eventId} is in {@code eventIds} are republished; every other record is skipped. No-op if
     * a replay is already running or its consumer is still draining after a stop request.
     *
     * @param eventIds the {@code eventId}s to replay; must not be empty
     * @return the current observed listener state immediately after issuing the request; container
     *         start is asynchronous, so this may still show the previous state while it transitions
     */
    public synchronized DlqReplayStatus start(Set<String> eventIds) {
        Assert.notEmpty(eventIds, "eventIds selection must not be empty");
        MessageListenerContainer container = requireContainer();

        // isRunning() flips false as soon as a stop is requested, but the consumer thread may
        // still be draining records against the previous session. Treat that window as busy too,
        // so a new selection cannot clobber (or be scanned against) a run that has not fully
        // terminated yet.
        if (container.isRunning() || container.isChildRunning()) {
            log.info(
                    "DLQ replay listener '{}' is already running; start request is a no-op",
                    DeadLetterEventConsumer.LISTENER_ID
            );
            return statusOf(container);
        }

        Set<String> selection = Set.copyOf(eventIds);
        Map<TopicPartition, DlqReplayPartitionRange> boundary = boundarySnapshotter.snapshot();
        replaySession.begin(selection, boundary);

        if (replaySession.claimCompletionIfBoundaryReached()) {
            log.info(
                    "DLQ replay listener '{}' has no records in its trigger-time boundary; start request is complete",
                    DeadLetterEventConsumer.LISTENER_ID
            );
            replaySession.clear();
            return statusOf(container);
        }

        log.info(
                "Starting DLQ replay listener '{}' to replay {} selected event(s) across {} bounded partition(s)",
                DeadLetterEventConsumer.LISTENER_ID,
                selection.size(),
                boundary.size()
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
    public synchronized DlqReplayStatus stop() {
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
     * Records successful handling of one record and stops the replay as soon as all trigger-time
     * partition ranges have been scanned. Records appended after the snapshot cannot extend a run.
     */
    public void onReplayRecordProcessed(TopicPartition partition, long offset) {
        replaySession.recordProcessed(partition, offset);
        if (!replaySession.claimCompletionIfBoundaryReached()) {
            return;
        }

        MessageListenerContainer container = requireContainer();
        if (!container.isRunning()) {
            replaySession.clear();
            return;
        }

        stopCompletedReplay(container);
    }

    /**
     * Handles Spring Kafka's idle signal as the fallback stop for a replay run. The replay normally
     * stops immediately after processing the final offset in its trigger-time snapshot; an idle
     * event then simply confirms completion. If the listener goes idle with partitions assigned
     * <em>before</em> reaching the boundary, the tail of a captured range can no longer be
     * delivered (for example after retention cleanup), so the run is stopped with a warning rather
     * than left scanning forever. Events published before partition assignment are ignored, since
     * assignment alone is not proof that the backlog was drained.
     * <p>
     * A {@code ConcurrentMessageListenerContainer} publishes idle events from each child container
     * with only that child's assigned partitions ({@link ListenerContainerIdleEvent#getTopicPartitions()}).
     * The fallback stop is therefore delegated to {@link DlqReplaySession#claimIdleFallbackStop(java.util.Collection)},
     * which stops the run only once every trigger-time partition is drained or idle — so a single
     * idle child cannot cut a concurrent replay short while another partition is still scanning.
     * <p>
     * The idle event is delivered on the consumer thread, so the container is stopped asynchronously
     * (a synchronous {@code stop()} would deadlock waiting for that same thread to finish).
     */
    @EventListener
    public void onListenerContainerIdle(ListenerContainerIdleEvent event) {
        MessageListenerContainer container = event.getContainer(MessageListenerContainer.class);

        // ConcurrentMessageListenerContainer publishes idle events from a child container whose
        // listener id is suffixed (for example, "dlq-replay-listener-0"), even when concurrency is
        // one. Match the registered parent container instead of the child event id so production
        // idle events are not ignored.
        if (container == null
                || !DeadLetterEventConsumer.LISTENER_ID.equals(container.getListenerId())) {
            return;
        }

        if (event.getTopicPartitions() == null || event.getTopicPartitions().isEmpty()) {
            log.debug(
                    "Ignoring idle event for DLQ replay listener '{}' while awaiting partition assignment",
                    DeadLetterEventConsumer.LISTENER_ID
            );
            return;
        }

        if (!container.isRunning()) {
            return;
        }

        if (replaySession.claimCompletionIfBoundaryReached()) {
            stopCompletedReplay(container);
            return;
        }

        if (replaySession.claimIdleFallbackStop(event.getTopicPartitions())) {
            log.warn(
                    "DLQ replay listener '{}' went idle for {} ms with every trigger-time partition"
                            + " either drained or idle before reaching its boundary; stopping it."
                            + " Records at the tail of the captured ranges may no longer exist (for"
                            + " example after retention cleanup) and were not replayed",
                    DeadLetterEventConsumer.LISTENER_ID,
                    event.getIdleTime()
            );
            stopReplayRun(container);
        } else {
            log.debug(
                    "DLQ replay listener '{}' child for partitions {} is idle, but other trigger-time"
                            + " partitions are still scanning; keeping the replay running",
                    DeadLetterEventConsumer.LISTENER_ID,
                    event.getTopicPartitions()
            );
        }
    }

    private void stopCompletedReplay(MessageListenerContainer container) {
        log.info(
                "DLQ replay listener '{}' reached its trigger-time backlog boundary; stopping it",
                DeadLetterEventConsumer.LISTENER_ID
        );
        stopReplayRun(container);
    }

    private void stopReplayRun(MessageListenerContainer container) {
        // The stop completes asynchronously, so scope the cleanup callback to the run it belongs
        // to: a late callback from this run must not wipe the session of a replay that an operator
        // triggers after the container has stopped.
        long runId = replaySession.currentRunId();
        container.stop(() -> replaySession.clearIfRunIs(runId));
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
