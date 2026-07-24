package com.pulsestream.processor.actuator;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.test.context.ActiveProfiles;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Verifies the Kubernetes liveness/readiness probe wiring (#137). The Deployment probes target
 * {@code /livez} and {@code /readyz} on the main service port because the full actuator surface —
 * including the state-changing {@code dlqreplay} endpoint — stays on the separate, loopback-bound
 * management port (see application.yml). {@code management.endpoint.health.probes.add-additional-paths}
 * mirrors only the probe groups to the main port so kubelet can reach them over the pod network
 * without exposing the rest of the management interface.
 */
@ActiveProfiles("test")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class HealthProbeEndpointsIntegrationTest {

    // Main service port — where kubelet reaches the probes over the pod network.
    @Value("${local.server.port}")
    private int serverPort;

    // Separate, loopback-bound management port that carries the full actuator surface.
    @Value("${local.management.port}")
    private int managementPort;

    @Autowired
    private TestRestTemplate restTemplate;

    private String mainPort(String path) {
        return "http://localhost:" + serverPort + path;
    }

    @Test
    @DisplayName("liveness probe path /livez is served on the main service port and reports UP")
    void livenessProbeIsServedOnMainPort() {
        ResponseEntity<String> response = restTemplate.getForEntity(mainPort("/livez"), String.class);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).contains("\"status\":\"UP\"");
    }

    @Test
    @DisplayName("readiness probe path /readyz is served on the main service port and reports UP")
    void readinessProbeIsServedOnMainPort() {
        ResponseEntity<String> response = restTemplate.getForEntity(mainPort("/readyz"), String.class);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).contains("\"status\":\"UP\"");
    }

    @Test
    @DisplayName("only the probe groups are exposed on the main port; the rest of actuator stays off it")
    void fullActuatorSurfaceIsNotExposedOnMainPort() {
        // The aggregate health endpoint and the state-changing dlqreplay endpoint remain on the
        // management port only, so probing the main port for them must not succeed.
        assertThat(restTemplate.getForEntity(mainPort("/actuator/health"), String.class).getStatusCode())
                .isEqualTo(HttpStatus.NOT_FOUND);
        assertThat(restTemplate.getForEntity(mainPort("/actuator/dlqreplay"), String.class).getStatusCode())
                .isEqualTo(HttpStatus.NOT_FOUND);
    }

    @Test
    @DisplayName("actuator liveness/readiness groups are reachable on the management port")
    void probeGroupsAreReachableOnManagementPort() {
        String base = "http://localhost:" + managementPort + "/actuator/health/";

        assertThat(restTemplate.getForEntity(base + "liveness", String.class).getStatusCode())
                .isEqualTo(HttpStatus.OK);
        assertThat(restTemplate.getForEntity(base + "readiness", String.class).getStatusCode())
                .isEqualTo(HttpStatus.OK);
    }
}
