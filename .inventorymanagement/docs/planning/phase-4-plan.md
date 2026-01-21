# Phase 4 Plan – F5 & Repository Integration

**Last Updated:** November 20, 2025
**Status:** Draft – Pending Phase 3 Exit
**Owner:** Carl R. Yeager
**Phase Window:** Weeks 13–17 (target)

---

## 1. Scope

Add **F5 LTM SSL profiles** and **certificate repository (CIFS share)** as new certificate sources while preserving existing stability:

**In Scope:**
- F5 REST client (profiles, virtual servers → certificate associations)
- F5 authentication + session handling (token-based)
- Rate limiting & circuit breaker for F5 API (Polly policies)
- Repository PFX enumeration (recursive CIFS share scan)
- PFX metadata extraction (thumbprint, validity, key usage, file hash)
- Extended SourceType enum (OS, IIS, F5, Repository)
- BindingContext JSON for F5 metadata (VirtualServer, SSLProfile, Partition)
- Source-specific logging and metrics
- Ops runbook addendum (F5 credential rotation, repository access troubleshooting)

**Out of Scope (Deferred to Phase 5):**
- WebUI
- Alert subscriptions (Teams webhook integration deferred)

---

## 2. Objectives

| ID | Objective | Success Metric |
|----|-----------|----------------|
| O1 | F5 harvest operational | ≥95% success across target F5 devices under rate limit |
| O2 | Repository ingestion | 100% readable PFX files ingested; failures logged with cause |
| O3 | Source parity | New sources follow same soft delete & normalization rules |
| O4 | Performance maintained | Harvest duration increase ≤+20% vs Phase 3 baseline |
| O5 | Resilience validated | Circuit breaker trips & recovers correctly (observed in test) |
| O6 | Traceability | F5 and Repository operations correlated via HarvestExecutionId |

---

## 3. Deliverables

| Deliverable | Description | Acceptance |
|-------------|-------------|------------|
| D1 | F5 REST client adapter | Auth, session handling, rate limiting, profile→cert mapping |
| D2 | F5 circuit breaker | Polly policy (trip after 5 failures, 30s cooldown) |
| D3 | Repository file scanner | Enumerate PFX files recursively + extract metadata |
| D4 | SourceType enum extension | OS, IIS, F5, Repository values |
| D5 | BindingContext for F5 | JSON structure (VirtualServer, SSLProfile, Partition, Destination) |
| D6 | Source-specific logging | F5 API errors, repository read errors with context |
| D7 | Ops runbook addendum | F5 credential rotation (Key Vault), repository access validation |

---

## 4. Work Breakdown Structure

### Epic A: F5 REST Integration

- A1: Define IF5RestClient port interface (per ADR-001)
- A2: Implement F5RestClient adapter (auth + token refresh)
- A3: Enumerate SSL profiles (/mgmt/tm/ltm/profile/client-ssl)
- A4: Map SSL profiles to certificates (cert property extraction)
- A5: Enumerate virtual servers (/mgmt/tm/ltm/virtual)
- A6: Associate SSL profiles with virtual servers
- A7: Populate BindingContext JSON (VirtualServer, SSLProfile, Partition)
- A8: Unit tests with mock HTTP responses
- A9: Integration test with staging F5 device

### Epic B: F5 Resilience

- B1: Implement Polly rate limiting policy (1 req/sec per device)
- B2: Implement circuit breaker (trip after 5 consecutive failures, 30s cooldown)
- B3: Configure retry policy (3 attempts, exponential backoff)
- B4: Add F5-specific metrics (API success rate, circuit breaker trips)
- B5: Integration test with fault injection (simulated F5 downtime)

### Epic C: Repository Scanner

- C1: Implement RepositoryPfxReader adapter (ICertificateStoreReader)
- C2: Enumerate PFX files recursively (CIFS share access)
- C3: Load PFX file (X509Certificate2.CreateFromFile)
- C4: Extract thumbprint, validity, key usage, file hash
- C5: Error classification (permission denied vs corrupt file)
- C6: Populate BindingContext JSON (FilePath, FileSize, FileHash, LastModified)
- C7: Unit tests with valid/invalid/password-protected samples
- C8: Integration test with test CIFS share

