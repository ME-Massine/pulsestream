package com.pulsestream.processor.consumer;

import com.pulsestream.processor.model.DeadLetterEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;

/**
 * Reads and deserializes events from the dead-letter topic so they are available for replay.
 * Publishing a replayed event back onto the pipeline is out of scope here and is tracked
 * separately; this consumer only proves the event can be read and parsed.
 */
@Service
public class DeadLetterEventConsumer {

    private static final Logger log = LoggerFactory.getLogger(DeadLetterEventConsumer.class);

    @KafkaListener(
            topics = "${pulsestream.kafka.topics.dlq}",
            groupId = "${pulsestream.kafka.consumer.dlq-group-id}",
            containerFactory = "dlqKafkaListenerContainerFactory"
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
    }
}
