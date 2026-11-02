package com.pulsestream.processor.model;

import java.util.Locale;

/** Canonical spellings only; converting measurement values requires a separate explicit rule. */
public final class TelemetryUnits {
    private TelemetryUnits() { }

    public static String canonical(String unit) {
        if (unit == null) return null;
        return switch (unit.trim().toLowerCase(Locale.ROOT)) {
            case "celsius", "°c" -> "c";
            case "fahrenheit", "°f" -> "f";
            default -> unit.trim().toLowerCase(Locale.ROOT);
        };
    }
}
