package com.pulsestream.ingestion;

import com.pulsestream.ingestion.dto.TelemetryIngestionRequestDto;
import com.pulsestream.ingestion.dto.TelemetryPayloadDto;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;

import java.math.BigDecimal;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class TelemetryIngestionControllerTests {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    private String baseUrl() {
        return "http://localhost:" + port + "/api/telemetry";
    }

    @Test
    void validPayloadIsAccepted() {
        TelemetryIngestionRequestDto request = new TelemetryIngestionRequestDto(
                "evt-123",
                "tenant-1",
                "reading",
                Instant.now(),
                "sensor-gateway",
                "1.0",
                new TelemetryPayloadDto(
                        "device-1",
                        "thermometer",
                        "temperature",
                        BigDecimal.valueOf(21.5),
                        "C",
                        "lab-1"
                )
        );

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        HttpEntity<TelemetryIngestionRequestDto> entity = new HttpEntity<>(request, headers);

        ResponseEntity<Void> response = restTemplate.postForEntity(baseUrl(), entity, Void.class);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.ACCEPTED);
    }

    @Test
    void missingRequiredFieldProducesBadRequest() {
        // eventId is blank, which violates @NotBlank
        TelemetryIngestionRequestDto invalidRequest = new TelemetryIngestionRequestDto(
                "",
                "tenant-1",
                "reading",
                Instant.now(),
                "sensor-gateway",
                "1.0",
                new TelemetryPayloadDto(
                        "device-1",
                        "thermometer",
                        "temperature",
                        BigDecimal.valueOf(21.5),
                        "C",
                        "lab-1"
                )
        );

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        HttpEntity<TelemetryIngestionRequestDto> entity = new HttpEntity<>(invalidRequest, headers);

        ResponseEntity<String> response = restTemplate.postForEntity(baseUrl(), entity, String.class);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
    }

    @Test
    void nullPayloadProducesBadRequest() {
        // payload is null, which violates @NotNull
        TelemetryIngestionRequestDto invalidRequest = new TelemetryIngestionRequestDto(
                "evt-123",
                "tenant-1",
                "reading",
                Instant.now(),
                "sensor-gateway",
                "1.0",
                null
        );

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        HttpEntity<TelemetryIngestionRequestDto> entity = new HttpEntity<>(invalidRequest, headers);

        ResponseEntity<String> response = restTemplate.postForEntity(baseUrl(), entity, String.class);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
    }
}
