package com.pulsestream.processor.consumer;

import com.pulsestream.processor.model.DeadLetterEvent;
import com.pulsestream.processor.service.ReplayEventPublisher;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

/**
 * Reads and deserializes events from the dead-letter topic and republishes the wrapped event to
 * {@code telemetry.events.raw} so it re-enters the pipeline through the existing raw-topic
 * consumer (#124). The {@code eventId} is preserved as-is; no replay metadata is attached yet —
 * that transport is deferred to #126.
 * <p>
 * The listener is registered with {@code autoStartup = "false"} so it stays stopped until an
 * operator explicitly triggers a replay (per the replay strategy in #122 there is no automatic
 * DLQ retry/replay loop). Keeping the container stopped prevents the replay consumer group from
 * advancing past historical DLQ records until an operator opts in. Start it via
 * {@code KafkaListenerEndpointRegistry.getListenerContainer(LISTENER_ID).start()}.
 */
@Service
public class DeadLetterEventConsumer {

    public static final String LISTENER_ID = "dlq-replay-listener";

    private static final Logger log = LoggerFactory.getLogger(DeadLetterEventConsumer.class);

    private final ReplayEventPublisher replayEventPublisher;

    public DeadLetterEventConsumer(ReplayEventPublisher replayEventPublisher) {
        this.replayEventPublisher = replayEventPublisher;
    }

    @KafkaListener(
            id = LISTENER_ID,
            topics = "${pulsestream.kafka.topics.dlq}",
            groupId = "${pulsestream.kafka.consumer.dlq-group-id}",
            containerFactory = "dlqKafkaListenerContainerFactory",
            autoStartup = "false"
    )
    public void consumeDeadLetterEvent(DeadLetterEvent deadLetterEvent) {
        Assert.notNull(deadLetterEvent, "deadLetterEvent must not be null");
        Assert.notNull(deadLetterEvent.event(), "deadLetterEvent.event must not be null");

        log.info(
                "Read DLQ event eventId={} tenantId={} sourceService={} errorMessage={} failedAt={}",
                deadLetterEvent.event().eventId(),
                deadLetterEvent.event().tenantId(),
                deadLetterEvent.sourceService(),
                deadLetterEvent.errorMessage(),
                deadLetterEvent.failedAt()
        );

        replayEventPublisher.publish(deadLetterEvent.event());
    }
}
