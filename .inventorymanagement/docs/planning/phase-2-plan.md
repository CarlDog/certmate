# Phase 2 Plan – Scale & Resilience

**Last Updated:** November 20, 2025
**Status:** Draft – Pending Phase 1 Exit
**Owner:** Carl R. Yeager
**Phase Window:** Weeks 5–8 (target)

---

## 1. Scope

Scale Phase 1's OS harvest to **production capacity** (300 servers) with production-grade resilience and add IIS binding collection:

**In Scope:**
- Parallel WinRM execution (SemaphoreSlim, max 10 concurrent sessions)
- Polly retry policies (WinRM transient failures, exponential backoff)
- IIS binding certificate extraction (Get-WebBinding → thumbprint mapping)
- HarvestExecution tracking table (run correlation, metrics)
- Structured logging enhancements (Serilog SQL sink, correlation IDs)
- SQLite buffer (conditional failover for SQL outages)
- Replay job (buffered records → SQL Server)
- Ops runbook updates (troubleshooting, log queries, buffer management)

**Out of Scope (Deferred to Later Phases):**
- Machine discovery from AD (Phase 3)
- Soft delete lifecycle (Phase 3)
- F5, Repository (Phase 4)
- WebUI (Phase 5)

---

## 2. Objectives

| ID | Objective | Success Metric |
|----|-----------|----------------|
| O1 | Production scale | 300-machine harvest completes in <30 minutes |
| O2 | Reliability | ≥99% successful WinRM sessions (non-firewalled targets) |
| O3 | IIS coverage | IIS bindings harvested with BindingContext JSON populated |
| O4 | Resilience validated | Injected WinRM timeout recovers via retry; SQL outage triggers buffer |
| O5 | Traceability | All harvest operations correlated via HarvestExecutionId |
| O6 | Buffer replay | Buffered records replay successfully after SQL recovery |

---

## 3. Deliverables

| Deliverable | Description | Acceptance |
|-------------|-------------|------------|
| D1 | Parallel WinRM orchestration | SemaphoreSlim-based throttling, max 10 concurrent |
| D2 | Polly retry policies | Exponential backoff for WinRM transient failures |
| D3 | IIS binding collector | Harvest HTTPS bindings, populate BindingContext JSON |
| D4 | HarvestExecution table | Run tracking with Start/End/RecordCount/ErrorCount |
| D5 | Serilog SQL sink | Structured logging to InventoryLogs table |
| D6 | SQLite buffer | Conditional persistence for SQL outages |
| D7 | Replay job | Background task to upload buffered records |
| D8 | Ops runbook | Troubleshooting WinRM failures, buffer management, log queries |

---

## 4. Work Breakdown Structure

### Epic A: Parallel Execution & Retry

- A1: Implement SemaphoreSlim-based WinRM throttling (max 10 concurrent)
- A2: Add Polly retry policy (3 attempts, exponential backoff)
- A3: Configure concurrency limit via appsettings.json
- A4: Unit tests for throttling logic
- A5: Integration test with simulated WinRM timeouts

### Epic B: IIS Binding Collection

- B1: Implement IISBindingCollector adapter (ICertificateStoreReader)
- B2: Enumerate IIS sites via PowerShell (Get-WebBinding)
- B3: Extract certificate thumbprints from HTTPS bindings
- B4: Populate BindingContext JSON (SiteName, IPAddress, Port, HostHeader)
- B5: Unit tests with mock IIS data
- B6: Integration test on real IIS server

### Epic C: Harvest Execution Tracking

- C1: Create HarvestExecutions table (schema migration)
- C2: Implement HarvestExecution entity + repository
- C3: Inject HarvestExecutionId into logging pipeline (Serilog enricher)
- C4: Emit harvest summary (Start, End, Duration, RecordCount, ErrorCount)
- C5: Add indices (IX_HarvestExecutions_StartTime)

### Epic D: Enhanced Logging

- D1: Configure Serilog SQL sink (InventoryLogs table)
- D2: Add correlation ID enricher (HarvestExecutionId)
- D3: Structured logging for WinRM sessions (target machine, duration, result)
- D4: Log query examples in runbook (find errors by HarvestExecutionId)

### Epic E: SQLite Buffer & Replay

