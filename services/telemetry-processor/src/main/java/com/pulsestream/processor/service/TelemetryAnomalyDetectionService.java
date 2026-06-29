package com.pulsestream.processor.service;

import com.pulsestream.processor.model.AnomalySeverity;
import com.pulsestream.processor.model.NormalizedTelemetryEvent;
import com.pulsestream.processor.model.TelemetryAnomalyResult;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;
import org.springframework.util.StringUtils;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;

@Service
public class TelemetryAnomalyDetectionService {

    private static final BigDecimal MAX_TEMPERATURE = new BigDecimal("80");
    private static final BigDecimal MIN_TEMPERATURE = new BigDecimal("-40");
    private static final BigDecimal SPIKE_RATIO_THRESHOLD = new BigDecimal("0.5");

    private final ConcurrentHashMap<String, BigDecimal> lastSeenValues = new ConcurrentHashMap<>();

    public TelemetryAnomalyResult detect(NormalizedTelemetryEvent event) {
        Assert.notNull(event, "normalized telemetry event must not be null");

        List<String> reasons = new ArrayList<>();
        boolean hasMissingCriticalField = false;

        if (!StringUtils.hasText(event.tenantId())) {
            reasons.add("tenantId is required");
            hasMissingCriticalField = true;
        }

        if (!StringUtils.hasText(event.deviceId())) {
            reasons.add("deviceId is required");
            hasMissingCriticalField = true;
        }

        if (!StringUtils.hasText(event.metric())) {
            reasons.add("metric is required");
            hasMissingCriticalField = true;
        }

        if (event.value() == null) {
            reasons.add("value is required");
            hasMissingCriticalField = true;
        }

        if (!hasMissingCriticalField) {
            if ("temperature".equals(event.metric())) {
                if (event.value().compareTo(MAX_TEMPERATURE) > 0) {
                    reasons.add("temperature is above maximum threshold");
                }

                if (event.value().compareTo(MIN_TEMPERATURE) < 0) {
                    reasons.add("temperature is below minimum threshold");
                }
            }

            String valueKey = event.tenantId() + ":" + event.deviceId() + ":" + event.metric();
            BigDecimal previous = lastSeenValues.put(valueKey, event.value());

            if (previous != null && previous.compareTo(BigDecimal.ZERO) != 0) {
                BigDecimal changeRatio = event.value().subtract(previous).abs()
                        .divide(previous.abs(), 10, RoundingMode.HALF_UP);
                if (changeRatio.compareTo(SPIKE_RATIO_THRESHOLD) > 0) {
                    BigDecimal pct = changeRatio.multiply(BigDecimal.valueOf(100))
                            .setScale(1, RoundingMode.HALF_UP);
                    reasons.add("value spike detected: changed by " + pct + "% from previous reading");
                }
            }
        }

        if (reasons.isEmpty()) {
            return TelemetryAnomalyResult.normal(event);
        }

        return TelemetryAnomalyResult.anomalous(event, resolveSeverity(hasMissingCriticalField), reasons);
    }

    private AnomalySeverity resolveSeverity(boolean hasMissingCriticalField) {
        return hasMissingCriticalField ? AnomalySeverity.CRITICAL : AnomalySeverity.WARNING;
    }
}