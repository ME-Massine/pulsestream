package com.pulsestream.ingestion.controller;

import com.pulsestream.ingestion.mapper.TelemetryEventMapper;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(TelemetryController.class)
class TelemetryControllerTest {

    @MockBean
    private TelemetryEventMapper telemetryEventMapper;

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
                    "deviceId": "",
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
                .andExpect(jsonPath("$.status").value(400))
                .andExpect(jsonPath("$.errors").isArray())
                .andExpect(jsonPath("$.errors[?(@.field=='eventId')]").exists())
                .andExpect(jsonPath("$.errors[?(@.field=='payload.deviceId')]").exists());

        verifyNoInteractions(telemetryEventMapper);
    }

    @Test
    @DisplayName("should accept valid telemetry request and invoke mapper")
    void shouldAcceptValidTelemetryRequestAndInvokeMapper() throws Exception {
        String requestBody = """
        {
          "eventId": "evt-001",
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
                .andExpect(status().isAccepted());

        verify(telemetryEventMapper).toModel(any());
    }
}
