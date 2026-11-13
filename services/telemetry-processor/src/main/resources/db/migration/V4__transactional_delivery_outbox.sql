CREATE TABLE platform.processing_receipts (
    id BIGSERIAL PRIMARY KEY,
    source_topic TEXT NOT NULL,
    source_partition INTEGER NOT NULL,
    source_offset BIGINT NOT NULL,
    input_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source_topic, source_partition, source_offset)
);

CREATE TABLE platform.delivery_outbox (
    id BIGSERIAL PRIMARY KEY,
    receipt_id BIGINT NOT NULL UNIQUE REFERENCES platform.processing_receipts(id),
    destination TEXT NOT NULL,
    message_key TEXT,
    payload TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivered_at TIMESTAMPTZ
);
CREATE INDEX delivery_outbox_pending_idx ON platform.delivery_outbox (receipt_id)
    WHERE delivered_at IS NULL;
