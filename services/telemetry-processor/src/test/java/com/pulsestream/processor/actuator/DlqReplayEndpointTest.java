package com.pulsestream.processor.actuator;

import com.pulsestream.processor.consumer.DeadLetterEventConsumer;
import com.pulsestream.processor.model.DlqReplayStatus;
import com.pulsestream.processor.service.DlqReplayService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.web.WebEndpointResponse;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class DlqReplayEndpointTest {

    @Mock
    private DlqReplayService dlqReplayService;

    private DlqReplayEndpoint endpoint;

    @BeforeEach
    void setUp() {
        endpoint = new DlqReplayEndpoint(dlqReplayService);
    }

    @Test
    @DisplayName("should be registered as the 'dlqreplay' actuator endpoint")
    void shouldBeRegisteredAsDlqReplayEndpoint() {
        Endpoint endpointAnnotation = DlqReplayEndpoint.class.getAnnotation(Endpoint.class);

        assertThat(endpointAnnotation).isNotNull();
        assertThat(endpointAnnotation.id()).isEqualTo("dlqreplay");
    }

    @Test
    @DisplayName("read operation should report the current replay listener state")
    void statusShouldReportListenerState() {
        DlqReplayStatus running = new DlqReplayStatus(DeadLetterEventConsumer.LISTENER_ID, true);
        when(dlqReplayService.status()).thenReturn(running);

        assertThat(endpoint.status()).isEqualTo(running);
    }

    @Test
    @DisplayName("'start' action should trigger a replay and return 200")
    void controlStartShouldTriggerReplay() {
        DlqReplayStatus started = new DlqReplayStatus(DeadLetterEventConsumer.LISTENER_ID, true);
        when(dlqReplayService.start()).thenReturn(started);

        WebEndpointResponse<DlqReplayStatus> response = endpoint.control("start");

        verify(dlqReplayService).start();
        verify(dlqReplayService, never()).stop();
        assertThat(response.getStatus()).isEqualTo(WebEndpointResponse.STATUS_OK);
        assertThat(response.getBody()).isEqualTo(started);
    }

    @Test
    @DisplayName("'stop' action should stop the replay and return 200")
    void controlStopShouldStopReplay() {
        DlqReplayStatus stopped = new DlqReplayStatus(DeadLetterEventConsumer.LISTENER_ID, false);
        when(dlqReplayService.stop()).thenReturn(stopped);

        WebEndpointResponse<DlqReplayStatus> response = endpoint.control("stop");

        verify(dlqReplayService).stop();
        verify(dlqReplayService, never()).start();
        assertThat(response.getStatus()).isEqualTo(WebEndpointResponse.STATUS_OK);
        assertThat(response.getBody()).isEqualTo(stopped);
    }

    @Test
    @DisplayName("action matching should be case-insensitive")
    void controlShouldBeCaseInsensitive() {
        DlqReplayStatus started = new DlqReplayStatus(DeadLetterEventConsumer.LISTENER_ID, true);
        when(dlqReplayService.start()).thenReturn(started);

        WebEndpointResponse<DlqReplayStatus> response = endpoint.control("START");

        verify(dlqReplayService).start();
        assertThat(response.getStatus()).isEqualTo(WebEndpointResponse.STATUS_OK);
    }

    @Test
    @DisplayName("an unknown action should return 400 without touching the replay listener")
    void controlUnknownActionShouldReturnBadRequest() {
        WebEndpointResponse<DlqReplayStatus> response = endpoint.control("resume");

        assertThat(response.getStatus()).isEqualTo(WebEndpointResponse.STATUS_BAD_REQUEST);
        assertThat(response.getBody()).isNull();
        verifyNoInteractions(dlqReplayService);
    }

    @Test
    @DisplayName("a null action should return 400 without touching the replay listener")
    void controlNullActionShouldReturnBadRequest() {
        WebEndpointResponse<DlqReplayStatus> response = endpoint.control(null);

        assertThat(response.getStatus()).isEqualTo(WebEndpointResponse.STATUS_BAD_REQUEST);
        assertThat(response.getBody()).isNull();
        verifyNoInteractions(dlqReplayService);
    }
}
