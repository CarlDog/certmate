# Phase 1 Stage 1: Foundation (Weeks 1-1.5)

**Last Updated:** November 20, 2025
**Status:** Ready for Implementation
**Owner:** Carl R. Yeager
**Duration:** ~1.5 weeks

---

## Overview

Establish the foundational architecture, domain model, and SQL schema for the Certificate Inventory Management System. This stage focuses on creating the core structure without implementing harvest logic.

**Primary Goal:** Build a clean hexagonal architecture foundation with validated domain models and deployed SQL schema.

---

## Scope

**In Scope:**
- Domain model entities (Certificate, Machine, MachineCertificate) with business rules
- Domain services (CertificateNormalizer, ExpiryEvaluator)
- SQL schema DDL with tables, constraints, and basic indices
- SQL schema deployment and validation
- Unit tests for domain layer (≥80% coverage)
- Project structure cleanup (remove placeholder files)
- Basic DI wiring in Agent project
- Configuration bootstrap (appsettings.json + Azure Key Vault wiring per phase plan)
- Serilog console/file logging baseline

**Out of Scope:**
- WinRM collection logic (Stage 2)
- Persistence MERGE implementations (Stage 2)
- Worker/orchestration (Stage 3)
- Logging infrastructure (Stage 4)

---

## Deliverables

| ID | Deliverable | Location | Acceptance Criteria |
|----|-------------|----------|---------------------|
| D1.1 | Certificate entity | `src/Domain/Certificates/Certificate.cs` | Factory-based creation using Thumbprint value object, ADR-007 invariants enforced, unit tests pass |
| D1.2 | Machine entity | `src/Domain/Machines/Machine.cs` | Hostname/FQDN validation + `DetermineEnvironment` helper implemented, unit tests pass |
| D1.3 | MachineCertificate entity | `src/Domain/Machines/MachineCertificate.cs` | Business key + soft-delete rules enforced, unit tests pass |
| D1.4 | CertificateNormalizer service | `src/Domain/Services/CertificateNormalizer.cs` | `NormalizeThumbprint`, `ExtractSubjectAlternativeNames`, `IsSelfSigned` implemented + tested |
| D1.5 | ExpiryEvaluator service | `src/Domain/Services/ExpiryEvaluator.cs` | Critical/Warning/Valid logic + `DaysUntilExpiry` helper match ADR thresholds |
| D1.6 | SQL DDL script | `docs/architecture/schema-ddl.sql` | Certificates, Machines, MachineCertificates, HarvestExecutions, InventoryLogs tables created (constraints validated) |
| D1.7 | Domain unit tests | `tests/Domain.Tests/` | ≥80% coverage, all tests green |
| D1.8 | Clean project structure + DI/config | All projects | Placeholder files removed, appsettings + Key Vault wiring + Serilog console/file logging configured |

---

## Tasks

### Task Group A: Domain Model Implementation

**Duration:** 3 days

#### A1: Implement Certificate Entity

- Replace the placeholder with an immutable entity and `Certificate.Create(...)` factory that enforces ADR-007 and ADR-002 guidance (Thumbprint normalization via `Thumbprint.Create`, SAN trimming/deduplication, subject/issuer validation, validity window enforcement, wildcard → SAN requirement).
- Keep helper methods such as `DaysUntilExpiry(DateTimeOffset? now = null)` and avoid exposing setters so downstream layers cannot bypass validation.
- Tests to add/update: creation failures for missing/invalid thumbprints, invalid date ranges, wildcard without SANs, plus a “happy path” case verifying SAN dedupe and expiry math.

#### A2: Implement Machine Entity

- Provide a `Machine.Create(...)` factory that trims hostnames/FQDNs, normalizes `Environment` to the allowed list (`DEV/TEST/INTG/UAT/PROD/DEMO/Unknown`), ensures `LastSeen >= FirstSeen`, and sets initial WinRM status to `Unknown`.
- Preserve lifecycle helpers (`UpdateSeen`, `MarkInactive`, `SetWinRmStatus`) and expose `DetermineEnvironment(string hostnameOrFqdn)` so Application logic can classify manual registrations consistently with ADR-006.
- Tests: missing hostname, invalid environment, `LastSeen < FirstSeen`, `DetermineEnvironment` heuristics, `UpdateSeen` advancing timestamps, `SetWinRmStatus` trimming input.

