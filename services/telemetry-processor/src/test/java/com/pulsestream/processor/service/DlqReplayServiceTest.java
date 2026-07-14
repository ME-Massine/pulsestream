package com.pulsestream.processor.service;

import com.pulsestream.processor.consumer.DeadLetterEventConsumer;
import com.pulsestream.processor.model.DlqReplayStatus;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.kafka.config.KafkaListenerEndpointRegistry;
import org.springframework.kafka.listener.MessageListenerContainer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
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

    private DlqReplayService service;

    @BeforeEach
    void setUp() {
        service = new DlqReplayService(listenerRegistryProvider);
    }

    @Test
    @DisplayName("start() should start the replay listener when it is stopped")
    void startShouldStartStoppedListener() {
        givenRegisteredContainer();
        when(container.isRunning()).thenReturn(false, true);

        DlqReplayStatus status = service.start();

        verify(container).start();
        assertThat(status.listenerId()).isEqualTo(DeadLetterEventConsumer.LISTENER_ID);
        assertThat(status.running()).isTrue();
    }

    @Test
    @DisplayName("start() should be a no-op when the replay listener is already running")
    void startShouldBeNoOpWhenAlreadyRunning() {
        givenRegisteredContainer();
        when(container.isRunning()).thenReturn(true);

        DlqReplayStatus status = service.start();

        verify(container, never()).start();
        assertThat(status.running()).isTrue();
    }

    @Test
    @DisplayName("stop() should stop the replay listener when it is running")
    void stopShouldStopRunningListener() {
        givenRegisteredContainer();
        when(container.isRunning()).thenReturn(true, false);

        DlqReplayStatus status = service.stop();

        verify(container).stop();
        assertThat(status.listenerId()).isEqualTo(DeadLetterEventConsumer.LISTENER_ID);
        assertThat(status.running()).isFalse();
    }

    @Test
    @DisplayName("stop() should be a no-op when the replay listener is already stopped")
    void stopShouldBeNoOpWhenAlreadyStopped() {
        givenRegisteredContainer();
        when(container.isRunning()).thenReturn(false);

        DlqReplayStatus status = service.stop();

        verify(container, never()).stop();
        assertThat(status.running()).isFalse();
    }

    @Test
    @DisplayName("status() should report the current running state without touching the listener")
    void statusShouldReportRunningState() {
        givenRegisteredContainer();
        when(container.isRunning()).thenReturn(true);

        DlqReplayStatus status = service.status();

        verify(container, never()).start();
        verify(container, never()).stop();
        assertThat(status.listenerId()).isEqualTo(DeadLetterEventConsumer.LISTENER_ID);
        assertThat(status.running()).isTrue();
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

        assertThatThrownBy(() -> service.start())
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("Kafka listener registry is not available");
    }

    private void givenRegisteredContainer() {
        when(listenerRegistryProvider.getIfAvailable()).thenReturn(listenerRegistry);
        when(listenerRegistry.getListenerContainer(DeadLetterEventConsumer.LISTENER_ID))
                .thenReturn(container);
    }
}
