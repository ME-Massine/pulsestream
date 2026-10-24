-- Initial platform contract, including adoption of tables created by the retired
-- manual init.sql. IF NOT EXISTS preserves existing rows and sequence values;
-- the checks below reject incompatible objects rather than silently adopting them.

-- 1. Create the platform schema
CREATE SCHEMA IF NOT EXISTS platform;

-- 2. Create the processed_telemetry table
-- This table stores enriched and normalized telemetry events.
CREATE TABLE IF NOT EXISTS platform.processed_telemetry (
    id SERIAL PRIMARY KEY,
    event_id VARCHAR(50) NOT NULL UNIQUE,
    tenant_id VARCHAR(100) NOT NULL,
    event_type VARCHAR(50) NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    source VARCHAR(100) NOT NULL,
    device_id VARCHAR(100) NOT NULL,
    device_type VARCHAR(100) NOT NULL,
    metric VARCHAR(100) NOT NULL,
    value NUMERIC(18, 4) NOT NULL,
    unit VARCHAR(20) NOT NULL,
    location VARCHAR(100) NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Optimize queries by tenant, device, and time
CREATE INDEX IF NOT EXISTS idx_telemetry_tenant ON platform.processed_telemetry (tenant_id);
CREATE INDEX IF NOT EXISTS idx_telemetry_device ON platform.processed_telemetry (device_id);
CREATE INDEX IF NOT EXISTS idx_telemetry_timestamp ON platform.processed_telemetry (timestamp DESC);

-- 3. Create the anomalies table
-- This table stores detected anomalies from the telemetry processor.
CREATE TABLE IF NOT EXISTS platform.anomalies (
    id SERIAL PRIMARY KEY,
    event_id VARCHAR(50) NOT NULL UNIQUE,
    tenant_id VARCHAR(100) NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    device_id VARCHAR(100) NOT NULL,
    metric VARCHAR(100) NOT NULL,
    value NUMERIC(18, 4) NOT NULL,
    threshold NUMERIC(18, 4) NOT NULL,
    anomaly_type VARCHAR(50) NOT NULL,
    severity VARCHAR(20) NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Optimize queries by tenant, device, and time for anomalies
CREATE INDEX IF NOT EXISTS idx_anomalies_tenant ON platform.anomalies (tenant_id);
CREATE INDEX IF NOT EXISTS idx_anomalies_device ON platform.anomalies (device_id);
CREATE INDEX IF NOT EXISTS idx_anomalies_timestamp ON platform.anomalies (timestamp DESC);

-- Validate legacy table columns before recording successful adoption. PostgreSQL
-- runs this migration transactionally, including the preceding DDL.
DO $$
DECLARE
    expected RECORD;
    relation REGCLASS;
    attribute SMALLINT;
BEGIN
    FOR expected IN
        SELECT * FROM (VALUES
            ('processed_telemetry', 'id', 'integer'),
            ('processed_telemetry', 'event_id', 'character varying(50)'),
            ('processed_telemetry', 'tenant_id', 'character varying(100)'),
            ('processed_telemetry', 'event_type', 'character varying(50)'),
            ('processed_telemetry', 'timestamp', 'timestamp with time zone'),
            ('processed_telemetry', 'source', 'character varying(100)'),
            ('processed_telemetry', 'device_id', 'character varying(100)'),
            ('processed_telemetry', 'device_type', 'character varying(100)'),
            ('processed_telemetry', 'metric', 'character varying(100)'),
            ('processed_telemetry', 'value', 'numeric(18,4)'),
            ('processed_telemetry', 'unit', 'character varying(20)'),
            ('processed_telemetry', 'location', 'character varying(100)'),
            ('processed_telemetry', 'ingested_at', 'timestamp with time zone'),
            ('anomalies', 'id', 'integer'),
            ('anomalies', 'event_id', 'character varying(50)'),
            ('anomalies', 'tenant_id', 'character varying(100)'),
            ('anomalies', 'timestamp', 'timestamp with time zone'),
            ('anomalies', 'device_id', 'character varying(100)'),
            ('anomalies', 'metric', 'character varying(100)'),
            ('anomalies', 'value', 'numeric(18,4)'),
            ('anomalies', 'threshold', 'numeric(18,4)'),
            ('anomalies', 'anomaly_type', 'character varying(50)'),
            ('anomalies', 'severity', 'character varying(20)'),
            ('anomalies', 'ingested_at', 'timestamp with time zone')
        ) AS columns(table_name, column_name, column_type)
    LOOP
        relation := format('platform.%I', expected.table_name)::regclass;
        IF NOT EXISTS (
            SELECT 1 FROM pg_attribute
            WHERE attrelid = relation AND attname = expected.column_name
                AND NOT attisdropped AND attnotnull
                AND format_type(atttypid, atttypmod) = expected.column_type
        ) THEN
            RAISE EXCEPTION 'Incompatible legacy column: platform.%.%',
                expected.table_name, expected.column_name;
        END IF;
    END LOOP;

    FOREACH relation IN ARRAY ARRAY['platform.processed_telemetry'::regclass, 'platform.anomalies'::regclass]
    LOOP
        SELECT attnum INTO attribute FROM pg_attribute WHERE attrelid = relation AND attname = 'id';
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
            WHERE conrelid = relation AND contype = 'p' AND conkey = ARRAY[attribute]) THEN
            RAISE EXCEPTION 'Missing id primary key: %', relation;
        END IF;
        IF pg_get_serial_sequence(relation::text, 'id') IS NULL THEN
            RAISE EXCEPTION 'Missing id sequence: %', relation;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_attrdef d JOIN pg_attribute a
            ON a.attrelid = d.adrelid AND a.attnum = d.adnum
            WHERE d.adrelid = relation AND a.attname = 'id'
                AND pg_get_expr(d.adbin, d.adrelid) = format('nextval(%L::regclass)',
                    pg_get_serial_sequence(relation::text, 'id'))) THEN
            RAISE EXCEPTION 'Incompatible id sequence default: %', relation;
        END IF;
        SELECT attnum INTO attribute FROM pg_attribute WHERE attrelid = relation AND attname = 'event_id';
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
            WHERE conrelid = relation AND contype = 'u' AND conkey = ARRAY[attribute]) THEN
            RAISE EXCEPTION 'Missing event_id uniqueness: %', relation;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_attrdef d JOIN pg_attribute a
            ON a.attrelid = d.adrelid AND a.attnum = d.adnum
            WHERE d.adrelid = relation AND a.attname = 'ingested_at'
                AND pg_get_expr(d.adbin, d.adrelid) = 'now()') THEN
            RAISE EXCEPTION 'Missing ingested_at default: %', relation;
        END IF;
    END LOOP;

    FOR expected IN
        SELECT * FROM (VALUES
            ('processed_telemetry', 'idx_telemetry_tenant', 'tenant_id', 0),
            ('processed_telemetry', 'idx_telemetry_device', 'device_id', 0),
            ('processed_telemetry', 'idx_telemetry_timestamp', '"timestamp"', 3),
            ('anomalies', 'idx_anomalies_tenant', 'tenant_id', 0),
            ('anomalies', 'idx_anomalies_device', 'device_id', 0),
            ('anomalies', 'idx_anomalies_timestamp', '"timestamp"', 3)
        ) AS indexes(table_name, index_name, index_column, index_options)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_index i
            WHERE i.indexrelid = to_regclass(format('platform.%I', expected.index_name))
                AND i.indrelid = to_regclass(format('platform.%I', expected.table_name))
                AND i.indisvalid AND i.indpred IS NULL AND i.indnatts = 1
                AND i.indoption[0] = expected.index_options
                AND pg_get_indexdef(i.indexrelid, 1, false) = expected.index_column) THEN
            RAISE EXCEPTION 'Incompatible legacy index: platform.%', expected.index_name;
        END IF;
    END LOOP;
END $$;
