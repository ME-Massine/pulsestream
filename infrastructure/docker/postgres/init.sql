-- PulseStream Database Initialization Script
-- This script creates the platform schema and initial tables for processed events.

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

-- 4. Initial seed data (optional, but useful for testing)
-- Could add some sample data if needed.
