# Data Model Design

**Last Updated:** November 20, 2025
**Status:** Approved
**Owner:** Carl R. Yeager

---

## Purpose

This document explains the **design rationale** for the v2.0 database schema. For executable DDL, see `docs/architecture/schema-ddl.sql`. For a concise high-level summary of core tables & invariants, refer to the Data Model Summary section in `architecture-overview.md`.

---

## Design Principles

1. **Canonical Certificate Storage:** Deduplicate certificates by thumbprint; one row per unique cert
2. **Dynamic Machine Discovery:** No pre-provisioning; machines auto-register on first certificate discovery
3. **Surrogate Keys:** Use synthetic primary keys for stability (ADR-007)
4. **Soft Delete:** 90-day grace period to recover from transient scan failures (ADR-004)
5. **JSON for Variable Structure:** Store source-specific metadata (IIS bindings, F5 profiles) as JSON

---

## Entity Relationships

```plaintext
Certificates (1) ──< MachineCertificates >── (M) Machines
     │                      │
     │                      └──> BindingContext (JSON)
     │
     └─> SANs (JSON), KeyUsages (JSON)

HarvestExecutions (1) ──< InventoryLogs >── (M) Log Entries
```

**Cardinality:**

- One certificate can appear on many machines (e.g., wildcard cert *.example.com)
- One machine can host many certificates (e.g., web server with 50+ sites)
- MachineCertificates is the many-to-many resolver with additional metadata

---

## Table Design Rationale

### Certificates (Canonical Store)

**Purpose:** Store unique certificates regardless of location/machine

**Key Design Decisions:**

- **Surrogate PK:** `CertificateId INT IDENTITY` (stable internal reference)
- **Natural Key:** `Thumbprint NVARCHAR(64) UNIQUE` (SHA-256 hash, 64 hex chars; also supports SHA-1 40 chars)
- **Computed Columns:** `DaysUntilExpiry`, `ExpiryStatus` (database-calculated for query performance)
- **JSON Arrays:** `SANs`, `KeyUsages`, `EnhancedKeyUsages` (variable-length lists)

**Why Surrogate Key?**

- Thumbprint is 40 characters (slower JOINs than INT)
- SHA-1 collision risk (theoretical but possible; see ADR-007)
- Easier to reference in foreign keys and indexes

**Schema Snippet:**

```sql
CREATE TABLE dbo.Certificates (
    CertificateId       INT             IDENTITY(1,1) PRIMARY KEY,
    Thumbprint          NVARCHAR(64)    NOT NULL UNIQUE,  -- Supports SHA-256 (64) and SHA-1 (40)
    Subject             NVARCHAR(500)   NOT NULL,
    Issuer              NVARCHAR(500)   NOT NULL,
    ValidFrom           DATETIME2       NOT NULL,
    ValidTo             DATETIME2       NOT NULL,
    DaysUntilExpiry     AS DATEDIFF(DAY, GETUTCDATE(), ValidTo) PERSISTED,
    -- ... additional columns
);
```

---

### Machines (Dynamic Inventory)

**Purpose:** Track Windows servers and their lifecycle

**Key Design Decisions:**

- **Auto-Discovery:** No manual provisioning; first cert harvest creates machine row
- **Hostname as Natural Key:** Unique constraint on `Hostname` ensures one row per machine
- **FQDN Optional:** `FQDN` is nullable; hostname is the stable identifier
- **Environment Enum:** Strict enumeration (`DEV`, `TEST`, `INTG`, `UAT`, `PROD`, `DEMO`, `Unknown`) with CHECK constraint
- **Roles JSON:** Extensible list (e.g., `["WebServer", "DatabaseHost"]`)
- **Physical Active Flag:** `IsActive BIT NOT NULL DEFAULT 1` (manually set or by scheduled job based on LastSeen)

**MERGE Pattern (ADR-006):**

```sql
MERGE INTO Machines AS target
USING (SELECT @Hostname AS Hostname, @FQDN AS FQDN, @Environment AS Environment) AS source
ON target.Hostname = source.Hostname
WHEN MATCHED THEN
    UPDATE SET LastSeen = GETUTCDATE(), FQDN = source.FQDN
WHEN NOT MATCHED THEN
    INSERT (Hostname, FQDN, Environment, FirstSeen, LastSeen, IsActive)
    VALUES (source.Hostname, source.FQDN, source.Environment, GETUTCDATE(), GETUTCDATE(), 1)
OUTPUT inserted.MachineId;
```

**Why MERGE?**

- Idempotent (safe to run multiple times)
- Updates `LastSeen` on every harvest (tracks machine liveness)
- Returns `MachineId` for immediate use in `MachineCertificates` binding

---

### MachineCertificates (Many-to-Many with Context)

**Purpose:** Track certificate locations and usage contexts

**Key Design Decisions (ADR-007):**

