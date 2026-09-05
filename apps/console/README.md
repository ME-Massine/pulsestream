# PulseStream Operations Console

The operations console turns PulseStream telemetry into an anomaly-first workflow. It combines a compact end-to-end pipeline pulse, a chronological incident ledger, signal evidence, event metadata, recent readings, and event-stage history on one screen.

## Run locally

```bash
npm install
npm run dev
```

The interface currently uses realistic in-memory data because the repository's query service does not yet expose telemetry or anomaly APIs. The UI keeps that boundary explicit so a later API adapter can replace the fixture layer without changing the interaction model.

## Quality checks

```bash
npm run build
npm run test:sites
```

The frontend is responsive across desktop, tablet, and mobile widths. The primary workflow supports anomaly selection, severity filtering, acknowledgement, and opening an investigation.
