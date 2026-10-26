package com.pulsestream.processor.config;

import java.math.BigDecimal;
import java.time.Duration;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

import static org.assertj.core.api.Assertions.*;

class AnomalyDetectionPropertiesTest {
    private final ApplicationContextRunner context = new ApplicationContextRunner().withUserConfiguration(Configuration.class);

    @Test
    void bindsDefaultsAndExplicitRulesAndBounds() {
        context.run(application -> assertThat(application.getBean(AnomalyDetectionProperties.class))
                .isEqualTo(AnomalyDetectionProperties.defaults()));
        context.withPropertyValues("pulsestream.anomaly.min-temperature=0", "pulsestream.anomaly.max-temperature=212",
                "pulsestream.anomaly.temperature-unit= F ", "pulsestream.anomaly.spike-ratio=0.25",
                "pulsestream.anomaly.state-retention=2h", "pulsestream.anomaly.max-keys-per-partition=20",
                "pulsestream.anomaly.decisions-per-partition=10").run(application -> {
                    assertThat(application).hasNotFailed();
                    assertThat(application.getBean(AnomalyDetectionProperties.class)).isEqualTo(new AnomalyDetectionProperties(
                            BigDecimal.ZERO, new BigDecimal("212"), "f", new BigDecimal("0.25"), Duration.ofHours(2), 20, 10));
                });
    }

    @ParameterizedTest
    @ValueSource(strings = {"min-temperature=80", "max-temperature=-40", "temperature-unit= ", "spike-ratio=-0.1",
            "state-retention=0s", "state-retention=-1s", "max-keys-per-partition=0", "decisions-per-partition=0"})
    void invalidRulesAndBoundsPreventStartup(String property) {
        context.withPropertyValues("pulsestream.anomaly." + property).run(application -> assertThat(application).hasFailed());
    }

    @EnableConfigurationProperties(AnomalyDetectionProperties.class)
    static class Configuration { }
}