#### A3: Implement MachineCertificate Entity

- Implement `MachineCertificate.Create(...)` using the `Thumbprint` value object and enforce the business key `(MachineId, Thumbprint, SourceType, PathLocation)` exactly as the SQL unique constraint. Allowed sources: `OS`, `IIS`, `F5`, `Repository`.
- Keep lifecycle helpers (`Verify`, `MarkDeleted`, `Recover`) so persistence can manage ADR-004 soft deletes without direct property mutation. `BindingContextJson` should be optional but trimmed and JSON-valid.
- Tests: invalid machine id, thumbprint, source type, missing path location, timestamp ordering, verify/mark-deleted/recover behaviors.

#### A4: Implement CertificateNormalizer Service

- Provide pure helper methods (`NormalizeThumbprint`, `ExtractSubjectAlternativeNames`, `IsSelfSigned`) with only BCL dependencies. `NormalizeThumbprint` should accept SHA-1 and SHA-256 inputs and strip delimiters before upper casing.
- `ExtractSubjectAlternativeNames` must parse SAN extensions using `System.Security.Cryptography.AsnEncodedData` to stay consistent with `docs/architecture/data-model-design.md` guidance; return trimmed DNS-only entries.
- Tests: delimiter removal, uppercase enforcement, invalid length handling, SAN parsing (multi/empty), self-signed detection when subject equals issuer.

#### A5: Implement ExpiryEvaluator Service

- Implement `Evaluate(Certificate certificate, DateTimeOffset? now = null)` with ADR thresholds (Expired ≤0 days, Critical ≤30, Warning ≤90, Valid >90) and helper methods `DaysUntilExpiry` and `IsExpiringSoon` to keep time math centralized.
- Tests: each threshold branch, `DaysUntilExpiry` accuracy, `IsExpiringSoon` honoring caller-provided thresholds.

---

### Task Group B: SQL Schema

**Duration:** 2 days

#### B1: Create DDL Migration Script

**File:** `docs/architecture/schema-ddl.sql`

> NOTE: Per the Phase 1 plan and ADR-007, the authoritative schema lives under `docs/architecture/` so it can be versioned alongside design artifacts and referenced by build scripts. The script must include the five foundational tables (Certificates, Machines, MachineCertificates, HarvestExecutions, InventoryLogs) with the constraints outlined in `docs/architecture/data-model-design.md`.

