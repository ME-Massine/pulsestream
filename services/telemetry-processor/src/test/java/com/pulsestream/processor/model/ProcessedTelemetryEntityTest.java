package com.pulsestream.processor.model;

import java.math.BigDecimal;
import java.time.Instant;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ProcessedTelemetryEntityTest {

    @Test
    void constructorPopulatesAllFieldsAlignedWithEventSchema() {
        Instant timestamp = Instant.parse("2026-03-15T12:00:00Z");
        Instant ingestedAt = Instant.parse("2026-03-15T12:00:05Z");

        ProcessedTelemetryEntity entity = new ProcessedTelemetryEntity(
                "evt-123",
                "tenant-1",
                "TELEMETRY",
                timestamp,
                "sensor-gateway",
                "device-42",
                "thermostat",
                "temperature",
                new BigDecimal("21.5000"),
                "celsius",
                "warehouse-1",
                ingestedAt
        );

        assertThat(entity.getId()).isNull();
        assertThat(entity.getEventId()).isEqualTo("evt-123");
        assertThat(entity.getTenantId()).isEqualTo("tenant-1");
        assertThat(entity.getEventType()).isEqualTo("TELEMETRY");
        assertThat(entity.getTimestamp()).isEqualTo(timestamp);
        assertThat(entity.getSource()).isEqualTo("sensor-gateway");
        assertThat(entity.getDeviceId()).isEqualTo("device-42");
        assertThat(entity.getDeviceType()).isEqualTo("thermostat");
        assertThat(entity.getMetric()).isEqualTo("temperature");
        assertThat(entity.getValue()).isEqualByComparingTo("21.5000");
        assertThat(entity.getUnit()).isEqualTo("celsius");
        assertThat(entity.getLocation()).isEqualTo("warehouse-1");
        assertThat(entity.getIngestedAt()).isEqualTo(ingestedAt);
    }

    @Test
    void noArgConstructorIsAvailableForJpa() {
        assertThat(ProcessedTelemetryEntity.class.getDeclaredConstructors())
                .anySatisfy(constructor -> assertThat(constructor.getParameterCount()).isZero());
    }
}