- **Surrogate PK:** `MachineCertificateId INT IDENTITY` (allows multiple rows for same cert/machine)
- **Unique Constraint:** `(MachineId, Thumbprint, SourceType, PathLocation)` (business key)
- **PathLocation Required:** NOT NULL (e.g., `LocalMachine\My`, `CurrentUser\Root`)
- **BindingContext JSON:** Source-specific metadata (IIS site name, F5 virtual server, etc.)
- **Soft Delete Columns:** `DeletedAt DATETIME2 NULL` (90-day grace period; no DeletedBy/Reason in Phase 1)

**Why PathLocation in Unique Constraint?**

**Problem:** Same certificate can exist in multiple store locations:

- `LocalMachine\My` (personal store)
- `LocalMachine\Root` (trusted root CAs)
- `LocalMachine\CA` (intermediate CAs)

**Solution:** Include `PathLocation` in unique constraint:

```sql
CONSTRAINT UQ_MachineCertBinding UNIQUE (MachineId, Thumbprint, SourceType, PathLocation)
```

**Example Data:**

| MachineId | Thumbprint | SourceType | PathLocation | BindingContext |
|-----------|------------|------------|--------------|----------------|
| 42 | ABC123... | OS | LocalMachine\My | `{"HasPrivateKey": true}` |
| 42 | ABC123... | OS | LocalMachine\Root | `{"HasPrivateKey": false}` |
| 42 | ABC123... | IIS | LocalMachine\My | `{"SiteName": "Default Web Site", "IPAddress": "10.0.0.5", "Port": 443}` |

**BindingContext Examples:**

**IIS Binding:**

```json
{
  "SiteName": "Default Web Site",
  "BindingInformation": "10.0.0.5:443:",
  "Protocol": "https",
  "IPAddress": "10.0.0.5",
  "Port": 443,
  "HostHeader": ""
}
```

**F5 Virtual Server:**

```json
{
  "VirtualServer": "/Common/vs_prod_web_443",
  "SSLProfile": "/Common/clientssl_prod",
  "Partition": "Common",
  "Destination": "10.1.1.100:443"
}
```

---

### HarvestExecutions (Run Tracking)

**Purpose:** Audit trail for collection runs

**Key Columns:**

- `HarvestExecutionId`: Unique run identifier
- `SourceType`: Which collector ran (OS, IIS, F5, Repository)
- `StartTime`, `EndTime`: Duration tracking
- `RecordCount`: Certificates/machines discovered
- `ErrorCount`: Failures during harvest

**Usage:**

- Correlation ID for log entries (Serilog includes `HarvestExecutionId` in all logs during run)
- Performance metrics (average duration, success rate)
- Alerting trigger (if `ErrorCount > threshold`, send Teams notification)

---

### InventoryLogs (Structured Logging)

**Purpose:** Centralized logging table (Serilog sink)

**Key Columns:**

- `Timestamp`: Log entry time (UTC)
- `Level`: Debug, Info, Warning, Error, Fatal
- `Message`: Human-readable message
- `Exception`: Stack trace (if error)
- `Properties`: JSON blob with structured data (e.g., `{"MachineId": 42, "Thumbprint": "ABC123..."}`)

**Query Example:**

```sql
-- Find all errors related to machine WEB-01
SELECT Timestamp, Message, Exception
FROM InventoryLogs
WHERE Level = 'Error'
  AND JSON_VALUE(Properties, '$.MachineName') = 'WEB-01'
ORDER BY Timestamp DESC;
```

---

## Data Lifecycle States

### Certificate Lifecycle

1. **Discovered:** First harvest inserts into `Certificates` and `MachineCertificates`
2. **Active:** Subsequent harvests update `LastVerified` timestamp
3. **Soft Deleted:** Certificate not found in scan → `DeletedAt` set (ADR-004)
4. **Recovered:** Certificate reappears → `DeletedAt` cleared (false positive deletion)
5. **Purged (Optional):** After 90-day grace period → move to `MachineCertificates_History` or hard delete

### Machine Lifecycle

1. **First Seen:** MERGE creates row with `FirstSeen = GETUTCDATE()`
2. **Active:** Every harvest updates `LastSeen`
3. **Inactive:** `LastSeen` > 90 days ago → `IsActive = 0` (computed column)
4. **Retired:** Manual flag or archive after prolonged inactivity

---

## Indexing Strategy

### Performance-Critical Indexes

**Certificates:**

```sql
CREATE INDEX IX_Certificates_ValidTo ON Certificates (ValidTo) INCLUDE (Thumbprint, Subject);
-- Use case: Find expiring certificates (WHERE ValidTo < DATEADD(day, 30, GETUTCDATE()))
```

**MachineCertificates:**

```sql
CREATE INDEX IX_MachineCertificates_MachineId ON MachineCertificates (MachineId)
  INCLUDE (Thumbprint, SourceType, LastVerified);
-- Use case: Find all certificates on a specific machine

CREATE INDEX IX_MachineCertificates_DeletedAt ON MachineCertificates (DeletedAt)
  WHERE DeletedAt IS NOT NULL;
-- Use case: Filtered index for soft-deleted records (grace period cleanup)
```