```sql
-- ============================================================================
-- Cambridge Certificate Inventory Management System
-- Schema Version: 1.0
-- Phase: 1 - Foundation & Basic OS Harvest
-- Date: November 21, 2025
-- Design aligned with: docs/architecture/schema-ddl.sql (authoritative master)
-- ============================================================================

USE ProdSpt_Inventory;
GO

-- ============================================================================
-- TABLE: Certificates
-- Purpose: Deduplicated certificate master table
-- Primary Key: CertificateId (surrogate per ADR-007)
-- Natural Key: Thumbprint (SHA-1 40 or SHA-256 64 chars, uppercase)
-- ============================================================================

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Certificates')
BEGIN
    CREATE TABLE dbo.Certificates (
        CertificateId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
        Thumbprint          NVARCHAR(64)    NOT NULL UNIQUE,  -- SHA-1 (40) or SHA-256 (64)
        Subject             NVARCHAR(500)   NOT NULL,
        Issuer              NVARCHAR(500)   NOT NULL,
        SerialNumber        NVARCHAR(100)   NOT NULL,
        FriendlyName        NVARCHAR(255)   NULL,
        ValidFrom           DATETIME2       NOT NULL,
        ValidTo             DATETIME2       NOT NULL,

        -- Expiration Analysis (computed columns)
        DaysUntilExpiry     AS DATEDIFF(DAY, GETUTCDATE(), ValidTo) PERSISTED,
        ExpiryStatus        AS
            CASE
                WHEN GETUTCDATE() > ValidTo THEN 'Expired'
                WHEN DATEDIFF(DAY, GETUTCDATE(), ValidTo) <= 30 THEN 'Critical'
                WHEN DATEDIFF(DAY, GETUTCDATE(), ValidTo) <= 90 THEN 'Warning'
                ELSE 'Valid'
            END PERSISTED,

        -- Extended Properties (JSON)
        SANs                NVARCHAR(MAX)   NULL,  -- JSON: ["dns:example.com"]
        KeyUsages           NVARCHAR(MAX)   NULL,  -- JSON: ["DigitalSignature"]
        EnhancedKeyUsages   NVARCHAR(MAX)   NULL,  -- JSON: ["1.3.6.1.5.5.7.3.1"]

        -- Cryptographic Properties
        HasPrivateKey       BIT             NULL,
        IsSelfSigned        BIT             NULL,
        KeyAlgorithm        NVARCHAR(50)    NULL,  -- RSA, ECDSA
        KeySize             INT             NULL,  -- 2048, 4096
        SignatureAlgorithm  NVARCHAR(100)   NULL,  -- sha256RSA

        -- Lifecycle
        FirstDiscoveredAt   DATETIME2       NOT NULL DEFAULT GETUTCDATE(),
        LastVerifiedAt      DATETIME2       NOT NULL DEFAULT GETUTCDATE(),

        -- Soft Delete (ADR-004)
        DeletedAt           DATETIME2       NULL,
        DeletedBy           NVARCHAR(100)   NULL,
        DeletedReason       NVARCHAR(500)   NULL,

        CONSTRAINT CK_Certificates_Thumbprint_Length CHECK (LEN(Thumbprint) IN (40, 64)),
        CONSTRAINT CK_Certificates_ValidDates CHECK (ValidTo > ValidFrom),
        CONSTRAINT CK_Certificates_SANs_JSON CHECK (SANs IS NULL OR ISJSON(SANs) = 1),
        CONSTRAINT CK_Certificates_KeyUsages_JSON CHECK (KeyUsages IS NULL OR ISJSON(KeyUsages) = 1),
        CONSTRAINT CK_Certificates_EnhancedKeyUsages_JSON CHECK (EnhancedKeyUsages IS NULL OR ISJSON(EnhancedKeyUsages) = 1),
        CONSTRAINT CK_Certificates_SoftDelete CHECK
            ((DeletedAt IS NULL AND DeletedBy IS NULL AND DeletedReason IS NULL) OR
             (DeletedAt IS NOT NULL AND DeletedBy IS NOT NULL AND DeletedReason IS NOT NULL))
    );

    CREATE NONCLUSTERED INDEX IX_Certificates_ValidTo
        ON dbo.Certificates (ValidTo)
        INCLUDE (Thumbprint, Subject, ExpiryStatus)
        WHERE DeletedAt IS NULL;

    CREATE NONCLUSTERED INDEX IX_Certificates_ExpiryStatus
        ON dbo.Certificates (ExpiryStatus, ValidTo)
        WHERE DeletedAt IS NULL;

    PRINT 'Created table: Certificates';
END
GO

-- ============================================================================
-- TABLE: Machines
-- Purpose: Managed Windows servers
-- Natural Key: Hostname (UNIQUE, required); FQDN nullable
-- Environment: DEV, TEST, INTG, UAT, PROD, DEMO
-- ============================================================================

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Machines')
BEGIN
    CREATE TABLE dbo.Machines (
        MachineId           INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
        Hostname            NVARCHAR(255)   NOT NULL UNIQUE,
        FQDN                NVARCHAR(255)   NULL,  -- Nullable: fallback to Hostname if unavailable
        NetBiosName         NVARCHAR(15)    NULL,
        IPAddress           NVARCHAR(45)    NULL,

        -- Classification
        Environment         NVARCHAR(20)    NOT NULL DEFAULT 'Unknown',

        -- Operating System
        OperatingSystem     NVARCHAR(100)   NULL,
        OSVersion           NVARCHAR(50)    NULL,

        -- Machine Roles (JSON)
        Roles               NVARCHAR(MAX)   NULL,  -- JSON: ["WebServer", "DatabaseHost"]

        -- Connectivity & Operational Telemetry
        IsReachable         BIT             NOT NULL DEFAULT 0,
        WinRMStatus         NVARCHAR(20)    NULL,
        LastSuccessfulScan  DATETIME2       NULL,
        LastConnectionError NVARCHAR(MAX)   NULL,
        ConnectivityFailureCount INT         NOT NULL DEFAULT 0,
        NextRetryAfter      DATETIME2       NULL,

        -- Lifecycle
        FirstDiscoveredAt   DATETIME2       NOT NULL DEFAULT GETUTCDATE(),
        LastVerifiedAt      DATETIME2       NOT NULL DEFAULT GETUTCDATE(),

        -- Soft Delete (ADR-004)
        DeletedAt           DATETIME2       NULL,
        DeletedBy           NVARCHAR(100)   NULL,
        DeletedReason       NVARCHAR(500)   NULL,

        CONSTRAINT CK_Machines_Hostname_NotEmpty CHECK (LEN(RTRIM(Hostname)) > 0),
        CONSTRAINT CK_Machines_Environment CHECK (Environment IN ('DEV', 'TEST', 'INTG', 'UAT', 'PROD', 'DEMO', 'Unknown')),
        CONSTRAINT CK_Machines_Roles_JSON CHECK (ISJSON(Roles) = 1 OR Roles IS NULL),
        CONSTRAINT CK_Machines_SoftDelete CHECK
            ((DeletedAt IS NULL AND DeletedBy IS NULL AND DeletedReason IS NULL) OR
             (DeletedAt IS NOT NULL AND DeletedBy IS NOT NULL AND DeletedReason IS NOT NULL))
    );

    CREATE NONCLUSTERED INDEX IX_Machines_Environment
        ON dbo.Machines (Environment, IsReachable)
        WHERE DeletedAt IS NULL;

    CREATE NONCLUSTERED INDEX IX_Machines_Connectivity
        ON dbo.Machines (IsReachable, NextRetryAfter, LastSuccessfulScan)
        WHERE DeletedAt IS NULL;

    PRINT 'Created table: Machines';
END
GO

-- ============================================================================
-- TABLE: MachineCertificates
-- Purpose: Many-to-many with location context (OS, IIS, F5, Repository)
-- Business Key: (MachineId, Thumbprint, SourceType, PathLocation)
-- FK Strategy: Uses Thumbprint directly (natural key reference per ADR-007)
-- ============================================================================

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'MachineCertificates')
BEGIN
    CREATE TABLE dbo.MachineCertificates (
        MachineCertificateId INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
        MachineId           INT             NOT NULL,
        Thumbprint          NVARCHAR(64)    NOT NULL,  -- Denormalized for business key

        -- Certificate Location
        SourceType          NVARCHAR(20)    NOT NULL,  -- OS, IIS, F5, Repository
        PathLocation        NVARCHAR(500)   NOT NULL,  -- LocalMachine\My, Site1:443, /Common/cert.crt

        -- Binding Context (JSON - source-specific metadata)
        BindingContext      NVARCHAR(MAX)   NULL,  -- IIS site details, F5 virtual server

        -- Lifecycle
        FirstDiscoveredAt   DATETIME2       NOT NULL DEFAULT GETUTCDATE(),
        LastVerifiedAt      DATETIME2       NOT NULL DEFAULT GETUTCDATE(),

        -- Soft Delete (ADR-004)
        DeletedAt           DATETIME2       NULL,
        DeletedBy           NVARCHAR(100)   NULL,
        DeletedReason       NVARCHAR(500)   NULL,

        CONSTRAINT FK_MachineCertificates_Machine
            FOREIGN KEY (MachineId) REFERENCES dbo.Machines(MachineId),
        CONSTRAINT FK_MachineCertificates_Certificate
            FOREIGN KEY (Thumbprint) REFERENCES dbo.Certificates(Thumbprint),
        CONSTRAINT UQ_MachineCertBinding
            UNIQUE (MachineId, Thumbprint, SourceType, PathLocation),
        CONSTRAINT CK_MachineCertificates_SourceType
            CHECK (SourceType IN ('OS', 'IIS', 'F5', 'Repository')),
        CONSTRAINT CK_MachineCertificates_PathLocation_NotEmpty
            CHECK (LEN(RTRIM(PathLocation)) > 0),
        CONSTRAINT CK_MachineCertificates_BindingContext_JSON
            CHECK (ISJSON(BindingContext) = 1 OR BindingContext IS NULL),
        CONSTRAINT CK_MachineCertificates_SoftDelete CHECK
            ((DeletedAt IS NULL AND DeletedBy IS NULL AND DeletedReason IS NULL) OR
             (DeletedAt IS NOT NULL AND DeletedBy IS NOT NULL AND DeletedReason IS NOT NULL))
    );

    CREATE NONCLUSTERED INDEX IX_MachineCertificates_MachineId
        ON dbo.MachineCertificates (MachineId)
        INCLUDE (Thumbprint, SourceType, PathLocation, LastVerifiedAt)
        WHERE DeletedAt IS NULL;

    CREATE NONCLUSTERED INDEX IX_MachineCertificates_Thumbprint
        ON dbo.MachineCertificates (Thumbprint)
        INCLUDE (MachineId, SourceType, PathLocation)
        WHERE DeletedAt IS NULL;

    CREATE NONCLUSTERED INDEX IX_MachineCertificates_SourceType
        ON dbo.MachineCertificates (SourceType, MachineId)
        WHERE DeletedAt IS NULL;

    CREATE NONCLUSTERED INDEX IX_MachineCertificates_DeletedAt
        ON dbo.MachineCertificates (DeletedAt)
        WHERE DeletedAt IS NOT NULL;

    PRINT 'Created table: MachineCertificates';
END
GO

PRINT 'Schema creation complete.';
GO
```

