-- Preserve V1/legacy rows and their threshold/type metadata. Detection can report
-- missing values/device/metric; no numeric threshold exists for every rule.
ALTER TABLE platform.anomalies
    ALTER COLUMN threshold DROP NOT NULL,
    ALTER COLUMN value DROP NOT NULL,
    ALTER COLUMN device_id DROP NOT NULL,
    ALTER COLUMN metric DROP NOT NULL,
    ADD COLUMN device_type VARCHAR(100),
    ADD COLUMN unit VARCHAR(20),
    ADD COLUMN location VARCHAR(100),
    ADD COLUMN reasons JSONB NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN detected_at TIMESTAMPTZ;

UPDATE platform.anomalies SET detected_at = ingested_at;
ALTER TABLE platform.anomalies
    ALTER COLUMN detected_at SET DEFAULT NOW(),
    ALTER COLUMN detected_at SET NOT NULL,
    ADD CONSTRAINT anomalies_reasons_array CHECK (jsonb_typeof(reasons) = 'array');

CREATE INDEX idx_anomalies_tenant_time ON platform.anomalies (tenant_id, timestamp DESC, id DESC);
