-- ============================================================================
-- SQL Server Schema DDL for Cambridge Inventory Management v2.0
-- ============================================================================
-- Purpose: Complete executable DDL for certificate inventory database
-- Based on: Architecture decisions finalized 2025-11-21
-- Last Updated: 2025-11-21
-- 1. Canonical certificate storage (Certificates table)
-- 2. Dynamic machine discovery (Machines table)
-- 3. Many-to-many via MachineCertificates with surrogate key (ADR-007)
-- 4. Soft delete with 90-day grace period (ADR-004) - included Phase 1
-- 5. Full audit trail (DeletedAt, DeletedBy, DeletedReason)
-- Design Decisions:
--   - Thumbprint: VARCHAR(64) supports SHA-1 (40) & SHA-256 (64)
--   - Expiry: Critical ≤30 days, Warning ≤90 days
--   - Machine key: Hostname UNIQUE (required), FQDN nullable
--   - Environment: DEV, TEST, INTG, UAT, PROD, DEMO
--   - SourceType: OS, IIS, F5, Repository
-- ============================================================================

USE ProdSpt_Inventory;
GO

-- ============================================================================
-- TABLE: Certificates (Canonical Store)
-- ============================================================================
-- Stores deduplicated certificate data by thumbprint
-- One row per unique certificate regardless of location/machine
-- Thumbprint normalized: uppercase, no delimiters, 40 (SHA-1) or 64 (SHA-256) chars
-- ============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Certificates')
BEGIN
    CREATE TABLE dbo.Certificates
    (
        -- Primary Key (Surrogate)
        CertificateId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,

        -- Natural Key (Business Identifier)
        Thumbprint          NVARCHAR(64)    NOT NULL UNIQUE,  -- SHA-1 (40) or SHA-256 (64)

        -- Certificate Core Properties
        Subject             NVARCHAR(500)   NOT NULL,
        Issuer              NVARCHAR(500)   NOT NULL,
        SerialNumber        NVARCHAR(100)   NOT NULL,
        FriendlyName        NVARCHAR(255)   NULL,

        -- Validity Period
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

        -- Extended Properties (JSON for variable-length data)
        SANs                NVARCHAR(MAX)   NULL,  -- JSON array: ["dns:example.com", "dns:*.example.com"]
        KeyUsages           NVARCHAR(MAX)   NULL,  -- JSON array: ["DigitalSignature", "KeyEncipherment"]
        EnhancedKeyUsages   NVARCHAR(MAX)   NULL,  -- JSON array: ["1.3.6.1.5.5.7.3.1", "1.3.6.1.5.5.7.3.2"]

        -- Cryptographic Properties
        KeyAlgorithm        NVARCHAR(50)    NULL,  -- RSA, ECDSA, DSA
        SignatureAlgorithm  NVARCHAR(100)   NULL,  -- sha256RSA, sha1RSA
        KeySize             INT             NULL,  -- 2048, 4096, 256 (EC)
        IsSelfSigned        BIT             NULL,
        HasPrivateKey       BIT             NULL,

        -- Lifecycle Timestamps
        FirstDiscoveredAt   DATETIME2       NOT NULL DEFAULT GETUTCDATE(),
        LastVerifiedAt      DATETIME2       NOT NULL DEFAULT GETUTCDATE(),

        -- Soft Delete (ADR-004)
        DeletedAt           DATETIME2       NULL,
        DeletedBy           NVARCHAR(100)   NULL,
        DeletedReason       NVARCHAR(500)   NULL,

        -- Constraints
        CONSTRAINT CK_Certificates_Thumbprint_Length CHECK (LEN(Thumbprint) IN (40, 64)),
        CONSTRAINT CK_Certificates_ValidDates CHECK (ValidTo > ValidFrom),
        CONSTRAINT CK_Certificates_SANs_JSON CHECK (SANs IS NULL OR ISJSON(SANs) = 1),
        CONSTRAINT CK_Certificates_KeyUsages_JSON CHECK (KeyUsages IS NULL OR ISJSON(KeyUsages) = 1),
        CONSTRAINT CK_Certificates_EnhancedKeyUsages_JSON CHECK (EnhancedKeyUsages IS NULL OR ISJSON(EnhancedKeyUsages) = 1),
        CONSTRAINT CK_Certificates_SoftDelete CHECK
            ((DeletedAt IS NULL AND DeletedBy IS NULL AND DeletedReason IS NULL) OR
             (DeletedAt IS NOT NULL AND DeletedBy IS NOT NULL AND DeletedReason IS NOT NULL))
    );

    -- Indexes for expiration queries
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
-- TABLE: Machines (Dynamic Discovery)
-- ============================================================================
-- Stores Windows servers discovered during harvest operations
-- Natural key: Hostname (required, unique); FQDN nullable for flexibility
-- Environment classification: DEV, TEST, INTG, UAT, PROD, DEMO
-- ============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Machines')
BEGIN
    CREATE TABLE dbo.Machines
    (
        -- Primary Key (Surrogate)
        MachineId           INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,

        -- Natural Key (Business Identifier)
        Hostname            NVARCHAR(255)   NOT NULL UNIQUE,

        -- Machine Identification
        FQDN                NVARCHAR(255)   NULL,  -- Nullable: fallback to Hostname if FQDN unavailable
        NetBiosName         NVARCHAR(15)    NULL,  -- Legacy compatibility
        IPAddress           NVARCHAR(45)    NULL,  -- IPv4/IPv6 support

        -- Classification
        Environment         NVARCHAR(20)    NOT NULL DEFAULT 'Unknown',  -- DEV, TEST, INTG, UAT, PROD, DEMO, Unknown

        -- Operating System Properties
        OperatingSystem     NVARCHAR(100)   NULL,
        OSVersion           NVARCHAR(50)    NULL,

        -- Machine Roles (JSON array for extensibility)
        Roles               NVARCHAR(MAX)   NULL,  -- JSON: ["WebServer", "DatabaseHost", "DomainController"]

        -- Connectivity & Operational Telemetry
        IsReachable         BIT             NOT NULL DEFAULT 0,
        WinRMStatus         NVARCHAR(20)    NULL,  -- Reachable, Unreachable, AuthFailure, Timeout
        LastSuccessfulScan  DATETIME2       NULL,
        LastConnectionError NVARCHAR(MAX)   NULL,
        ConnectivityFailureCount INT         NOT NULL DEFAULT 0,  -- Increment on failure, reset on success
        NextRetryAfter      DATETIME2       NULL,  -- Backoff timestamp for failed machines

        -- Lifecycle Timestamps
        FirstDiscoveredAt   DATETIME2       NOT NULL DEFAULT GETUTCDATE(),
        LastVerifiedAt      DATETIME2       NOT NULL DEFAULT GETUTCDATE(),

        -- Soft Delete (ADR-004)
        DeletedAt           DATETIME2       NULL,
        DeletedBy           NVARCHAR(100)   NULL,
        DeletedReason       NVARCHAR(500)   NULL,

        -- Constraints
        CONSTRAINT CK_Machines_Hostname_NotEmpty CHECK (LEN(RTRIM(Hostname)) > 0),
        CONSTRAINT CK_Machines_Environment CHECK (Environment IN ('DEV', 'TEST', 'INTG', 'UAT', 'PROD', 'DEMO', 'Unknown')),
        CONSTRAINT CK_Machines_Roles_JSON CHECK (Roles IS NULL OR ISJSON(Roles) = 1),
        CONSTRAINT CK_Machines_SoftDelete CHECK
            ((DeletedAt IS NULL AND DeletedBy IS NULL AND DeletedReason IS NULL) OR
             (DeletedAt IS NOT NULL AND DeletedBy IS NOT NULL AND DeletedReason IS NOT NULL))
    );

    -- Index for active machines queries
    CREATE NONCLUSTERED INDEX IX_Machines_Environment
        ON dbo.Machines (Environment, IsReachable)
        WHERE DeletedAt IS NULL;

    -- Index for connectivity status and backoff queries
    CREATE NONCLUSTERED INDEX IX_Machines_Connectivity
        ON dbo.Machines (IsReachable, NextRetryAfter, LastSuccessfulScan)
        WHERE DeletedAt IS NULL;

    PRINT 'Created table: Machines';
