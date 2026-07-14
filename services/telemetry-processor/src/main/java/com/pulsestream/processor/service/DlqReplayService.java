package com.pulsestream.processor.service;

import com.pulsestream.processor.consumer.DeadLetterEventConsumer;
import com.pulsestream.processor.model.DlqReplayStatus;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.kafka.config.KafkaListenerEndpointRegistry;
import org.springframework.kafka.listener.MessageListenerContainer;
import org.springframework.stereotype.Service;

/**
 * Triggers and reports on DLQ event replay (#125).
 * <p>
 * The DLQ replay listener ({@link DeadLetterEventConsumer#LISTENER_ID}) is registered with
 * {@code autoStartup=false}, so it stays stopped until an operator explicitly asks for a replay.
 * Starting the container is the trigger: once running it drains the dead-letter topic backlog and
 * republishes each event back onto {@code telemetry.events.raw} so it re-enters the pipeline
 * (#124). Stopping the container halts replay; the container also stops itself on a failed
 * republish to avoid advancing past an unrecovered record.
 * <p>
 * {@link #start()} and {@link #stop()} are idempotent — issuing a trigger against a listener that
 * is already in the requested state is a safe no-op — so repeated or concurrent operator requests
 * do not fail.
 */
@Service
public class DlqReplayService {

    private static final Logger log = LoggerFactory.getLogger(DlqReplayService.class);

    private final ObjectProvider<KafkaListenerEndpointRegistry> listenerRegistryProvider;

    public DlqReplayService(ObjectProvider<KafkaListenerEndpointRegistry> listenerRegistryProvider) {
        this.listenerRegistryProvider = listenerRegistryProvider;
    }

    /**
     * Starts the DLQ replay listener so it begins replaying dead-letter events. No-op if the
     * listener is already running.
     *
     * @return the listener state after the request
     */
    public DlqReplayStatus start() {
        MessageListenerContainer container = requireContainer();

        if (container.isRunning()) {
            log.info(
                    "DLQ replay listener '{}' is already running; start request is a no-op",
                    DeadLetterEventConsumer.LISTENER_ID
            );
        } else {
            log.info(
                    "Starting DLQ replay listener '{}' to replay dead-letter events",
                    DeadLetterEventConsumer.LISTENER_ID
            );
            container.start();
        }

        return statusOf(container);
    }

    /**
     * Stops the DLQ replay listener so it no longer replays dead-letter events. No-op if the
     * listener is already stopped.
     *
     * @return the listener state after the request
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

        return statusOf(container);
    }

    /**
     * Reports whether the DLQ replay listener is currently running.
     *
     * @return the current listener state
     */
    public DlqReplayStatus status() {
        return statusOf(requireContainer());
    }

    private DlqReplayStatus statusOf(MessageListenerContainer container) {
        return new DlqReplayStatus(DeadLetterEventConsumer.LISTENER_ID, container.isRunning());
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