#### B2: Manual Schema Validation

Create test validation script:

**File:** `docs/architecture/schema-validation.sql`

```sql
-- ============================================================================
-- Schema Validation Tests
-- Run this after deploying 001-initial-schema.sql
-- ============================================================================

USE ProdSpt_Inventory;
GO

-- Test 1: Insert test certificate (SHA-1)
DECLARE @Thumbprint1 NVARCHAR(64) = 'ABC123DEF456789012345678901234567890ABCD';

INSERT INTO dbo.Certificates (Thumbprint, Subject, Issuer, ValidFrom, ValidTo, KeyAlgorithm, KeySize, SignatureAlgorithm, SerialNumber)
VALUES (@Thumbprint1, 'CN=test.cambridge.edu', 'CN=TestCA', '2025-01-01', '2026-01-01', 'RSA', 2048, 'sha256RSA', '123456');

-- Test 2: Insert test certificate (SHA-256)
DECLARE @Thumbprint2 NVARCHAR(64) = 'ABCD1234567890ABCD1234567890ABCD1234567890ABCD1234567890ABCD12';

INSERT INTO dbo.Certificates (Thumbprint, Subject, Issuer, ValidFrom, ValidTo, KeyAlgorithm, KeySize, SignatureAlgorithm, SerialNumber)
VALUES (@Thumbprint2, 'CN=sha256-test.cambridge.edu', 'CN=TestCA', '2025-01-01', '2026-01-01', 'ECDSA', 256, 'sha256ECDSA', '789012');

SELECT * FROM dbo.Certificates WHERE Thumbprint IN (@Thumbprint1, @Thumbprint2);

-- Test 3: Insert test machine
INSERT INTO dbo.Machines (Hostname, FQDN, Environment)
VALUES ('SERVER01', 'server01.corp.cambridge.edu', 'TEST');

DECLARE @MachineId INT = SCOPE_IDENTITY();

-- Test 4: Insert machine-certificate binding
INSERT INTO dbo.MachineCertificates (MachineId, Thumbprint, SourceType, PathLocation)
VALUES (@MachineId, @Thumbprint1, 'OS', 'LocalMachine\My');

-- Test 5: Verify relationships
SELECT
    m.Hostname,
    m.FQDN,
    c.Subject,
    mc.SourceType,
    mc.PathLocation,
    c.ExpiryStatus
FROM dbo.MachineCertificates mc
INNER JOIN dbo.Machines m ON mc.MachineId = m.MachineId
INNER JOIN dbo.Certificates c ON mc.Thumbprint = c.Thumbprint;

-- Test 6: Verify computed columns
SELECT Thumbprint, Subject, DaysUntilExpiry, ExpiryStatus
FROM dbo.Certificates;

-- Test 7: Cleanup
DELETE FROM dbo.MachineCertificates WHERE MachineId = @MachineId;
DELETE FROM dbo.Machines WHERE MachineId = @MachineId;
DELETE FROM dbo.Certificates WHERE Thumbprint IN (@Thumbprint1, @Thumbprint2);

PRINT 'Validation complete - all constraints working.';
GO
```