- E1: Implement SqliteBuffer abstraction (PendingUploads table)
- E2: Serialize harvest results to JSON on SQL connection failure
- E3: Implement replay job (BackgroundService or scheduled task)
- E4: Mark uploaded records (UploadedAt timestamp)
- E5: Auto-purge uploaded records >7 days old
- E6: Health metric for buffer size/age
- E7: Integration test (SQL outage → buffer → replay)

### Epic F: Operations & Hardening

- F1: Document WinRM troubleshooting (connectivity, timeout, throttling)
- F2: Document buffer management (query pending records, manual replay trigger)
- F3: Document log queries (errors by machine, harvest duration trends)
- F4: Create diagnostic script (test WinRM connectivity across server list)
- F5: Load test with 50-machine subset

---

## 5. Sequencing & Dependencies

| Order | Epic | Reason |
|-------|------|--------|
| 1 | A (Parallel + Retry) | Enables production-scale harvest |
| 2 | B (IIS) | Builds on WinRM patterns from Phase 1 + Epic A |
| 3 | C (Tracking) | Required before logging enhancements |
| 4 | D (Logging) | Depends on HarvestExecution correlation |
| 5 | E (Buffer) | Added after baseline reliability established |
| 6 | F (Ops) | Consolidates after features validated |

---

## 6. Estimates

| Epic | Size | Notes |
|------|------|-------|
| A | M | Parallelization + retry patterns |
| B | M | IIS enumeration + JSON structure |
| C | S | Table + basic tracking logic |
| D | S | Serilog configuration + enrichers |
| E | M | SQLite integration + replay job |
| F | S | Documentation + diagnostics |

**Total:** ~2.5 Large equivalents (4-week phase)

---

## 7. Risks & Mitigations

| ID | Risk | Likelihood | Impact | Mitigation |
|----|------|-----------|--------|-----------|
| R4 | WinRM throttling causes timeouts | Medium | High | Adaptive backoff + session pooling; configurable concurrency limit |
| R5 | IIS binding enumeration inconsistency | Medium | Medium | Fallback command variants; test on sample IIS versions |
| R6 | SQLite file corruption | Low | Medium | WAL mode + automated integrity check |
| R7 | Schema performance issues (MERGE locks) | Medium | Medium | Batch MERGE + proper indices + isolation level tuning |

---

## 8. Acceptance Criteria

- 50-machine harvest completes in <5 minutes
- Projected 300-machine harvest <30 minutes (linear extrapolation acceptable)
- IIS bindings appear with BindingContext JSON
- Injected WinRM timeout recovers via retry (observed in test)
- SQL outage triggers SQLite buffer; replay succeeds after recovery
- HarvestExecution records created for each harvest with accurate metrics
- Ops can query logs by HarvestExecutionId

---

## 9. Exit Criteria

- All Epics A–F complete with passing tests
- **Demonstration:** 50-machine harvest with IIS, injected failure recovery, buffer replay
- Load test projects <30-minute full-scale harvest
- Ops runbook reviewed and validated
- No P1 unresolved risks
- Product Owner approval to proceed to Phase 3

---

## 10. Traceability Links

| Area | Reference |
|------|-----------|
| Architecture | `architecture-overview.md` (Core Workflows, Resilience) |
| ADRs | 001 (WinRM), 002 (Hexagonal), 003 (SQLite), 006 (MERGE) |
| Data Model | `data-model-design.md` (HarvestExecutions, InventoryLogs) |
| Phase 1 | `phase-1-plan.md` (builds on foundation) |

---

## 11. Open Questions

| ID | Question | Resolution Path |
|----|----------|----------------|
| Q3 | IIS version matrix for binding extraction reliability? | Test on IIS 8.5, 10, 11 during Epic B |
| Q4 | Buffer retention limit (days vs size)? | Decide after initial outage simulation |

---

## 12. Reporting Cadence

- Weekly: Epic progress, WinRM success rate metric
- Daily (Weeks 7-8): Harvest duration trends during load testing

---

## 13. Next Steps (Pre-Kickoff)

1. Expand target machine list to 50 servers (mix of OS-only and IIS)
2. Validate IIS servers accessible via WinRM
3. Provision SQLite test environment
4. Begin parallel execution implementation (Epic A)
