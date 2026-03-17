# Cache Strategy

## Overview

PulseStream uses Redis as a lightweight in-memory data store for local development and future platform capabilities.

At the current stage of the project, Redis is provisioned as part of the local platform environment but is not yet heavily used by application services.

---

## Intended Use Cases

Redis may be used for:

- caching frequently requested query results
- temporary storage of derived device state
- rate limiting support
- lightweight coordination or ephemeral state if needed

---

## Current Scope

For the MVP infrastructure phase, Redis is introduced to ensure that the local platform environment includes a ready-to-use caching component.

This allows future services to integrate Redis without requiring additional infrastructure changes.

---

## Connection Details

### From inside Docker network

```text
redis:6379
```

### From host machine

```text
localhost:6379
```