---

### Task Group C: Unit Testing

**Duration:** 2 days

#### C1: Setup Domain.Tests Project

1. **Delete placeholder:** Remove `tests/Domain.Tests/UnitTest1.cs`

2. **Add test utilities:**

**File:** `tests/Domain.Tests/TestHelpers/CertificateBuilder.cs`

```csharp
namespace InventoryManagement.Domain.Tests.TestHelpers;

using InventoryManagement.Domain.Certificates;

/// <summary>
/// Test data builder for Certificate entities.
/// </summary>
public class CertificateBuilder
{
    private string _thumbprint = "ABC123DEF456789012345678901234567890ABCD";
    private string _subject = "CN=test.cambridge.edu";
    private string _issuer = "CN=TestCA";
    private DateTimeOffset _validFrom = DateTimeOffset.UtcNow.AddDays(-30);
    private DateTimeOffset _validTo = DateTimeOffset.UtcNow.AddDays(365);

    public CertificateBuilder WithThumbprint(string thumbprint)
    {
        _thumbprint = thumbprint;
        return this;
    }

    public CertificateBuilder WithSubject(string subject)
    {
        _subject = subject;
        return this;
    }

    public CertificateBuilder ExpiresIn(int days)
    {
        _validTo = DateTimeOffset.UtcNow.AddDays(days);
        return this;
    }

    public Certificate Build()
    {
        return new Certificate
        {
            Thumbprint = _thumbprint,
            Subject = _subject,
            Issuer = _issuer,
            ValidFrom = _validFrom,
            ValidTo = _validTo,
            KeyAlgorithm = "RSA",
            KeySize = 2048,
            SignatureAlgorithm = "sha256RSA",
            SerialNumber = "123456"
        };
    }
}
```

