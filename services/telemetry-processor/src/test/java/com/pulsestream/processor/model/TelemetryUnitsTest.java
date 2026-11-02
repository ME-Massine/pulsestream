package com.pulsestream.processor.model;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class TelemetryUnitsTest {
    @Test
    void canonicalizesEquivalentTemperatureSpellingsWithoutConvertingOtherMeasurements() {
        for (String unit : new String[] {" C ", "Celsius", "°C"}) assertThat(TelemetryUnits.canonical(unit)).isEqualTo("c");
        for (String unit : new String[] {" F ", "Fahrenheit", "°F"}) assertThat(TelemetryUnits.canonical(unit)).isEqualTo("f");
        assertThat(TelemetryUnits.canonical(" KPa ")).isEqualTo("kpa");
        assertThat(TelemetryUnits.canonical(null)).isNull();
        assertThat(TelemetryUnits.canonical(" ")).isEmpty();
    }
}
