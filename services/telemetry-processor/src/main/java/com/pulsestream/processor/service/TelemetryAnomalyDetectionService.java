package com.pulsestream.processor.service;

import com.pulsestream.processor.model.AnomalySeverity;
import com.pulsestream.processor.model.NormalizedTelemetryEvent;
import com.pulsestream.processor.model.TelemetryAnomalyResult;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;
import org.springframework.util.StringUtils;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;

@Service
public class TelemetryAnomalyDetectionService {

    private static final BigDecimal MAX_TEMPERATURE = new BigDecimal("80");
    private static final BigDecimal MIN_TEMPERATURE = new BigDecimal("-40");

    public TelemetryAnomalyResult detect(NormalizedTelemetryEvent event) {
        Assert.notNull(event, "normalized telemetry event must not be null");

        List<String> reasons = new ArrayList<>();

        if (!StringUtils.hasText(event.tenantId())) {
            reasons.add("tenantId is required");
        }

        if (!StringUtils.hasText(event.deviceId())) {
            reasons.add("deviceId is required");
        }

        if (!StringUtils.hasText(event.metric())) {
            reasons.add("metric is required");
        }

        if (event.value() == null) {
            reasons.add("value is required");
        }

        if (event.value() != null && "temperature".equals(event.metric())) {
            if (event.value().compareTo(MAX_TEMPERATURE) > 0) {
                reasons.add("temperature is above maximum threshold");
            }

            if (event.value().compareTo(MIN_TEMPERATURE) < 0) {
                reasons.add("temperature is below minimum threshold");
            }
        }

        if (reasons.isEmpty()) {
            return TelemetryAnomalyResult.normal(event);
        }

        return TelemetryAnomalyResult.anomalous(
                event,
                resolveSeverity(reasons),
                reasons
        );
    }

    private AnomalySeverity resolveSeverity(List<String> reasons) {
        boolean hasMissingCriticalField = reasons.stream()
                .anyMatch(reason ->
                        reason.contains("tenantId")
                                || reason.contains("deviceId")
                                || reason.contains("metric")
                                || reason.contains("value")
                );

        if (hasMissingCriticalField) {
            return AnomalySeverity.CRITICAL;
        }

        return AnomalySeverity.WARNING;
    }
}