3. **Implement comprehensive tests** (see unit test examples in A1-A5 above)

**File:** `tests/Domain.Tests/Certificates/CertificateTests.cs`
**File:** `tests/Domain.Tests/Machines/MachineTests.cs`
**File:** `tests/Domain.Tests/Machines/MachineCertificateTests.cs`
**File:** `tests/Domain.Tests/Services/CertificateNormalizerTests.cs`
**File:** `tests/Domain.Tests/Services/ExpiryEvaluatorTests.cs`

---

### Task Group D: Project Cleanup

**Duration:** 1 day

#### D1: Remove Placeholder Files

Delete the following files:
- `src/Domain/Class1.cs`
- `src/Application/Class1.cs`
- `src/Infrastructure/Class1.cs`
- `tests/Domain.Tests/UnitTest1.cs`

#### D2: Verify Build

```powershell
dotnet restore
dotnet build --no-restore
dotnet test --no-build
```

All tests should pass, no build warnings.

---

### Task Group E: Configuration & Logging

**Duration:** 0.5 day

#### E1: Bootstrap appsettings + Key Vault wiring

- Populate `src/Agent/appsettings.json` with placeholder values for SQL connectivity, WinRM targets (5-10 pilot machines), and Serilog sinks. Check in only sanitized values per security guidelines.
- In `src/Agent/Program.cs`, bind the WinRM/Harvest configuration section and add Azure Key Vault integration (developer secrets locally, KV in hosted environments) per `docs/planning/phase-1-plan.md`.