END
GO

-- ============================================================================
-- TABLE: MachineCertificates (Many-to-Many Junction)
-- ============================================================================
-- Links certificates to machines with location and binding context
-- Uses surrogate key per ADR-007 for flexibility
-- Business key: (MachineId, Thumbprint, SourceType, PathLocation)
-- SourceType values: OS, IIS, F5, Repository
-- ============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'MachineCertificates')
BEGIN
    CREATE TABLE dbo.MachineCertificates
    (
        -- Surrogate Primary Key (ADR-007)
        MachineCertificateId INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,

        -- Foreign Keys (Business Key Components)
        MachineId           INT             NOT NULL,
        Thumbprint          NVARCHAR(64)    NOT NULL,  -- Denormalized for business key; FK via CertificateId

        -- Certificate Location (Business Key Components)
        SourceType          NVARCHAR(20)    NOT NULL,  -- OS, IIS, F5, Repository
        PathLocation        NVARCHAR(500)   NOT NULL,  -- 'LocalMachine\My', 'Default Web Site:443', '/Common/ssl-cert'

        -- Binding Context (JSON - source-specific metadata)
        BindingContext      NVARCHAR(MAX)   NULL,  -- JSON: IIS site details, F5 virtual server, Repository file path

        -- Lifecycle Timestamps
        FirstDiscoveredAt   DATETIME2       NOT NULL DEFAULT GETUTCDATE(),
        LastVerifiedAt      DATETIME2       NOT NULL DEFAULT GETUTCDATE(),

        -- Soft Delete (ADR-004)
        DeletedAt           DATETIME2       NULL,
        DeletedBy           NVARCHAR(100)   NULL,
        DeletedReason       NVARCHAR(500)   NULL,

        -- Foreign Key Constraints
        CONSTRAINT FK_MachineCertificates_Machine
            FOREIGN KEY (MachineId) REFERENCES dbo.Machines(MachineId),
        CONSTRAINT FK_MachineCertificates_Certificate
            FOREIGN KEY (Thumbprint) REFERENCES dbo.Certificates(Thumbprint),

        -- Business Key Unique Constraint (ADR-007)
        -- Allows same cert in multiple locations on same machine
        CONSTRAINT UQ_MachineCertificate_BusinessKey
            UNIQUE (MachineId, Thumbprint, SourceType, PathLocation),

        -- Validation Constraints
        CONSTRAINT CK_MachineCertificates_SourceType
            CHECK (SourceType IN ('OS', 'IIS', 'F5', 'Repository')),
        CONSTRAINT CK_MachineCertificates_PathLocation_NotEmpty
            CHECK (LEN(RTRIM(PathLocation)) > 0),
        CONSTRAINT CK_MachineCertificates_BindingContext_JSON
            CHECK (BindingContext IS NULL OR ISJSON(BindingContext) = 1),
        CONSTRAINT CK_MachineCertificates_SoftDelete CHECK
            ((DeletedAt IS NULL AND DeletedBy IS NULL AND DeletedReason IS NULL) OR
             (DeletedAt IS NOT NULL AND DeletedBy IS NOT NULL AND DeletedReason IS NOT NULL))
    );

    -- Performance Indexes
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

    -- Index for soft delete cleanup (grace period queries)
    CREATE NONCLUSTERED INDEX IX_MachineCertificates_DeletedAt
        ON dbo.MachineCertificates (DeletedAt)
        WHERE DeletedAt IS NOT NULL;

    PRINT 'Created table: MachineCertificates';
