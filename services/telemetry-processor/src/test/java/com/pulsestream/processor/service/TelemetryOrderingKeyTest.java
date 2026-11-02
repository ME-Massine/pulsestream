package com.pulsestream.processor.service;

import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;

import static org.assertj.core.api.Assertions.*;

class TelemetryOrderingKeyTest {
    @Test
    void sharedVectorsDefineWhitespaceCaseAndDelimiterSafeKeys() throws Exception {
        try (var stream = getClass().getResourceAsStream("/contracts/ordering-keys.json")) {
            assertThat(stream).isNotNull();
            var vectors = JsonMapper.builder().build().readTree(new String(stream.readAllBytes(), StandardCharsets.UTF_8));
            for (var vector : vectors) {
                assertThat(TelemetryOrderingKey.of(vector.path("tenantId").asText(), vector.path("deviceId").asText()))
                        .isEqualTo(vector.path("key").asText());
            }
        }
        assertThat(TelemetryOrderingKey.of("工場", "温度")).isEqualTo("v1:5bel5aC0:5rip5bqm");
        assertThatThrownBy(() -> TelemetryOrderingKey.of(null, "device")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> TelemetryOrderingKey.of("tenant", " ")).isInstanceOf(IllegalArgumentException.class);
    }
}
