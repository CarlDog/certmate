# Phase 1 Plan – Foundation & Basic OS Harvest

**Last Updated:** November 20, 2025
**Status:** Draft – Pending Kickoff
**Owner:** Carl R. Yeager
**Phase Window:** Weeks 1–4 (target)

---

## 1. Scope

Deliver a **working OS certificate harvest for a small set of machines** (5-10 servers) with core infrastructure in place:

**In Scope:**
- Domain model entities (Certificate, Machine, MachineCertificate) with invariants
- SQL schema deployment (Certificates, Machines, MachineCertificates, HarvestExecutions, InventoryLogs tables + indices)
- SQL persistence layer (ADO.NET MERGE statements for core tables; insert-only for execution tracking)
- WinRM OS certificate collector (sequential, single-threaded—no parallelization yet)
- Certificate normalization (thumbprint uppercase, delimiter removal, SHA-256 support)
- Expiry status computation (Critical/Warning/Valid)
- Basic Serilog logging (console + file sinks—SQL sink populated but not yet wired)
- Manual machine registration (config file with target hostname list)
- Basic ops runbook (how to add machines, trigger manual harvest)
- Soft delete columns present in schema (DeletedAt in MachineCertificates; lifecycle logic deferred to Phase 3)

**Out of Scope (Deferred to Later Phases):**
- Machine discovery from AD (Phase 3)
- Parallel WinRM execution (Phase 2)
- IIS binding collection (Phase 2)
- Soft delete lifecycle logic (Phase 3—columns exist but not actively managed)
- Serilog SQL sink integration (Phase 2—table exists, Serilog config not wired)
- HarvestExecution orchestration workflow (Phase 2—table exists for future use)
- SQLite buffer (Phase 2)
- F5, Repository, WebUI (Phases 4-5)

---

## 2. Objectives

| ID | Objective | Success Metric |
|----|-----------|----------------|
| O1 | Domain model correct | All invariants enforced; 80% unit test coverage |
| O2 | Schema deployed | Tables created with constraints, indices; manual MERGE test passes |
| O3 | Harvest working | 5-machine harvest completes successfully with certificates in SQL |
| O4 | Deduplication verified | Same certificate on multiple machines → single row in Certificates table |
| O5 | Normalization validated | Thumbprints stored uppercase, no delimiters |
| O6 | Manual re-harvest | Second harvest updates LastVerified, no duplicate rows created |

---

## 3. Deliverables

| Deliverable | Description | Acceptance |
|-------------|-------------|------------|
| D1 | Domain entities | Certificate, Machine, MachineCertificate classes with validation |
| D2 | Domain services | CertificateNormalizer, ExpiryEvaluator with unit tests |
| D3 | Port interfaces | ICertificateStoreReader, IIngestionWriter defined |
| D4 | SQL schema DDL | Migration script with all tables (Certificates, Machines, MachineCertificates, HarvestExecutions, InventoryLogs), constraints, indices |
| D5 | SqlServerPersistence | MERGE statements for Certificates, Machines, MachineCertificates |
| D6 | WinRmOSCollector | Sequential OS cert harvesting (no throttling/retry yet) |
| D7 | Agent Worker | Basic BackgroundService with manual trigger |
| D8 | Configuration | appsettings.json with target machine list (5-10 Hostnames) |
| D9 | Basic runbook | Add machines, run harvest, view logs |

---

## 4. Work Breakdown Structure

### Epic A: Domain Model

- A1: Implement Certificate entity (Thumbprint, Subject, Issuer, ValidFrom, ValidTo, SANs, KeyUsages)
- A2: Implement Machine entity (MachineId, Hostname, FQDN, Environment, FirstSeen, LastSeen, IsActive)
- A3: Implement MachineCertificate entity (Id, MachineId, Thumbprint, SourceType, PathLocation, DeletedAt)
- A4: Implement CertificateNormalizer service (thumbprint normalization, SAN extraction)
- A5: Implement ExpiryEvaluator service (compute Critical/Warning/Valid from ValidTo)
- A6: Unit tests for entities and services (80% coverage target)

### Epic B: SQL Persistence