END
GO

-- ============================================================================
-- TABLE: HarvestExecutions (Run Tracking - Phase 2)
-- ============================================================================
-- Tracks each scheduled harvest run for auditing and diagnostics
-- One row per Worker.ExecuteAsync() invocation
-- NOTE: Included in Phase 1 schema; populated starting Phase 2
-- ============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'HarvestExecutions')
BEGIN
    CREATE TABLE dbo.HarvestExecutions
    (
        -- Primary Key
        HarvestExecutionId  INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,

        -- Execution Metadata
        StartedAt           DATETIME2       NOT NULL DEFAULT GETUTCDATE(),
        CompletedAt         DATETIME2       NULL,
        DurationSeconds     AS DATEDIFF(SECOND, StartedAt, CompletedAt) PERSISTED,

        -- Execution Results
        Status              NVARCHAR(50)    NOT NULL DEFAULT 'Running',  -- Running, Completed, Failed, PartialFailure
        MachinesScanned     INT             NOT NULL DEFAULT 0,
        MachinesSuccessful  INT             NOT NULL DEFAULT 0,
        MachinesFailed      INT             NOT NULL DEFAULT 0,
        CertificatesFound   INT             NOT NULL DEFAULT 0,
        CertificatesNew     INT             NOT NULL DEFAULT 0,
        CertificatesUpdated INT             NOT NULL DEFAULT 0,

        -- Error Summary
        ErrorMessage        NVARCHAR(MAX)   NULL,
        FailedMachines      NVARCHAR(MAX)   NULL,  -- JSON array: [{"Hostname":"...", "Error":"..."}]

        -- Agent Information
        AgentVersion        NVARCHAR(50)    NULL,
        AgentHostname       NVARCHAR(255)   NULL,

        -- Constraints
        CONSTRAINT CK_HarvestExecutions_Status
            CHECK (Status IN ('Running', 'Completed', 'Failed', 'PartialFailure')),
        CONSTRAINT CK_HarvestExecutions_Counts
            CHECK (MachinesSuccessful + MachinesFailed <= MachinesScanned),
        CONSTRAINT CK_HarvestExecutions_FailedMachines_JSON
            CHECK (FailedMachines IS NULL OR ISJSON(FailedMachines) = 1)
    );

    -- Index for run history queries
    CREATE NONCLUSTERED INDEX IX_HarvestExecutions_StartedAt
        ON dbo.HarvestExecutions (StartedAt DESC)
        INCLUDE (Status, DurationSeconds, MachinesScanned);

    PRINT 'Created table: HarvestExecutions';
