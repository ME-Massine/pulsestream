package com.pulsestream.query.service;

import com.pulsestream.query.exception.InvalidQueryException;
import org.junit.jupiter.api.Test;
import org.springframework.util.LinkedMultiValueMap;

import static org.assertj.core.api.Assertions.*;

class AnomalyQueryTest {
    @Test
    void parsesAnomalyFiltersAndSharesExistingPageTimeAndDeviceValidation() {
        var parameters = new LinkedMultiValueMap<String, String>();
        var defaults = AnomalyQuery.parse(parameters);
        assertThat(defaults).isEqualTo(new AnomalyQuery(new TelemetryQuery(null, null, null, 0, 50), null, null));
        parameters.add("severity", "WARNING");
        parameters.add("metric", "temperature");
        parameters.add("deviceId", "device");
        parameters.add("from", "2026-01-01T00:00:00Z");
        parameters.add("to", "2026-01-02T00:00:00Z");
        parameters.add("size", "100");
        parameters.add("page", "10000");
        var query = AnomalyQuery.parse(parameters);
        assertThat(query.metric()).isEqualTo("temperature");
        assertThat(query.severity()).isEqualTo("WARNING");
        assertThat(query.telemetry().deviceId()).isEqualTo("device");
        assertThat(parameters).containsKey("severity");
    }

    @Test
    void rejectsBlankOverlongRepeatedAndUnknownFilters() {
        for (String name : new String[] {"severity", "metric"}) {
            for (String value : new String[] {"", " ", "x".repeat(name.equals("severity") ? 21 : 101)}) {
                var parameters = new LinkedMultiValueMap<String, String>();
                parameters.add(name, value);
                assertThatThrownBy(() -> AnomalyQuery.parse(parameters)).isInstanceOf(InvalidQueryException.class);
            }
            var repeated = new LinkedMultiValueMap<String, String>();
            repeated.add(name, "a");
            repeated.add(name, "b");
            assertThatThrownBy(() -> AnomalyQuery.parse(repeated)).isInstanceOf(InvalidQueryException.class);
        }
        var parameters = new LinkedMultiValueMap<String, String>();
        parameters.add("tenantId", "another");
        assertThatThrownBy(() -> AnomalyQuery.parse(parameters)).isInstanceOf(InvalidQueryException.class);
    }
}
