package com.pulsestream.query.service;

import com.pulsestream.query.exception.InvalidQueryException;
import java.time.Instant;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.util.LinkedMultiValueMap;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class TelemetryQueryTest {
    @Test
    void defaultsAndOffsetTimestamps() {
        var parameters = new LinkedMultiValueMap<String, String>();
        assertThat(TelemetryQuery.parse(parameters)).isEqualTo(new TelemetryQuery(null, null, null, 0, 50));
        parameters.add("from", "2026-01-01T01:00:00+01:00");
        parameters.add("to", "2026-01-02T00:00:00Z");
        parameters.add("deviceId", "sensor-1");
        parameters.add("size", "100");
        parameters.add("page", "10000");
        var query = TelemetryQuery.parse(parameters);
        assertThat(query.from()).isEqualTo(Instant.parse("2026-01-01T00:00:00Z"));
        assertThat(query.deviceId()).isEqualTo("sensor-1");
        assertThat(query.size()).isEqualTo(100);
        assertThat(query.page()).isEqualTo(10000);
    }

    @ParameterizedTest
    @CsvSource(value = {
            "page|-1", "page|10001", "page|2147483648", "page|1.5", "size|0", "size|101",
            "size|abc", "size|''", "deviceId|''", "from|2026-01-01", "to|2026-01-01T00:00:00",
            "from|+10000-01-01T00:00:00Z", "tenantId|another", "sort|tenantId"
    }, delimiter = '|', emptyValue = "")
    void rejectsInvalidParameters(String name, String value) {
        var parameters = new LinkedMultiValueMap<String, String>();
        parameters.add(name, value);
        assertThatThrownBy(() -> TelemetryQuery.parse(parameters)).isInstanceOf(InvalidQueryException.class);
    }

    @Test
    void rejectsRepeatedParametersBlankAndOverlongDeviceAndInvertedRanges() {
        var parameters = new LinkedMultiValueMap<String, String>();
        parameters.add("deviceId", "a");
        parameters.add("deviceId", "b");
        assertThatThrownBy(() -> TelemetryQuery.parse(parameters)).isInstanceOf(InvalidQueryException.class);
        for (String device : new String[] {"   ", "a".repeat(101)}) {
            assertThatThrownBy(() -> new TelemetryQuery(device, null, null, 0, 50))
                    .isInstanceOf(InvalidQueryException.class);
        }
        Instant time = Instant.parse("2026-01-01T00:00:00Z");
        assertThatThrownBy(() -> new TelemetryQuery(null, time, time, 0, 50)).isInstanceOf(InvalidQueryException.class);
        assertThatThrownBy(() -> new TelemetryQuery(null, time.plusSeconds(1), time, 0, 50))
                .isInstanceOf(InvalidQueryException.class);
    }
}