END
GO

-- ============================================================================
-- TABLE: InventoryLogs (Existing v1.0 Logging Table)
-- ============================================================================
-- Preserved from PowerShell v1.0 for backward compatibility
-- v2.0 uses Serilog for structured logging (ADR-006)
-- This table remains for legacy script support during transition
-- ============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'InventoryLogs')
BEGIN
    CREATE TABLE dbo.InventoryLogs
    (
        LogId               INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
        Timestamp           DATETIME2       NOT NULL DEFAULT GETUTCDATE(),
        ScriptName          NVARCHAR(100)   NOT NULL,
        Severity            NVARCHAR(20)    NOT NULL,  -- 'Info', 'Warning', 'Error'
        Message             NVARCHAR(MAX)   NOT NULL,
        MachineName         NVARCHAR(255)   NULL,
        AdditionalData      NVARCHAR(MAX)   NULL,

        CONSTRAINT CK_InventoryLogs_Severity
            CHECK (Severity IN ('Info', 'Warning', 'Error'))
    );

    CREATE NONCLUSTERED INDEX IX_InventoryLogs_Timestamp
        ON dbo.InventoryLogs (Timestamp DESC);

    PRINT 'Created table: InventoryLogs (legacy v1.0)';
END
GO

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================
-- Run these after deployment to validate schema creation
-- ============================================================================

PRINT '';
PRINT '============================================================================';
PRINT 'Schema Deployment Summary';
PRINT '============================================================================';

SELECT
    t.name AS TableName,
    SUM(CASE WHEN i.type_desc = 'CLUSTERED' THEN 1 ELSE 0 END) AS ClusteredIndexes,
    SUM(CASE WHEN i.type_desc = 'NONCLUSTERED' THEN 1 ELSE 0 END) AS NonClusteredIndexes,
    COUNT(DISTINCT fk.name) AS ForeignKeys,
    COUNT(DISTINCT cc.name) AS CheckConstraints
FROM sys.tables t
LEFT JOIN sys.indexes i ON t.object_id = i.object_id
LEFT JOIN sys.foreign_keys fk ON t.object_id = fk.parent_object_id
LEFT JOIN sys.check_constraints cc ON t.object_id = cc.parent_object_id
WHERE t.name IN ('Certificates', 'Machines', 'MachineCertificates', 'HarvestExecutions', 'InventoryLogs')
GROUP BY t.name
ORDER BY t.name;

PRINT '';
PRINT 'Schema deployment completed successfully.';
PRINT 'Ready for Week 1 Task 2: Deploy Schema to Test SQL Server';
GO