### Epic D: Ingestion Pipeline Updates

- D1: Extend SourceType enum (OS, IIS, F5, Repository)
- D2: Update MachineCertificates MERGE logic (no schema changes needed)
- D3: Verify soft delete unaffected by new sources
- D4: Add SourceType to logging context
- D5: Integration test (all 4 sources → deduplication working)

### Epic E: Operations & Documentation

- E1: Document F5 credential rotation procedure (Key Vault)
- E2: Create repository access validation script (test CIFS connectivity)
- E3: Document F5 troubleshooting (rate limit, circuit breaker, auth errors)
- E4: Document repository troubleshooting (permission errors, corrupt files)
- E5: Update ops runbook with new source-specific procedures

---

## 5. Sequencing & Dependencies

| Order | Epic | Reason |
|-------|------|--------|
| 1 | A (F5 Integration) | Core F5 harvesting capability |
| 2 | B (F5 Resilience) | Depends on F5 client implementation |
| 3 | C (Repository Scanner) | Parallel development after F5 skeleton |
| 4 | D (Ingestion Updates) | After both collectors produce sample data |
| 5 | E (Ops) | Finalize once behavior validated |

---

## 6. Estimates

| Epic | Size | Notes |
|------|------|-------|
| A | L | External API + profile/virtual server mapping complexity |
| B | S | Polly policy reuse from Phase 2 |
| C | M | PFX parsing + error handling |
| D | S | Minor enum & pipeline adjustments |
| E | XS | Documentation only |

**Total:** ~2 Large equivalents (5-week phase, includes buffer for F5 API complexity)

---

## 7. Risks & Mitigations

| ID | Risk | Likelihood | Impact | Mitigation |
|----|------|-----------|--------|-----------|
| R12 | F5 API schema variance across devices | Medium | Medium | Device sampling + JSON schema validation |
| R13 | PFX password-protected files | Medium | Low | Skip with log; future enhancement for secure password store |
| R14 | Rate limiting misconfiguration | Low | High | Observability metrics + adjustable config |
| R15 | Repository network latency | Medium | Medium | Batching + async enumeration |

---

## 8. Acceptance Criteria

- F5 profiles mapped to certificates with BindingContext including virtual server
- Repository certificates appear with SourceType=Repository and PathLocation=file path
- Circuit breaker observed in controlled failure test & resets correctly
- Performance within +20% duration threshold vs. Phase 3 baseline
- Soft delete works correctly for all 4 sources
- No unresolved P1 risks

---

## 9. Exit Criteria

- All Epics A–E complete with passing tests
- **Demonstration:** Full harvest (OS, IIS, F5, Repository), circuit breaker recovery, soft delete across all sources
- Ops runbook reviewed and validated
- Product Owner approval to proceed to Phase 5

---

## 10. Traceability Links

| Area | Reference |
|------|-----------|
| Architecture | `architecture-overview.md` (Extension Strategy) |
| ADRs | 001 (WinRM context), 003 (SQLite), 004 (Soft Delete), 007 (Surrogate Key) |
| Data Model | `data-model-design.md` (SourceType enum, BindingContext) |
| Phase 1-3 | Build on foundation + lifecycle |

---

## 11. Open Questions

| ID | Question | Resolution Path |
|----|----------|----------------|
| Q7 | F5 SSL profile to virtual server mapping edge cases? | Sample export from staging F5 during Week 13 |
| Q8 | Repository file naming conventions standard? | Survey current share contents Week 13 |

---

## 12. Reporting Cadence

- Weekly: F5 success rate, repository ingestion count
- Daily (Weeks 16-17): F5 API error rate snapshot during stabilization

---

## 13. Next Steps (Pre-Kickoff)

1. Inventory F5 devices & confirm credentials readiness
2. Confirm repository share path & permissions
3. Prepare mock F5 JSON payloads for testing
4. Begin F5 REST client implementation (Epic A)
