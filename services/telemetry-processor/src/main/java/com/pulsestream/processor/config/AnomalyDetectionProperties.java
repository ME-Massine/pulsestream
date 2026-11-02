package com.pulsestream.processor.config;

import java.math.BigDecimal;
import java.time.Duration;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;
import org.springframework.util.Assert;

@ConfigurationProperties("pulsestream.anomaly")
public record AnomalyDetectionProperties(
        @DefaultValue("-40") BigDecimal minTemperature,
        @DefaultValue("80") BigDecimal maxTemperature,
        @DefaultValue("c") String temperatureUnit,
        @DefaultValue("0.5") BigDecimal spikeRatio,
        @DefaultValue("24h") Duration stateRetention,
        @DefaultValue("10000") int maxKeysPerPartition,
        @DefaultValue("1000") int decisionsPerPartition
) {
    public AnomalyDetectionProperties {
        Assert.isTrue(minTemperature != null && maxTemperature != null
                && minTemperature.compareTo(maxTemperature) < 0, "temperature minimum must be below maximum");
        Assert.hasText(temperatureUnit, "temperature unit must not be blank");
        temperatureUnit = com.pulsestream.processor.model.TelemetryUnits.canonical(temperatureUnit);
        Assert.isTrue(spikeRatio != null && spikeRatio.signum() >= 0, "spike ratio must not be negative");
        Assert.isTrue(stateRetention != null && stateRetention.toMillis() > 0, "state retention must be positive");
        Assert.isTrue(maxKeysPerPartition > 0 && decisionsPerPartition > 0, "state bounds must be positive");
    }

    public static AnomalyDetectionProperties defaults() {
        return new AnomalyDetectionProperties(new BigDecimal("-40"), new BigDecimal("80"), "c",
                new BigDecimal("0.5"), Duration.ofHours(24), 10000, 1000);
    }
}
