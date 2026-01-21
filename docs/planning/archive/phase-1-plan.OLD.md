# Phase 1 Plan – Core Certificate Collection

**Last Updated:** November 20, 2025
**Status:** Draft – Pending Kickoff
**Owner:** Carl R. Yeager
**Phase Window:** Weeks 1–8 (target)

---

## 1. Scope

In-scope capabilities required to deliver a production‑usable OS/IIS certificate inventory foundation:
- Domain model implementation (Certificate, Machine, MachineCertificate, supporting services)
- Machine discovery via Active Directory sync (dedicated background worker – ADR‑009)
- WinRM OS certificate harvesting (LocalMachine stores: My, Root, CA, AuthRoot)
- IIS binding certificate extraction (https bindings -> thumbprint mapping)
- Machine dynamic registration (MERGE pattern) and environment classification
- SQL persistence layer (ADO.NET MERGE upserts + basic indexing)
- Harvest execution tracking + structured logging
- Soft delete lifecycle (DeletedAt flag, 90‑day grace period – ADR‑004)
- Thumbprint normalization + expiry status computation

Out of scope (deferred to later phases): F5 collection, Repository CIFS reading, WebUI, alert subscriptions, compliance engine.

---

## 2. Objectives

| ID | Objective | Success Metric |
|----|-----------|----------------|
| O1 | Sync machines from AD | Machines table populated with ≥95% of AD servers; daily sync operational |
| O2 | Harvest OS certs reliably | ≥99% successful WinRM sessions across target list (non-firewalled) |
| O3 | Deduplicate certificates | Thumbprint uniqueness maintained; no duplicate rows after 10 consecutive harvests |
| O4 | Track machine lifecycle | Machines table accurately reflects FirstSeen/LastSeen for ≥95% active servers |
| O5 | Implement soft delete | Orphaned bindings retained for full 90‑day window; no premature purges |
| O6 | Provide traceability | Each harvest has Start/End, RecordCount, ErrorCount logged; correlation via HarvestExecutionId |
| O7 | Resilience baseline | SQL outage buffered (SQLite) with ≤5% data delay, zero data loss after replay |

---

## 3. Deliverables

| Deliverable | Description | Acceptance |
|-------------|-------------|------------|
| D1 | Domain project & tests | All invariants enforced; 80% domain service coverage |
| D2 | Machine discovery worker | AD sync worker; LDAP query + filtering; daily schedule |
| D3 | WinRM certificate collector | Parallel (≤10 sessions) with retry & normalization |
| D4 | IIS binding collector | Harvest IIS https bindings; populate BindingContext JSON |
| D5 | SQL persistence adapters | MERGE statements for Certificates, Machines, MachineCertificates |
| D6 | Soft delete workflow | DeletedAt set on missing bindings; recovery logic clears flag |
| D7 | HarvestExecution tracking | Table + logging integration + correlation id flow |
| D8 | SQLite buffer (conditional) | Configurable toggle; successful replay into SQL |
| D9 | Phase 1 Ops Runbook | Basic operational procedures (restart service, manual re-harvest) |

---

## 4. Work Breakdown Structure (Epics → Tasks)

### Epic A: Domain Model Implementation

- A1: Implement entity classes (Certificate, Machine, MachineCertificate)
- A2: Implement normalization & expiry evaluator services
- A3: Define port interfaces (ICertificateStoreReader, IIngestionWriter, ITeamsNotifier placeholder)
- A4: Unit tests for invariants & services

### Epic B: Persistence Layer

- B1: Create schema migration scripts (initial tables + indices)
- B2: Implement ADO.NET MERGE commands
- B3: Implement repository abstractions & mapping
- B4: Integration tests with local SQL Server / Testcontainers

### Epic C: WinRM & IIS Collection

- C1: Implement WinRM session handling (retry + throttling)
- C2: Enumerate OS certificate stores & map to domain
- C3: Implement IIS binding enumeration (Get-WebBinding)
- C4: Normalize thumbprints & merge machine discovery step
- C5: Parallel execution orchestration (SemaphoreSlim)

### Epic D: Harvest Execution & Logging

- D1: Implement HarvestExecution table + model
- D2: Inject correlation id through logging pipeline
- D3: Structured Serilog sink configuration (console, file, SQL)
- D4: Summary log + metrics emission on completion

### Epic E: Soft Delete Lifecycle

- E1: Detection of missing bindings vs previous state
- E2: Apply DeletedAt and IsDeleted flags
- E3: Recovery logic if reappears within grace period
- E4: (Optional) Manual override script for false positives

### Epic F: Resilience Buffer (Conditional)

- F1: Implement SQLite persistence abstraction
- F2: Replay job for buffered records
- F3: Health metric for buffer size & age

### Epic G: Ops & Runbook

