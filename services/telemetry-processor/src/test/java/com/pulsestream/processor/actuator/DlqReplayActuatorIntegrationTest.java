package com.pulsestream.processor.actuator;

import java.util.Map;
import java.util.Set;

import com.pulsestream.processor.consumer.DeadLetterEventConsumer;
import com.pulsestream.processor.model.DlqReplayStatus;
import com.pulsestream.processor.service.DlqReplayService;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.test.context.ActiveProfiles;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anySet;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Verifies over real HTTP that the {@code dlqreplay} actuator endpoint is exposed on the management
 * interface and that its read/write operations are mapped to the expected routes (#125). The
 * underlying {@link DlqReplayService} is mocked so no Kafka broker is required — this test is about
 * the actuator web mapping, not the replay mechanics.
 */
@ActiveProfiles("test")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class DlqReplayActuatorIntegrationTest {

    @Value("${local.management.port}")
    private int managementPort;

    @Autowired
    private TestRestTemplate restTemplate;

    @MockBean
    private DlqReplayService dlqReplayService;

    private String url(String path) {
        return "http://localhost:" + managementPort + "/actuator/dlqreplay" + path;
    }

    @Test
    @DisplayName("GET /actuator/dlqreplay should be mapped to the read operation")
    void statusRouteIsMapped() {
        when(dlqReplayService.status())
                .thenReturn(new DlqReplayStatus(DeadLetterEventConsumer.LISTENER_ID, false, Set.of()));

        ResponseEntity<String> response = restTemplate.getForEntity(url(""), String.class);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).contains("\"running\":false");
        verify(dlqReplayService).status();
    }

    @Test
    @DisplayName("POST /actuator/dlqreplay/start should trigger a selective replay")
    void startRouteIsMapped() {
        when(dlqReplayService.start(anySet()))
                .thenReturn(new DlqReplayStatus(DeadLetterEventConsumer.LISTENER_ID, true, Set.of("evt-1", "evt-2")));

        // The actuator web adapter reads the JSON body as string values, so the selection is passed
        // as a comma-delimited string rather than a JSON array.
        ResponseEntity<String> response = restTemplate.exchange(
                url("/start"),
                HttpMethod.POST,
                jsonEntity(Map.of("eventIds", "evt-1,evt-2")),
                String.class
        );

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);

        @SuppressWarnings("unchecked")
        ArgumentCaptor<Set<String>> selection = ArgumentCaptor.forClass(Set.class);
        verify(dlqReplayService).start(selection.capture());
        assertThat(selection.getValue()).containsExactlyInAnyOrder("evt-1", "evt-2");
    }

    @Test
    @DisplayName("POST /actuator/dlqreplay/start without a selection should return 400")
    void startWithoutSelectionIsRejected() {
        ResponseEntity<String> response = restTemplate.exchange(
                url("/start"),
                HttpMethod.POST,
                jsonEntity(Map.of("eventIds", "")),
                String.class
        );

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
        assertThat(response.getBody()).contains("eventIds selection must not be empty");
    }

    @Test
    @DisplayName("POST /actuator/dlqreplay/stop should be mapped to the stop action")
    void stopRouteIsMapped() {
        when(dlqReplayService.stop())
                .thenReturn(new DlqReplayStatus(DeadLetterEventConsumer.LISTENER_ID, false, Set.of()));

        ResponseEntity<String> response = restTemplate.exchange(
                url("/stop"),
                HttpMethod.POST,
                jsonEntity(Map.of()),
                String.class
        );

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        verify(dlqReplayService).stop();
    }

    private HttpEntity<Object> jsonEntity(Object body) {
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        return new HttpEntity<>(body, headers);
    }
}
