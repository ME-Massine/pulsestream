-- Copy immutable receipt coordinates so pending delivery lookup never scans receipt history.
ALTER TABLE platform.delivery_outbox
    ADD COLUMN source_topic TEXT,
    ADD COLUMN source_partition INTEGER,
    ADD COLUMN source_offset BIGINT;

UPDATE platform.delivery_outbox o
SET source_topic = r.source_topic,
    source_partition = r.source_partition,
    source_offset = r.source_offset
FROM platform.processing_receipts r
WHERE r.id = o.receipt_id;

ALTER TABLE platform.delivery_outbox
    ALTER COLUMN source_topic SET NOT NULL,
    ALTER COLUMN source_partition SET NOT NULL,
    ALTER COLUMN source_offset SET NOT NULL;

CREATE INDEX delivery_outbox_pending_source_idx
    ON platform.delivery_outbox (source_topic, source_partition, source_offset)
    WHERE delivered_at IS NULL;
