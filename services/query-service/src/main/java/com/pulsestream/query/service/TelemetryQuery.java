package com.pulsestream.query.service;

import com.pulsestream.query.exception.InvalidQueryException;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.format.DateTimeParseException;
import java.util.Set;
import org.springframework.util.MultiValueMap;

/** Validated filters shared by the HTTP and repository layers. */
public record TelemetryQuery(String deviceId, Instant from, Instant to, int page, int size) {
    private static final Set<String> PARAMETERS = Set.of("deviceId", "from", "to", "page", "size");
    public static final int MAX_PAGE = 10_000;
    public static final int MAX_SIZE = 100;

    public TelemetryQuery {
        if (deviceId != null && (deviceId.isBlank() || deviceId.length() > 100)) {
            throw new InvalidQueryException("deviceId must contain 1 to 100 characters and cannot be blank.");
        }
        if (page < 0 || page > MAX_PAGE || size < 1 || size > MAX_SIZE) {
            throw new InvalidQueryException("page must be between 0 and 10000; size must be between 1 and 100.");
        }
        if (from != null && to != null && !from.isBefore(to)) {
            throw new InvalidQueryException("from must be earlier than to.");
        }
    }

    public static TelemetryQuery parse(MultiValueMap<String, String> parameters) {
        parameters.forEach((name, values) -> {
            if (!PARAMETERS.contains(name) || values.size() != 1) {
                throw new InvalidQueryException("Only deviceId, from, to, page and size are supported, once each.");
            }
        });
        return new TelemetryQuery(parameters.getFirst("deviceId"), time(parameters.getFirst("from")),
                time(parameters.getFirst("to")), number(parameters.getFirst("page"), 0),
                number(parameters.getFirst("size"), 50));
    }

    private static int number(String value, int defaultValue) {
        if (value == null) {
            return defaultValue;
        }
        try {
            if (!value.matches("[0-9]{1,10}")) {
                throw new NumberFormatException();
            }
            return Integer.parseInt(value);
        } catch (NumberFormatException ex) {
            throw new InvalidQueryException("page and size must be bounded non-negative integers.");
        }
    }

    private static Instant time(String value) {
        if (value == null) {
            return null;
        }
        try {
            OffsetDateTime timestamp = OffsetDateTime.parse(value);
            if (timestamp.getYear() < 1 || timestamp.getYear() > 9999) {
                throw new DateTimeParseException("Timestamp out of range", value, 0);
            }
            return timestamp.toInstant();
        } catch (DateTimeParseException ex) {
            throw new InvalidQueryException("from and to must be ISO-8601 timestamps with an offset, in years 0001 to 9999.");
        }
    }
}
