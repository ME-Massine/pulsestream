-- Partition checkpoints fence stale delivery and serialize state changes across owners.
-- Stream time is a monotonic Kafka-record timestamp watermark, independent of replica clocks.
CREATE TABLE platform.anomaly_partition_state (
    topic VARCHAR(249) NOT NULL,
    partition_id INTEGER NOT NULL,
    last_offset BIGINT NOT NULL DEFAULT -1,
    stream_time BIGINT NOT NULL DEFAULT 0,
    configuration TEXT NOT NULL,
    PRIMARY KEY (topic, partition_id)
);

CREATE TABLE platform.anomaly_reading_state (
    topic VARCHAR(249) NOT NULL,
    partition_id INTEGER NOT NULL,
    tenant_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    metric TEXT NOT NULL,
    unit TEXT NOT NULL,
    value NUMERIC NOT NULL,
    seen_at BIGINT NOT NULL,
    PRIMARY KEY (topic, partition_id, tenant_id, device_id, metric, unit),
    FOREIGN KEY (topic, partition_id) REFERENCES platform.anomaly_partition_state
);
CREATE INDEX idx_anomaly_state_expiry ON platform.anomaly_reading_state (topic, partition_id, seen_at);

-- A bounded decision journal prevents a crash between detection and offset commit
-- from re-evaluating a reading against its own already-advanced baseline.
CREATE TABLE platform.anomaly_decisions (
    topic VARCHAR(249) NOT NULL,
    partition_id INTEGER NOT NULL,
    record_offset BIGINT NOT NULL,
    input_hash TEXT NOT NULL,
    severity VARCHAR(10) NOT NULL,
    reasons JSONB NOT NULL,
    PRIMARY KEY (topic, partition_id, record_offset),
    FOREIGN KEY (topic, partition_id) REFERENCES platform.anomaly_partition_state
);
