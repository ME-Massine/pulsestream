package com.pulsestream.processor.service;

/**
 * Inclusive/exclusive Kafka offset range captured for one DLQ partition when a replay starts.
 *
 * @param startOffset inclusive beginning offset available at trigger time
 * @param endOffset exclusive end offset present at trigger time
 */
public record DlqReplayPartitionRange(long startOffset, long endOffset) {

    public DlqReplayPartitionRange {
        if (startOffset < 0) {
            throw new IllegalArgumentException("startOffset must not be negative");
        }
        if (endOffset < startOffset) {
            throw new IllegalArgumentException("endOffset must not be less than startOffset");
        }
    }

    public boolean contains(long offset) {
        return offset >= startOffset && offset < endOffset;
    }
}
