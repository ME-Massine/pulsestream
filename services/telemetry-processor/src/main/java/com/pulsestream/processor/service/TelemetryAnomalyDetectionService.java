package com.pulsestream.processor.service;

import com.pulsestream.processor.model.AnomalySeverity;
import com.pulsestream.processor.model.NormalizedTelemetryEvent;
import com.pulsestream.processor.model.TelemetryAnomalyResult;
import com.pulsestream.processor.config.AnomalyDetectionProperties;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.util.Assert;
import org.springframework.util.StringUtils;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.List;

@Service
public class TelemetryAnomalyDetectionService {

    private final AnomalyDetectionProperties properties;

    public TelemetryAnomalyDetectionService() {
        this(AnomalyDetectionProperties.defaults());
    }

    @Autowired
    public TelemetryAnomalyDetectionService(AnomalyDetectionProperties properties) {
        this.properties = properties;
    }

    public TelemetryAnomalyResult detect(NormalizedTelemetryEvent event) {
        return detect(event, null);
    }

    public TelemetryAnomalyResult detect(NormalizedTelemetryEvent event, BigDecimal previous) {
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

        if (!StringUtils.hasText(event.unit())) {
            reasons.add("unit is required");
            hasMissingCriticalField = true;
        } else if ("temperature".equals(event.metric()) && !properties.temperatureUnit().equals(event.unit())) {
            reasons.add("temperature unit must be " + properties.temperatureUnit());
            hasMissingCriticalField = true;
        }

        if (!hasMissingCriticalField) {
            if ("temperature".equals(event.metric())) {
                if (event.value().compareTo(properties.maxTemperature()) > 0) {
                    reasons.add("temperature is above maximum threshold");
                }

                if (event.value().compareTo(properties.minTemperature()) < 0) {
                    reasons.add("temperature is below minimum threshold");
                }
            }

            if (previous != null && previous.compareTo(BigDecimal.ZERO) != 0) {
                BigDecimal difference = event.value().subtract(previous).abs();
                if (difference.compareTo(previous.abs().multiply(properties.spikeRatio())) > 0) {
                    BigDecimal changeRatio = difference.divide(previous.abs(), 10, RoundingMode.HALF_UP);
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
