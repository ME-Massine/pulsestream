package com.pulsestream.processor.service;

import java.util.List;
import java.util.Map;
import java.util.Set;

import com.pulsestream.processor.consumer.DeadLetterEventConsumer;
import com.pulsestream.processor.model.DlqReplayStatus;
import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.common.TopicPartition;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.kafka.config.KafkaListenerEndpointRegistry;
import org.springframework.kafka.event.ListenerContainerIdleEvent;
import org.springframework.kafka.listener.MessageListenerContainer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class DlqReplayServiceTest {

    private static final TopicPartition DLQ_PARTITION =
            new TopicPartition("telemetry.events.dlq", 0);

    @Mock
    private ObjectProvider<KafkaListenerEndpointRegistry> listenerRegistryProvider;

    @Mock
    private KafkaListenerEndpointRegistry listenerRegistry;

    @Mock
    private MessageListenerContainer container;

    @Mock
    private DlqReplayBoundarySnapshotter boundarySnapshotter;

    private DlqReplaySession replaySession;

    private DlqReplayService service;

    @BeforeEach
    void setUp() {
        replaySession = new DlqReplaySession();
        service = new DlqReplayService(listenerRegistryProvider, replaySession, boundarySnapshotter);
    }

    @Test
    @DisplayName("start() should record the selection and start the replay listener when it is stopped")
    void startShouldStartStoppedListener() {
        givenRegisteredContainer();
        when(boundarySnapshotter.snapshot()).thenReturn(replayBoundary(0, 2));
        when(container.isRunning()).thenReturn(false, true);

        DlqReplayStatus status = service.start(Set.of("evt-1", "evt-2"));

        verify(container).start();
        assertThat(status.listenerId()).isEqualTo(DeadLetterEventConsumer.LISTENER_ID);
        assertThat(status.running()).isTrue();
        assertThat(status.selectedEventIds()).containsExactlyInAnyOrder("evt-1", "evt-2");
        assertThat(replaySession.shouldReplay("evt-1", DLQ_PARTITION, 0)).isTrue();
    }

    @Test
    @DisplayName("start() should reject an empty selection without touching the listener")
    void startShouldRejectEmptySelection() {
        assertThatThrownBy(() -> service.start(Set.of()))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("eventIds selection must not be empty");

        assertThat(replaySession.isActive()).isFalse();
    }

    @Test
    @DisplayName("start() should be a no-op when the replay listener is already running")
    void startShouldBeNoOpWhenAlreadyRunning() {
        givenRegisteredContainer();
        when(container.isRunning()).thenReturn(true);

        DlqReplayStatus status = service.start(Set.of("evt-1"));

        verify(container, never()).start();
        assertThat(status.running()).isTrue();
    }

    @Test
    @DisplayName("start() should be a no-op while a previous run's consumer is still stopping")
    void startShouldBeNoOpWhileConsumerIsStillStopping() {
        givenRegisteredContainer();
        when(container.isRunning()).thenReturn(false);
        when(container.isChildRunning()).thenReturn(true);

        service.start(Set.of("evt-2"));

        verify(container, never()).start();
        verify(boundarySnapshotter, never()).snapshot();
        assertThat(replaySession.isActive()).isFalse();
    }

    @Test
    @DisplayName("stop() should stop the replay listener and clear the selection when it is running")
    void stopShouldStopRunningListener() {
        givenRegisteredContainer();
        beginReplay("evt-1");
        when(container.isRunning()).thenReturn(true, false);

        DlqReplayStatus status = service.stop();

        verify(container).stop();
        assertThat(status.listenerId()).isEqualTo(DeadLetterEventConsumer.LISTENER_ID);
        assertThat(status.running()).isFalse();
        assertThat(status.selectedEventIds()).isEmpty();
        assertThat(replaySession.isActive()).isFalse();
    }

    @Test
    @DisplayName("stop() should be a no-op on the container when the replay listener is already stopped")
    void stopShouldBeNoOpWhenAlreadyStopped() {
        givenRegisteredContainer();
        when(container.isRunning()).thenReturn(false);

        DlqReplayStatus status = service.stop();

        verify(container, never()).stop();
        assertThat(status.running()).isFalse();
    }

    @Test
    @DisplayName("status() should report the current running state and selection without touching the listener")
    void statusShouldReportRunningState() {
        givenRegisteredContainer();
        beginReplay("evt-1");
        when(container.isRunning()).thenReturn(true);

        DlqReplayStatus status = service.status();

        verify(container, never()).start();
        verify(container, never()).stop();
        assertThat(status.listenerId()).isEqualTo(DeadLetterEventConsumer.LISTENER_ID);
        assertThat(status.running()).isTrue();
        assertThat(status.selectedEventIds()).containsExactly("evt-1");
    }

    @Test
    @DisplayName("an idle event from the replay child container should stop the parent and clear the selection")
    void idleEventFromReplayChildShouldStopDrainedReplayListener() {
        beginReplay("evt-1");
        replaySession.recordProcessed(DLQ_PARTITION, 0);
        when(container.getListenerId()).thenReturn(DeadLetterEventConsumer.LISTENER_ID);
        when(container.isRunning()).thenReturn(true);
        ListenerContainerIdleEvent event = idleEventFor(
                DeadLetterEventConsumer.LISTENER_ID + "-0",
                container,
                List.of(DLQ_PARTITION)
        );

        service.onListenerContainerIdle(event);

        ArgumentCaptor<Runnable> callback = ArgumentCaptor.forClass(Runnable.class);
        verify(container).stop(callback.capture());
        callback.getValue().run();
        assertThat(replaySession.isActive()).isFalse();
    }

    @Test
    @DisplayName("an idle event before the boundary is reached should stop the stalled replay as a fallback")
    void idleEventBeforeBoundaryReachedShouldStopStalledReplay() {
        beginReplay("evt-1");
        when(container.getListenerId()).thenReturn(DeadLetterEventConsumer.LISTENER_ID);
        when(container.isRunning()).thenReturn(true);
        ListenerContainerIdleEvent event = idleEventFor(
                DeadLetterEventConsumer.LISTENER_ID + "-0",
                container,
                List.of(DLQ_PARTITION)
        );

        service.onListenerContainerIdle(event);

        ArgumentCaptor<Runnable> callback = ArgumentCaptor.forClass(Runnable.class);
        verify(container).stop(callback.capture());
        callback.getValue().run();
        assertThat(replaySession.isActive()).isFalse();
        assertThat(replaySession.selectedEventIds()).isEmpty();
    }

    @Test
    @DisplayName("a late stop callback from a finished run should not clear a newer run's session")
    void staleStopCallbackShouldNotClearNewerRun() {
        givenRegisteredContainer();
        beginReplay("evt-1");
        when(container.isRunning()).thenReturn(true);

        service.onReplayRecordProcessed(DLQ_PARTITION, 0);

        ArgumentCaptor<Runnable> callback = ArgumentCaptor.forClass(Runnable.class);
        verify(container).stop(callback.capture());

        // Operator triggers the next replay before the previous stop callback fires.
        replaySession.begin(Set.of("evt-2"), replayBoundary(0, 3));
        callback.getValue().run();

        assertThat(replaySession.isActive()).isTrue();
        assertThat(replaySession.selectedEventIds()).containsExactly("evt-2");
    }

    @Test
    @DisplayName("an idle event before partition assignment should not stop the replay listener")
    void idleEventBeforePartitionAssignmentShouldBeIgnored() {
        beginReplay("evt-1");
        when(container.getListenerId()).thenReturn(DeadLetterEventConsumer.LISTENER_ID);
        ListenerContainerIdleEvent event = idleEventFor(
                DeadLetterEventConsumer.LISTENER_ID + "-0",
                container,
                List.of()
        );

        service.onListenerContainerIdle(event);

        verify(container, never()).stop(any(Runnable.class));
        assertThat(replaySession.isActive()).isTrue();
    }

    @Test
    @DisplayName("processing the final trigger-time record should stop the replay immediately")
    void finalBoundaryRecordShouldStopReplay() {
        givenRegisteredContainer();
        beginReplay("evt-1");
        when(container.isRunning()).thenReturn(true);

        service.onReplayRecordProcessed(DLQ_PARTITION, 0);

        ArgumentCaptor<Runnable> callback = ArgumentCaptor.forClass(Runnable.class);
        verify(container).stop(callback.capture());
        assertThat(replaySession.isActive()).isFalse();
        callback.getValue().run();
        assertThat(replaySession.selectedEventIds()).isEmpty();
    }

    @Test
    @DisplayName("start should complete without starting the listener when the snapshot is empty")
    void startShouldCompleteImmediatelyForEmptyBoundary() {
        givenRegisteredContainer();
        when(boundarySnapshotter.snapshot()).thenReturn(replayBoundary(5, 5));
        when(container.isRunning()).thenReturn(false);

        DlqReplayStatus status = service.start(Set.of("evt-1"));

        verify(container, never()).start();
        assertThat(status.running()).isFalse();
        assertThat(status.selectedEventIds()).isEmpty();
    }

    @Test
    @DisplayName("an idle event for another listener should be ignored")
    void idleEventForOtherListenerShouldBeIgnored() {
        MessageListenerContainer otherContainer = mock(MessageListenerContainer.class);
        when(otherContainer.getListenerId()).thenReturn("some-other-listener");
        ListenerContainerIdleEvent event = idleEventFor(
                "some-other-listener-0",
                otherContainer,
                List.of(new TopicPartition("some.other.topic", 0))
        );

        service.onListenerContainerIdle(event);

        verify(container, never()).stop(any(Runnable.class));
        verify(otherContainer, never()).stop(any(Runnable.class));
    }

    @Test
    @DisplayName("should fail clearly when the replay listener container is not registered")
    void shouldFailWhenContainerMissing() {
        when(listenerRegistryProvider.getIfAvailable()).thenReturn(listenerRegistry);
        when(listenerRegistry.getListenerContainer(DeadLetterEventConsumer.LISTENER_ID))
                .thenReturn(null);

        assertThatThrownBy(() -> service.status())
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining(DeadLetterEventConsumer.LISTENER_ID);
    }

    @Test
    @DisplayName("should fail clearly when the Kafka listener registry is unavailable")
    void shouldFailWhenRegistryUnavailable() {
        when(listenerRegistryProvider.getIfAvailable()).thenReturn(null);

        assertThatThrownBy(() -> service.start(Set.of("evt-1")))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("Kafka listener registry is not available");
    }

    private ListenerContainerIdleEvent idleEventFor(
            String listenerId,
            MessageListenerContainer container,
            List<TopicPartition> assignedPartitions
    ) {
        return new ListenerContainerIdleEvent(
                new Object(),
                container,
                30_000L,
                listenerId,
                assignedPartitions,
                mock(Consumer.class),
                false
        );
    }

    private void givenRegisteredContainer() {
        when(listenerRegistryProvider.getIfAvailable()).thenReturn(listenerRegistry);
        when(listenerRegistry.getListenerContainer(DeadLetterEventConsumer.LISTENER_ID))
                .thenReturn(container);
    }

    private void beginReplay(String... eventIds) {
        replaySession.begin(Set.of(eventIds), replayBoundary(0, 1));
    }

    private Map<TopicPartition, DlqReplayPartitionRange> replayBoundary(long start, long end) {
        return Map.of(DLQ_PARTITION, new DlqReplayPartitionRange(start, end));
    }
}
