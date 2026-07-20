package com.pulsestream.processor.actuator;

import java.util.List;
import java.util.Map;
import java.util.Set;

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
        DlqReplayStatus running = new DlqReplayStatus(DeadLetterEventConsumer.LISTENER_ID, true, Set.of("evt-1"));
        when(dlqReplayService.status()).thenReturn(running);

        assertThat(endpoint.status()).isEqualTo(running);
    }

    @Test
    @DisplayName("'start' action should trigger a replay of the selected events and return 200")
    void controlStartShouldTriggerReplay() {
        Set<String> selection = Set.of("evt-1", "evt-2");
        DlqReplayStatus started = new DlqReplayStatus(DeadLetterEventConsumer.LISTENER_ID, true, selection);
        when(dlqReplayService.start(selection)).thenReturn(started);

        WebEndpointResponse<Object> response = endpoint.control("start", List.of("evt-1", "evt-2"));

        verify(dlqReplayService).start(selection);
        verify(dlqReplayService, never()).stop();
        assertThat(response.getStatus()).isEqualTo(WebEndpointResponse.STATUS_OK);
        assertThat(response.getBody()).isEqualTo(started);
    }

    @Test
    @DisplayName("'start' without a selection should return 400 without touching the replay listener")
    void controlStartWithoutSelectionShouldReturnBadRequest() {
        WebEndpointResponse<Object> emptyResponse = endpoint.control("start", List.of());
        WebEndpointResponse<Object> nullResponse = endpoint.control("start", null);

        assertThat(emptyResponse.getStatus()).isEqualTo(WebEndpointResponse.STATUS_BAD_REQUEST);
        assertThat(nullResponse.getStatus()).isEqualTo(WebEndpointResponse.STATUS_BAD_REQUEST);
        assertThat(emptyResponse.getBody())
                .isEqualTo(Map.of("error", "eventIds selection must not be empty"));
        assertThat(nullResponse.getBody())
                .isEqualTo(Map.of("error", "eventIds selection must not be empty"));
        verifyNoInteractions(dlqReplayService);
    }

    @Test
    @DisplayName("'stop' action should stop the replay and return 200")
    void controlStopShouldStopReplay() {
        DlqReplayStatus stopped = new DlqReplayStatus(DeadLetterEventConsumer.LISTENER_ID, false, Set.of());
        when(dlqReplayService.stop()).thenReturn(stopped);

        WebEndpointResponse<Object> response = endpoint.control("stop", null);

        verify(dlqReplayService).stop();
        verify(dlqReplayService, never()).start(org.mockito.ArgumentMatchers.anySet());
        assertThat(response.getStatus()).isEqualTo(WebEndpointResponse.STATUS_OK);
        assertThat(response.getBody()).isEqualTo(stopped);
    }

    @Test
    @DisplayName("action matching should be case-insensitive")
    void controlShouldBeCaseInsensitive() {
        DlqReplayStatus started = new DlqReplayStatus(DeadLetterEventConsumer.LISTENER_ID, true, Set.of("evt-1"));
        when(dlqReplayService.start(Set.of("evt-1"))).thenReturn(started);

        WebEndpointResponse<Object> response = endpoint.control("START", List.of("evt-1"));

        verify(dlqReplayService).start(Set.of("evt-1"));
        assertThat(response.getStatus()).isEqualTo(WebEndpointResponse.STATUS_OK);
    }

    @Test
    @DisplayName("an unknown action should return 400 without touching the replay listener")
    void controlUnknownActionShouldReturnBadRequest() {
        WebEndpointResponse<Object> response = endpoint.control("resume", List.of("evt-1"));

        assertThat(response.getStatus()).isEqualTo(WebEndpointResponse.STATUS_BAD_REQUEST);
        assertThat(response.getBody()).isEqualTo(Map.of(
                "error", "Unknown action",
                "allowed", List.of("start", "stop")
        ));
        verifyNoInteractions(dlqReplayService);
    }

    @Test
    @DisplayName("a null action should return 400 without touching the replay listener")
    void controlNullActionShouldReturnBadRequest() {
        WebEndpointResponse<Object> response = endpoint.control(null, List.of("evt-1"));

        assertThat(response.getStatus()).isEqualTo(WebEndpointResponse.STATUS_BAD_REQUEST);
        assertThat(response.getBody()).isEqualTo(Map.of(
                "error", "Unknown action",
                "allowed", List.of("start", "stop")
        ));
        verifyNoInteractions(dlqReplayService);
    }
}