- B1: Create DDL migration script (Certificates, Machines, MachineCertificates, HarvestExecutions, InventoryLogs tables)
- B2: Add primary keys, foreign keys, unique constraints, CHECK constraints (Environment enum)
- B3: Add basic indices (Certificates.ValidTo, Machines.Hostname, MachineCertificates.MachineId)
- B4: Implement SqlServerPersistence.UpsertMachine (MERGE, returns MachineId)
- B5: Implement SqlServerPersistence.UpsertCertificates (MERGE by Thumbprint)
- B6: Implement SqlServerPersistence.UpsertMachineCertificates (MERGE with unique constraint)
- B7: Integration tests with Testcontainers (SQL Server in Docker)

### Epic C: WinRM OS Collector

- C1: Implement WinRmOSCollector adapter (ICertificateStoreReader)
- C2: PowerShell session creation (basic—no retry yet)
- C3: Enumerate certificate stores (LocalMachine\My, Root, CA, AuthRoot)
- C4: Map X509Certificate2 properties to Domain.Certificate
- C5: Close session cleanly
- C6: Unit tests with mock PowerShell responses

### Epic D: Agent & Configuration

- D1: Create CertificateCollectionWorker BackgroundService
- D2: Wire DI (Domain, Infrastructure, Agent composition)
- D3: Configure appsettings.json (SQL connection, target machines list)
- D4: Add Serilog console + file sinks
- D5: Manual harvest trigger (ExecuteAsync override)

### Epic E: Basic Operations

- E1: Document adding machines to config file
- E2: Document running manual harvest (dotnet run or service start)
- E3: Document viewing logs (console output, file location)
- E4: Create basic WinRM connectivity test script

---

## 5. Sequencing & Dependencies

| Order | Epic | Reason |
|-------|------|--------|
| 1 | A (Domain) | Foundation for all other layers |
| 2 | B (Persistence) | Required before collector can save data |
| 3 | C (Collector) | Core harvest logic |
| 4 | D (Agent) | Composition root ties everything together |
| 5 | E (Ops) | Documentation after implementation validated |

---

## 6. Estimates

| Epic | Size | Notes |
|------|------|-------|
| A | M | Core entities + services straightforward |
| B | L | MERGE statements + integration testing effort |
| C | M | WinRM basics without parallelization |
| D | S | Thin orchestration layer |
| E | XS | Documentation only |

**Total:** ~2 Large equivalents (4-week phase)

---

## 7. Risks & Mitigations

| ID | Risk | Likelihood | Impact | Mitigation |
|----|------|-----------|--------|-----------|
| R1 | WinRM connectivity issues | Medium | High | Pre-kickoff connectivity test script; validate firewall rules |
| R2 | SQL schema design flaws | Low | High | Manual testing of MERGE statements before integration |
| R3 | Domain model misalignment | Low | Medium | Review domain invariants against architecture docs |

---

## 8. Acceptance Criteria

- Domain unit tests pass (≥80% coverage)
- SQL schema deployed to test environment
- Harvest 5 machines sequentially
- Certificates table has deduplicated thumbprints
- Manual re-harvest updates LastVerified without duplicates
- Runbook reviewed and validated

---

## 9. Exit Criteria

- All Epics A–E complete with passing tests
- **Demonstration:** Harvest 5 machines, show certificates in SQL, re-run harvest and show LastVerified update
- No P1 unresolved risks
- Product Owner approval to proceed to Phase 2

---

## 10. Traceability Links

| Area | Reference |
|------|-----------|
| Architecture | `architecture-overview.md` (Core Workflows §2) |
| ADRs | 002 (Hexagonal), 006 (MERGE), 007 (Surrogate Key) |
| Data Model | `data-model-design.md` (Certificates, Machines, MachineCertificates) |

---

## 11. Open Questions

| ID | Question | Resolution Path |
|----|----------|----------------|
| Q1 | Test environment SQL Server version? | Confirm with DBAs (target 2016+) |
| Q2 | Initial target machine list? | Gather 5-10 stable, non-production servers |

---

## 12. Reporting Cadence

- Weekly: Epic progress, blockers
- End of Phase: Demo + retrospective

---

## 13. Next Steps (Pre-Kickoff)

1. Provision test SQL Server
2. Identify 5-10 target machines for pilot harvest
3. Validate WinRM connectivity to target machines
4. Begin Domain model implementation (Epic A)
