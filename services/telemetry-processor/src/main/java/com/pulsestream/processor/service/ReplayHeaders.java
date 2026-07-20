package com.pulsestream.processor.service;

import java.nio.charset.StandardCharsets;

import org.apache.kafka.common.header.Header;
import org.apache.kafka.common.header.Headers;

/**
 * Kafka headers used to mark records produced by the replay path. The headers deliberately stay
 * outside the telemetry envelope so replay control data is not persisted as business telemetry.
 */
public final class ReplayHeaders {

    public static final String REPLAY = "pulsestream.replay";
    public static final String REPLAYED_AT = "pulsestream.replayed-at";
    public static final String REPLAY_SOURCE = "pulsestream.replay-source";

    private ReplayHeaders() {
    }

    /**
     * Returns whether the record was produced by the replay path. Only the literal UTF-8 value
     * {@code true} opts a record into replay safeguards.
     */
    public static boolean isReplay(Headers headers) {
        if (headers == null) {
            return false;
        }

        Header replayHeader = headers.lastHeader(REPLAY);
        return replayHeader != null
                && replayHeader.value() != null
                && Boolean.parseBoolean(new String(replayHeader.value(), StandardCharsets.UTF_8));
    }
}
