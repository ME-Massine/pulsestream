-- Current classification only; historical contradictory rows await explicit replay.
DO $$ DECLARE conflicting_ids TEXT; BEGIN
    IF EXISTS (SELECT 1 FROM platform.processed_telemetry p JOIN platform.anomalies a USING (event_id)
               WHERE p.tenant_id <> a.tenant_id) THEN
        SELECT string_agg(event_id, ', ' ORDER BY event_id) INTO conflicting_ids FROM
            (SELECT p.event_id FROM platform.processed_telemetry p JOIN platform.anomalies a USING (event_id)
             WHERE p.tenant_id <> a.tenant_id ORDER BY p.event_id LIMIT 10) conflicts;
        RAISE EXCEPTION 'Cross-tenant event ownership conflicts (first 10 IDs: %); inspect both projections before upgrading', conflicting_ids;
    END IF;
END $$;
CREATE TABLE platform.event_classifications (
    event_id VARCHAR(50) PRIMARY KEY,
    tenant_id VARCHAR(100) NOT NULL,
    classification TEXT NOT NULL CHECK (classification IN ('NORMAL', 'ANOMALY', 'UNRESOLVED')),
    revision BIGINT NOT NULL,
    result JSONB,
    first_processed_at TIMESTAMPTZ NOT NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((classification = 'UNRESOLVED' AND revision = 0 AND result IS NULL)
        OR (classification <> 'UNRESOLVED' AND revision > 0 AND result IS NOT NULL))
);
INSERT INTO platform.event_classifications (event_id, tenant_id, classification, revision, result, first_processed_at)
SELECT event_id, min(tenant_id), CASE WHEN count(*) > 1 THEN 'UNRESOLVED' ELSE min(classification) END,
    CASE WHEN count(*) > 1 THEN 0 ELSE 1 END,
    CASE WHEN count(*) > 1 THEN NULL ELSE (array_agg(result))[1] END, min(ingested_at)
FROM (
    SELECT event_id, tenant_id, 'NORMAL' AS classification, ingested_at,
        jsonb_build_object('classification', 'NORMAL', 'eventTime', extract(epoch FROM timestamp),
            'payload', jsonb_build_object('deviceId', device_id, 'deviceType', device_type,
                'metric', metric, 'value', value, 'unit', unit, 'location', location)) AS result
    FROM platform.processed_telemetry
    UNION ALL
    SELECT event_id, tenant_id, 'ANOMALY', ingested_at,
        jsonb_build_object('classification', 'ANOMALY', 'eventTime', extract(epoch FROM timestamp),
            'payload', jsonb_build_object('deviceId', device_id, 'deviceType', device_type,
                'metric', metric, 'value', value, 'unit', unit, 'location', location),
            'severity', severity, 'reasons', reasons)
    FROM platform.anomalies
) projections GROUP BY event_id;
ALTER TABLE platform.delivery_outbox DROP CONSTRAINT delivery_outbox_receipt_id_key;
ALTER TABLE platform.delivery_outbox ADD COLUMN message_sequence INTEGER NOT NULL DEFAULT 0 CHECK (message_sequence >= 0);
ALTER TABLE platform.delivery_outbox ADD CONSTRAINT delivery_outbox_receipt_sequence_key UNIQUE (receipt_id, message_sequence);
DROP INDEX platform.delivery_outbox_pending_source_idx;
CREATE INDEX delivery_outbox_pending_key_idx ON platform.delivery_outbox (message_key, id) WHERE delivered_at IS NULL;
CREATE INDEX delivery_outbox_pending_source_idx ON platform.delivery_outbox
    (source_topic, source_partition, source_offset, message_sequence) WHERE delivered_at IS NULL;
