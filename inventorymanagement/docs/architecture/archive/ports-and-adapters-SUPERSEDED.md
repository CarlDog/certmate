# ⚠️ SUPERSEDED DOCUMENT - PORTS AND ADAPTERS SPECIFICATION (Historical)

**Original Date:** November 19, 2025
**Archived:** November 20, 2025
**Superseded By:** `architectural-decisions.md` (ADR-002, ADR-003, ADR-006, ADR-007) and evolving implementation details.

This document described planned port/interface inventory before final ADR consolidation. Current authoritative sources for port definitions are Domain interfaces actually implemented plus ADR rationale. Future evolution will be captured directly through code and ADR revisions.

Rationale for Archival:

- Avoid dual maintenance with ADR-002 and implementation roadmap
- Prevent drift between planned vs actual interface sets
- Reduce documentation surface area; keep only enduring design records

Below is the original content preserved for historical context.

---

## Original Content (Historical)

## Overview

This document catalogs all ports (interfaces) and their corresponding adapters (implementations) in the Inventory Management system.

## Inbound Ports (Driving Adapters)

### ICertificateCollectionCommand

**Location:** `Application.Commands`
**Purpose:** Trigger certificate collection workflow
**Driving Adapter:** `Worker` (Agent)

## Outbound Ports (Driven Adapters)

### ICertificateStoreReader

**Location:** `Domain.Interfaces`
**Contract:**

```csharp
Task<IReadOnlyCollection<Certificate>> GetMachineCertificatesAsync(CancellationToken ct);
```

**Adapters:**

- `WindowsCertStoreReader` - LocalMachine stores (My, WebHosting, CA, Root, AuthRoot)
- `UserProfileCertStoreReader` - HKU user profile stores (optional)
- `RemoteWinRmCertCollector` - Remote machine stores via WinRM (pull-only)

**Responsibilities:**

- Read certificate metadata from Windows certificate stores
- Parse X509Certificate2 properties
- Return normalized certificate entities

---

### IIngestionWriter

**Location:** `Domain.Interfaces`
**Contract:**

```csharp
Task<IngestionOutcome> PersistAsync(IEnumerable<Certificate> certs, Machine machine, CancellationToken ct);
```

**Adapters:**

- `SqlServerPersistence` - SQL Server with parameterized MERGE

**Responsibilities:**

- Upsert canonical certificates to `Certificates` table
- Maintain machine-certificate associations in `MachineCertificates` table
- Return outcome counts (Inserted/Updated/Skipped)

---

### IF5RestClient

**Location:** `Domain.Interfaces`
**Contract:**

```csharp
Task<T> GetAsync<T>(string endpoint, CancellationToken ct);
```

**Adapters:**

- `F5RestClient` - F5 LTM REST API with token auth and rate limiting

**Responsibilities:**

- Authenticate with F5 (token-based)
- BIG-IP 17.1.3 REST API integration
- Rate limiting via Polly (5 req/s, burst=5)
- Retry transient failures

---

### ITeamsNotifier

**Location:** `Domain.Interfaces`
**Contract:**

```csharp
Task SendWeeklyDigestAsync(string message, CancellationToken ct);
```

**Adapters:**

- `TeamsWebhookPublisher` - Teams webhook HTTP POST

**Responsibilities:**

- Format and send weekly certificate expiry digest
- Suppress repeat alerts per certificate after first notification
- Production environment only

---

### IClock

**Location:** `Domain.Interfaces`
**Contract:**

```csharp
DateTimeOffset UtcNow { get; }
```

**Adapters:**

- `SystemClock` (to be implemented) - `DateTimeOffset.UtcNow`
- `TestClock` (for testing) - Controllable time

**Responsibilities:**

- Provide current UTC time
- Testing seam for time-dependent logic

---

## Cross-Cutting Adapters

### PolicyFactory (Polly)

**Location:** `Infrastructure.Retry`
**Responsibilities:**

- Create F5 rate-limiting policy (5 req/s)
- Create WinRM exponential backoff policy
- Create general HTTP retry policy

### SqlLogger

**Location:** `Infrastructure.Logging`
**Responsibilities:**

- Write structured logs to `InventoryLogs` and `collectionLogs` tables
- Complement Serilog file/console logging

## Adapter Configuration

Each adapter receives typed configuration from DI:

| Adapter | Config Class | appsettings Section |
|---------|-------------|---------------------|
| SqlServerPersistence | SqlConfiguration | `Sql` |
| F5RestClient | F5Configuration | `F5` |
| RemoteWinRmCertCollector | WinRmConfiguration | `WinRM` |
| TeamsWebhookPublisher | InventoryConfiguration | `Inventory:WeeklyDigest` |

## Adapter Constraints

### Pull-Only Collection

- **No remote agents** installed on target machines
- WinRM used for OS/IIS remote queries (max 10 concurrent sessions)
- F5 accessed via REST API (BIG-IP 17.1.3, 5 req/s rate limit)
- Repository PFX files accessed via CIFS share

### Concurrency Limits

- WinRM: 10 concurrent sessions (configurable)
- F5: 5 requests/second with burst=5 (Polly token bucket)

### Error Handling

- Partial success retained (no rollback)
- Errors logged with source attribution
- Outcomes classified as Success, Partial, or Failed

---
_End of historical document._
