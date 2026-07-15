package com.pulsestream.processor.service;

import java.util.List;
import java.util.Set;

import com.pulsestream.processor.consumer.DeadLetterEventConsumer;
import com.pulsestream.processor.model.DlqReplayStatus;
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

    @Mock
    private ObjectProvider<KafkaListenerEndpointRegistry> listenerRegistryProvider;

    @Mock
    private KafkaListenerEndpointRegistry listenerRegistry;

    @Mock
    private MessageListenerContainer container;

    private DlqReplaySession replaySession;

    private DlqReplayService service;

    @BeforeEach
    void setUp() {
        replaySession = new DlqReplaySession();
        service = new DlqReplayService(listenerRegistryProvider, replaySession);
    }

    @Test
    @DisplayName("start() should record the selection and start the replay listener when it is stopped")
    void startShouldStartStoppedListener() {
        givenRegisteredContainer();
        when(container.isRunning()).thenReturn(false, true);

        DlqReplayStatus status = service.start(Set.of("evt-1", "evt-2"));

        verify(container).start();
        assertThat(status.listenerId()).isEqualTo(DeadLetterEventConsumer.LISTENER_ID);
        assertThat(status.running()).isTrue();
        assertThat(status.selectedEventIds()).containsExactlyInAnyOrder("evt-1", "evt-2");
        assertThat(replaySession.isSelected("evt-1")).isTrue();
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
    @DisplayName("stop() should stop the replay listener and clear the selection when it is running")
    void stopShouldStopRunningListener() {
        givenRegisteredContainer();
        replaySession.begin(Set.of("evt-1"));
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
        replaySession.begin(Set.of("evt-1"));
        when(container.isRunning()).thenReturn(true);

        DlqReplayStatus status = service.status();

        verify(container, never()).start();
        verify(container, never()).stop();
        assertThat(status.listenerId()).isEqualTo(DeadLetterEventConsumer.LISTENER_ID);
        assertThat(status.running()).isTrue();
        assertThat(status.selectedEventIds()).containsExactly("evt-1");
    }

    @Test
    @DisplayName("an idle event for the replay listener should stop it and clear the selection once the backlog is drained")
    void idleEventShouldStopDrainedReplayListener() {
        replaySession.begin(Set.of("evt-1"));
        when(container.isRunning()).thenReturn(true);
        ListenerContainerIdleEvent event = idleEventFor(
                DeadLetterEventConsumer.LISTENER_ID,
                container,
                List.of(new TopicPartition("telemetry.events.dlq", 0))
        );

        service.onListenerContainerIdle(event);

        ArgumentCaptor<Runnable> callback = ArgumentCaptor.forClass(Runnable.class);
        verify(container).stop(callback.capture());
        callback.getValue().run();
        assertThat(replaySession.isActive()).isFalse();
    }

    @Test
    @DisplayName("an idle event before partition assignment should not stop the replay listener")
    void idleEventBeforePartitionAssignmentShouldBeIgnored() {
        replaySession.begin(Set.of("evt-1"));
        ListenerContainerIdleEvent event = idleEventFor(
                DeadLetterEventConsumer.LISTENER_ID,
                container,
                List.of()
        );

        service.onListenerContainerIdle(event);

        verify(container, never()).stop(any(Runnable.class));
        assertThat(replaySession.isActive()).isTrue();
    }

    @Test
    @DisplayName("an idle event for another listener should be ignored")
    void idleEventForOtherListenerShouldBeIgnored() {
        ListenerContainerIdleEvent event = idleEventFor("some-other-listener", container, List.of());

        service.onListenerContainerIdle(event);

        verify(container, never()).stop(any(Runnable.class));
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
        ListenerContainerIdleEvent event = mock(ListenerContainerIdleEvent.class);
        when(event.getListenerId()).thenReturn(listenerId);
        if (listenerId.equals(DeadLetterEventConsumer.LISTENER_ID)) {
            when(event.getTopicPartitions()).thenReturn(assignedPartitions);
            if (!assignedPartitions.isEmpty()) {
                when(event.getContainer(MessageListenerContainer.class)).thenReturn(container);
            }
        }
        return event;
    }

    private void givenRegisteredContainer() {
        when(listenerRegistryProvider.getIfAvailable()).thenReturn(listenerRegistry);
        when(listenerRegistry.getListenerContainer(DeadLetterEventConsumer.LISTENER_ID))
                .thenReturn(container);
    }
}