- G1: Document manual harvest trigger procedure
- G2: Document rotating logs & troubleshooting WinRM failures
- G3: Basic diagnostic script (verify connectivity to sample target)

### Epic H: Machine Discovery Worker

- H1: Implement MachineDiscoveryWorker BackgroundService (ADR-009)
- H2: LDAP query for AD computer objects (objectClass=computer)
- H3: Application-side filtering (OS=Server, exclude patterns, OU exclusions)
- H4: MERGE into Machines table with soft delete resurrection
- H5: Configuration for sync interval, include/exclude lists
- H6: Unit tests for filtering logic; integration test with test AD

---

## 5. Sequencing & Dependencies

| Order | Dependency | Reason |
|-------|-----------|--------|
| 1 | Domain entities/services | Foundation for all other layers (ADR‑002) |
| 2 | Schema & MERGE infrastructure | Required before collectors can persist |
| 3 | Machine discovery worker | Populates Machines table for harvesting targets (ADR‑009) |
| 4 | WinRM collector core | Provides initial certificate data to test persistence |
| 5 | IIS collector | Builds on established WinRM patterns |
| 6 | HarvestExecution tracking | Wraps collection lifecycle once base harvest stable |
| 7 | Soft delete workflow | Requires historical persisted data to compare |
| 8 | SQLite buffer | Added after baseline reliability measured |
| 9 | Ops runbook | Consolidate after features complete |

---

## 6. Estimates (T-Shirt)

| Epic | Size | Notes |
|------|------|-------|
| A | M | Some domain refinements expected |
| B | L | MERGE tuning + integration tests |
| C | L | WinRM complexities + IIS nuances |
| D | S | Logging patterns straightforward |
| E | M | Requires diffing previous harvest state |
| F | S | Optional toggle; limited scope |
| G | XS | Documentation only |
| H | M | AD integration + filtering logic + resurrection |

---

## 7. Risks & Mitigations (Extract for Risk Register)

| ID | Risk | Likelihood | Impact | Mitigation |
|----|------|-----------|--------|-----------|
| R1 | WinRM throttling causes timeouts | Medium | High | Adaptive backoff + session pooling |
| R2 | IIS binding enumeration inconsistency | Medium | Medium | Fallback command variants; test on sample set |
| R3 | Incorrect soft delete marking | Low | High | Grace period before hard delete (ADR-004); manual resurrection available |
| R4 | SQLite file corruption | Low | Medium | WAL mode + automated integrity check |
| R5 | Schema performance issues (MERGE locks) | Medium | Medium | Batch MERGE + proper indices + isolation level tuning |

---

## 8. Acceptance Criteria

- All Epics A–H implemented with passing tests
- Machine discovery worker populates Machines table from AD (≥95% coverage)
- Harvest of pilot server set (<10) completes in <2 minutes
- Production-scale dry run (simulation or subset) projects <30-minute full harvest
- Soft delete flags appear when bindings not found in harvest (per ADR-004)
- Replay from SQLite buffer reinserts 100% of staged rows
- Domain test coverage ≥80%; integration test suite green

---

## 9. Exit Criteria

- Reliability metric (successful harvest %) meets O1 over 3 consecutive runs
- Data model stable (no pending mandatory schema changes)
- Runbook published and reviewed
- No P1 unresolved risks; mitigations implemented or deferred with ADR justification

---

## 10. Traceability Links

| Area | Reference |
|------|-----------||
| Architecture Overview | `architecture-overview.md` (Core Workflows 1–3) |
| ADRs | 001 (WinRM), 002 (Hexagonal), 003 (SQLite), 004 (Soft Delete), 006 (MERGE), 007 (Surrogate Key), 009 (Machine Discovery) |
| Data Model | `data-model-design.md` (Certificates, Machines, MachineCertificates) |
| Resilience | `architecture-overview.md` Resilience Architecture section |

---

## 11. Open Questions

| ID | Question | Resolution Path |
|----|----------|----------------|
| Q1 | Need IIS version matrix for binding extraction reliability? | Gather sample from 3 IIS versions during Week 2 |
| Q2 | Minimum SQL Server version for computed columns strategy? | Confirm with DBAs (target 2016+) |
| Q3 | Buffer retention limit (days vs size)? | Decide after initial outage simulation |

---

## 12. Change Control

Adjustments to scope or exit criteria require: Product Owner + Architect review, ADR if architectural.

---

## 13. Reporting Cadence

- Weekly status summary (Epics progress, risk changes)
- Daily harvest success rate metric during stabilization (Weeks 5–6)

---

## 14. Next Steps

Kickoff Checklist:
1. Confirm target machine list availability
2. Validate WinRM connectivity baseline script
3. Provision SQL schema (migration script execution)
4. Start Domain implementation (Epic A)
