package com.pulsestream.processor.consumer;

import java.util.Map;

import com.pulsestream.processor.model.DeadLetterEvent;
import com.pulsestream.processor.service.DlqReplayService;
import com.pulsestream.processor.service.DlqReplaySession;
import com.pulsestream.processor.service.ReplayEventPublisher;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.common.TopicPartition;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.listener.ConsumerSeekAware;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

/**
 * Reads and deserializes events from the dead-letter topic and republishes <em>selected</em> events
 * to {@code telemetry.events.raw} so they re-enter the pipeline through the existing raw-topic
 * consumer (#124). The {@code eventId} is preserved as-is; no replay metadata is attached yet —
 * that transport is deferred to #126.
 * <p>
 * Replay is <strong>selective and bounded</strong>, matching the accepted replay strategy
 * ("replay targets specific failed events by {@code eventId}", "no automatic retry loop from the
 * DLQ"):
 * <ul>
 *   <li><strong>Selective.</strong> Only records whose {@code eventId} is in the operator-supplied
 *       {@link DlqReplaySession} selection are republished; every other dead-letter record read
 *       during the scan is skipped. Future dead-letter records that were not selected are therefore
 *       never automatically replayed.</li>
 *   <li><strong>Repeatable.</strong> On each replay start the listener seeks its partitions to the
 *       beginning (see {@link #onPartitionsAssigned}), so an operator can target any historical
 *       dead-letter event regardless of what a previous run already consumed.</li>
 *   <li><strong>Bounded.</strong> The container is registered with {@code autoStartup = "false"} so
 *       it stays stopped until an operator explicitly triggers a replay. Each trigger captures the
 *       current beginning/end offsets, and the listener stops after scanning those ranges. Records
 *       appended later cannot extend the run.</li>
 * </ul>
 * Start it via {@code DlqReplayService.start(...)}, which records the selection and starts the
 * container.
 */
@Service
public class DeadLetterEventConsumer implements ConsumerSeekAware {

    public static final String LISTENER_ID = "dlq-replay-listener";

    private static final Logger log = LoggerFactory.getLogger(DeadLetterEventConsumer.class);

    private final ReplayEventPublisher replayEventPublisher;

    private final DlqReplaySession replaySession;

    private final DlqReplayService dlqReplayService;

    public DeadLetterEventConsumer(
            ReplayEventPublisher replayEventPublisher,
            DlqReplaySession replaySession,
            DlqReplayService dlqReplayService
    ) {
        this.replayEventPublisher = replayEventPublisher;
        this.replaySession = replaySession;
        this.dlqReplayService = dlqReplayService;
    }

    @KafkaListener(
            id = LISTENER_ID,
            topics = "${pulsestream.kafka.topics.dlq}",
            groupId = "${pulsestream.kafka.consumer.dlq-group-id}",
            containerFactory = "dlqKafkaListenerContainerFactory",
            autoStartup = "false"
    )
    public void consumeDeadLetterEvent(ConsumerRecord<String, DeadLetterEvent> record) {
        Assert.notNull(record, "record must not be null");
        DeadLetterEvent deadLetterEvent = record.value();
        Assert.notNull(deadLetterEvent, "deadLetterEvent must not be null");
        Assert.notNull(deadLetterEvent.event(), "deadLetterEvent.event must not be null");

        String eventId = deadLetterEvent.event().eventId();
        TopicPartition partition = new TopicPartition(record.topic(), record.partition());

        if (!replaySession.shouldReplay(eventId, partition, record.offset())) {
            log.debug(
                    "Skipping DLQ event eventId={} tenantId={} partition={} offset={}: not selected or outside the trigger-time boundary",
                    eventId,
                    deadLetterEvent.event().tenantId(),
                    record.partition(),
                    record.offset()
            );
        } else {
            log.info(
                    "Replaying selected DLQ event eventId={} tenantId={} sourceService={} errorMessage={} failedAt={}",
                    eventId,
                    deadLetterEvent.event().tenantId(),
                    deadLetterEvent.sourceService(),
                    deadLetterEvent.errorMessage(),
                    deadLetterEvent.failedAt()
            );

            replayEventPublisher.publish(deadLetterEvent.event());
        }

        dlqReplayService.onReplayRecordProcessed(partition, record.offset());
    }

    /**
     * Rewinds the assigned partitions to the beginning on each replay start so the run re-scans the
     * trigger-time dead-letter range and can find any selected {@code eventId}, independent of the
     * replay consumer group's previously committed offsets. The captured end offsets bound the scan;
     * non-selected records within it are read and skipped in {@link #consumeDeadLetterEvent}.
     */
    @Override
    public void onPartitionsAssigned(Map<TopicPartition, Long> assignments, ConsumerSeekCallback callback) {
        if (replaySession.isActive() && !assignments.isEmpty()) {
            log.info("Rewinding DLQ replay listener '{}' to the beginning to re-scan the backlog", LISTENER_ID);
            callback.seekToBeginning(assignments.keySet());
        }
    }
}
