package com.pulsestream.query.service;

import com.pulsestream.query.exception.InvalidQueryException;
import java.util.Set;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;

/** Shares device/time/page validation with processed telemetry; exact severity includes legacy labels. */
public record AnomalyQuery(TelemetryQuery telemetry, String severity, String metric) {
    private static final Set<String> PARAMETERS = Set.of("deviceId", "severity", "metric", "from", "to", "page", "size");

    public AnomalyQuery {
        validate("severity", severity, 20);
        validate("metric", metric, 100);
    }

    public static AnomalyQuery parse(MultiValueMap<String, String> parameters) {
        parameters.forEach((name, values) -> {
            if (!PARAMETERS.contains(name) || values.size() != 1) {
                throw new InvalidQueryException("Only deviceId, severity, metric, from, to, page and size are supported, once each.");
            }
        });
        var common = new LinkedMultiValueMap<>(parameters);
        String severity = common.getFirst("severity");
        String metric = common.getFirst("metric");
        common.remove("severity");
        common.remove("metric");
        return new AnomalyQuery(TelemetryQuery.parse(common), severity, metric);
    }

    private static void validate(String name, String value, int maximum) {
        if (value != null && (value.isBlank() || value.length() > maximum)) {
            throw new InvalidQueryException(name + " must contain 1 to " + maximum + " characters and cannot be blank.");
        }
    }
}