**Machines:**

```sql
CREATE INDEX IX_Machines_LastSeen ON Machines (LastSeen) INCLUDE (Hostname, IsActive);
-- Use case: Find inactive machines (WHERE LastSeen < DATEADD(day, -90, GETUTCDATE()))
```

---

## JSON Querying & Performance

### Query Patterns

**Extract JSON Values:**

```sql
-- Get all IIS sites using a specific certificate
SELECT
    m.FQDN,
    JSON_VALUE(mc.BindingContext, '$.SiteName') AS SiteName,
    JSON_VALUE(mc.BindingContext, '$.Port') AS Port
FROM MachineCertificates mc
JOIN Machines m ON mc.MachineId = m.MachineId
WHERE mc.Thumbprint = 'ABC123...'
  AND mc.SourceType = 'IIS';
```

**Array Expansion:**

```sql
-- Find all SANs for a certificate
SELECT
    c.Thumbprint,
    san.value AS SubjectAlternativeName
FROM Certificates c
CROSS APPLY OPENJSON(c.SANs) AS san
WHERE c.Thumbprint = 'ABC123...';
```

### Performance Considerations

**Computed Columns for Indexing:**

```sql
-- Add computed column for frequently-queried JSON property
ALTER TABLE MachineCertificates
ADD SiteName AS JSON_VALUE(BindingContext, '$.SiteName');

CREATE INDEX IX_MachineCertificates_SiteName ON MachineCertificates (SiteName)
  WHERE SiteName IS NOT NULL;
```

**When to Denormalize:**

- If JSON queries become slow (> 100ms), extract critical fields to dedicated columns
- Example: `IISBindings` table with normalized `SiteName`, `IPAddress`, `Port` columns

---

## Invariants & Constraints

**Business Invariants:** See `domain-architecture.md` for entity validation rules (thumbprint format, FQDN structure, environment values, SAN requirements). This section covers **database-level** constraint enforcement only.

### Database-Enforced Constraints

- `Thumbprint` must be UNIQUE (prevents duplicate certificate rows)
- `Hostname` must be UNIQUE (prevents duplicate machine registrations)
- `Environment` must match CHECK constraint (`DEV`, `TEST`, `INTG`, `UAT`, `PROD`, `DEMO`, `Unknown`)
- `BindingContext` must be valid JSON (`CHECK (ISJSON(BindingContext) = 1)`)
- `PathLocation` must be NOT NULL (required for composite unique constraint on MachineCertificates)
- `DeletedAt` must be NULL or >= `DateDiscovered` (`CHECK (DeletedAt IS NULL OR DeletedAt >= DateDiscovered)`)

**Rationale:** Constraints are enforced at DB layer for data integrity across all access paths (not just application code). Business validation (e.g., thumbprint normalization) occurs in Domain layer before persistence.

---

## Migration from v1.0

### Key Schema Changes

| v1.0 Column | v2.0 Mapping | Rationale |
|-------------|--------------|-----------||
| `certThumbprint` (PK) | `Thumbprint` (UQ), `CertificateId` (PK) | Surrogate key for stability; supports SHA-256 (ADR-007) |
| No machine table | `Machines` table | Dynamic discovery (ADR-006) |
| `machineName` embedded | `MachineCertificates.MachineId` (FK) | Normalized relationship; Hostname is natural key |
| No PathLocation | `PathLocation` in unique constraint | Support multiple store locations (ADR-007) |
| Hard delete | `DeletedAt` soft delete | 90-day grace period (ADR-004) |

### Data Migration Steps

1. **Extract unique certificates:** `INSERT INTO Certificates SELECT DISTINCT certThumbprint, ...`
2. **Create machine inventory:** `INSERT INTO Machines SELECT DISTINCT machineName, ...`
3. **Rebuild bindings:** `INSERT INTO MachineCertificates SELECT MachineId, Thumbprint, ...`
4. **Validate counts:** Ensure no data loss (v1.0 row count = v2.0 MachineCertificates count)

---

## Future Extensions

### Planned Additions

- **CertificateChains Table:** Store issuer hierarchy (root → intermediate → leaf)
- **ComplianceRules Table:** Define policies (e.g., "No SHA-1 certs in Production")
- **AlertSubscriptions Table:** User-specific expiry notifications
- **AuditHistory Table:** Track all schema/data changes with row-level versioning

### Extensibility Points

- **BindingContext JSON:** Add new properties without schema migration
- **Machines.Roles JSON:** Extend with custom tags (e.g., `["PCI-Compliant", "HIPAA"]`)
- **Additional SourceTypes:** `AWS`, `Azure`, `GCP` (just add enum value, no schema change)

---

## Related Documents

- **Executable DDL:** `docs/architecture/schema-ddl.sql`
- **ADRs:** `architectural-decisions.md` (ADR-004, ADR-006, ADR-007)
- **Architecture Overview:** `architecture-overview.md`
