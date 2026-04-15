package com.pulsestream.ingestion.controller;

import com.pulsestream.ingestion.exception.GlobalExceptionHandler;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.http.MediaType;
import org.springframework.context.annotation.Import;
import org.springframework.test.web.servlet.MockMvc;

import static org.hamcrest.Matchers.hasItem;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(TelemetryController.class)
@Import(GlobalExceptionHandler.class)
class TelemetryControllerTest {

    private static final String VALID_REQUEST_BODY = """
            {
              "eventId": "evt-1001",
              "tenantId": "factory-01",
              "eventType": "telemetry.reading",
              "timestamp": "2026-03-31T12:00:00Z",
              "source": "sensor-gateway",
              "version": "1.0",
              "payload": {
                "deviceId": "sensor-1042",
                "deviceType": "temperature-sensor",
                "metric": "temperature",
                "value": 28.4,
                "unit": "C",
                "location": "zone-a"
              }
            }
            """;

    @Autowired
    private MockMvc mockMvc;

    @Test
    @DisplayName("should reject invalid telemetry request when required field is missing")
    void shouldRejectInvalidTelemetryRequestWhenEventIdMissing() throws Exception {
        String requestBody = """
            {
              "tenantId": "factory-01",
              "eventType": "telemetry.reading",
              "timestamp": "2026-03-31T12:00:00Z",
              "source": "sensor-gateway",
              "version": "1.0",
              "payload": {
                "deviceId": "sensor-1042",
                "deviceType": "temperature-sensor",
                "metric": "temperature",
                "value": 28.4,
                "unit": "C",
                "location": "zone-a"
              }
            }
            """;

        mockMvc.perform(post("/api/v1/events")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(requestBody))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors[*].field", hasItem("eventId")));
    }

    @Test
    @DisplayName("should reject invalid telemetry request when timestamp format is invalid")
    void shouldRejectInvalidTelemetryRequestWhenTimestampFormatInvalid() throws Exception {
        String requestBody = VALID_REQUEST_BODY.replace(
                "\"timestamp\": \"2026-03-31T12:00:00Z\"",
                "\"timestamp\": \"31-03-2026 12:00:00\"");

        mockMvc.perform(post("/api/v1/events")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(requestBody))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.message").value("Malformed JSON request body or missing required payload."));
    }

    @Test
    @DisplayName("should reject invalid telemetry request when payload structure is empty")
    void shouldRejectInvalidTelemetryRequestWhenPayloadStructureEmpty() throws Exception {
        String requestBody = """
            {
              "eventId": "evt-1001",
              "tenantId": "factory-01",
              "eventType": "telemetry.reading",
              "timestamp": "2026-03-31T12:00:00Z",
              "source": "sensor-gateway",
              "version": "1.0",
              "payload": {}
            }
            """;

        mockMvc.perform(post("/api/v1/events")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(requestBody))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors[*].field", hasItem("payload.deviceId")));
    }

    @Test
    @DisplayName("should reject invalid telemetry request when event metadata is null")
    void shouldRejectInvalidTelemetryRequestWhenEventMetadataNull() throws Exception {
        String requestBody = VALID_REQUEST_BODY.replace(
                "\"source\": \"sensor-gateway\"",
                "\"source\": null");

        mockMvc.perform(post("/api/v1/events")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(requestBody))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors[*].field", hasItem("source")));
    }

    @Test
    @DisplayName("should accept valid telemetry request")
    void shouldAcceptValidTelemetryRequest() throws Exception {
        mockMvc.perform(post("/api/v1/events")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(VALID_REQUEST_BODY))
                .andExpect(status().isAccepted());
    }
}