#### E2: Configure Serilog console/file sinks

- Register Serilog (console + rolling file) before host build. Structured properties should include `Machine`, `HarvestCycleId`, and `CertificateCount`. SQL sink is deferred to Stage 4.

#### E3: Document bootstrap steps

- Update `docs/architecture/agent-architecture.md` (Configuration section) with the new keys/secret sources and add a short “Getting Started” excerpt in `docs/implementation/1-phase-one/phase-1-stage-1-foundation.md` referencing this task.

##### Configuration Bootstrap – Quick Start

1. **Baseline file (`src/Agent/appsettings.json`):** Contains sanitized defaults for SQL Server, WinRM concurrency, F5 placeholders, harvest cadence, manual pilot servers (`TargetServers`), and Serilog sinks (console + rolling file). Update host lists here when promoting machines from pilot → production.
2. **Developer overrides:** Copy `src/Agent/appsettings.Development.json.example` to `appsettings.Development.json` (gitignored). Provide real usernames/password secret names, tune logging verbosity, or shorten harvest intervals while testing locally.
3. **Secrets:** Store actual secrets in user-secrets for dev (`dotnet user-secrets set "AzureKeyVault:ClientSecret" ...`) or in Azure Key Vault for hosted environments. Toggle Key Vault loading via `AzureKeyVault.Enabled` and ensure `VaultUri` plus identity/secret fields are populated.
    - _Bookmark (Nov 26 follow-up): Provision the Azure AD app registration + Key Vault access policies and document the exact secret names before enabling the hosted service._
4. **Validation:** `ServiceRegistration.AddInventoryServices` binds/validates all sections on startup. A missing connection string or malformed WinRM value now fails fast with a descriptive exception.
5. **Structured logging:** Serilog templates surface `Machine`, `HarvestCycleId`, and `CertificateCount`. Use `ILogger.BeginScope` or `LogContext.PushProperty` in future harvest code to supply real values; the bootstrap worker already emits a heartbeat with placeholder properties.

---

## Acceptance Criteria

| ID | Criteria | Validation Method |
|----|----------|-------------------|
| AC1 | All domain entities implemented | Code review, builds without errors |
| AC2 | Domain validation logic working | Unit tests pass (≥80% coverage) |
| AC3 | SQL schema deployed | DDL script runs successfully on test SQL Server |
| AC4 | Schema constraints enforced | Validation test script passes |
| AC5 | No placeholder files remain | File search for `Class1.cs`, `UnitTest1.cs` returns zero results |
| AC6 | Build clean | `dotnet build` completes with zero warnings |
| AC7 | Tests green | `dotnet test` shows 100% pass rate |
| AC8 | Configuration + logging bootstrap complete | `appsettings.json` checked in (redacted secrets), Key Vault references resolved, Serilog console/file output verified |

---

## Dependencies

**Required Before Starting:**
- [ ] SQL Server test instance available (`ProdSpt_Inventory` database)
- [ ] Development environment configured (Visual Studio / VS Code + .NET 8 SDK)
- [ ] Git repository initialized and main branch protected

**Provides to Next Stage:**
- Domain model ready for persistence layer
- SQL schema deployed and validated
- Unit test harness established

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| SQL schema design flaws discovered late | High | Manual testing before proceeding to Stage 2 |
| Domain model misalignment with v1.0 data | Medium | Review v1.0 scripts for field mapping |
| Test coverage insufficient | Low | Code review before merge |

---

## Success Metrics

- **Domain tests:** ≥80% code coverage
- **Build time:** <30 seconds for full solution
- **Schema deployment:** <10 seconds on test SQL Server
- **Zero rework required** in Stage 2 due to foundation issues

---

## Next Stage

**Stage 2: Core Features (Weeks 1.5-2.5)** - Implement WinRM collector, certificate parsing, and SQL persistence with MERGE statements.
