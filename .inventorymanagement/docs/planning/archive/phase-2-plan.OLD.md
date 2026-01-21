# Phase 2 Plan – F5 & Repository Integration

**Last Updated:** November 20, 2025
**Status:** Draft – Pending Phase 1 Exit
**Owner:** Carl R. Yeager
**Phase Window:** Weeks 9–14 (target)

---
## 1. Scope
Add F5 LTM SSL profile and certificate repository (CIFS share) as new certificate sources while preserving Phase 1 stability.
- F5 REST client (profiles, virtual servers → certificate associations)
- Repository PFX enumeration & metadata extraction (file hash, validity, key usage)
- Unified normalization pipeline for new sources
- Extended SourceType enum and ingestion logic (no schema changes expected)
- Resilience enhancements (F5 circuit breaker per ADR‑003 pattern extension)
- Buffer replay validation under multi-source load

Out of scope: WebUI, compliance engine, scheduled task inventory.

---
## 2. Objectives
| ID | Objective | Success Metric |
|----|-----------|----------------|
| O1 | Harvest F5 SSL profiles | ≥95% success across target devices under rate limit |
| O2 | Repository ingestion | 100% readable PFX files ingested; failures logged with cause |
| O3 | Source parity | New sources follow same soft delete & normalization rules |
| O4 | Performance | Harvest duration increase ≤ +20% vs Phase 1 baseline |
| O5 | Resilience | Circuit breaker trips & recovers correctly (observed in test) |
| O6 | Traceability | F5 and Repository operations correlated via HarvestExecutionId |

---
## 3. Deliverables
| Deliverable | Description | Acceptance |
|-------------|-------------|------------|
| D1 | F5 REST client adapter | Auth, pagination, rate limiting, profile→cert mapping |
| D2 | Repository file scanner | Enumerate PFX files + extract thumbprint & validity |
| D3 | Unified ingestion updates | New SourceType values pass through MERGE logic |
| D4 | Resilience extensions | Circuit breaker, differentiated retry policies |
| D5 | Extended logging | Source-specific BindingContext population |
| D6 | Ops runbook addendum | F5 credential rotation & repository access troubleshooting |

---
## 4. Work Breakdown Structure
### Epic A: F5 REST Integration
- A1: Define IF5RestClient usage contract (per ADR‑001)
- A2: Implement auth + session handling
- A3: Enumerate SSL profiles & map to certificates
- A4: Rate limiting & retry policies (Polly)
- A5: Unit + integration tests (mock handlers)

### Epic B: Repository Scanner
- B1: File enumeration (recursive share path)
- B2: PFX load & metadata extraction
- B3: Error classification (permission vs corrupt file)
- B4: BindingContext JSON structure definition
- B5: Unit tests (valid/invalid samples)

### Epic C: Ingestion Pipeline Updates
- C1: Extend SourceType enum & mapping
- C2: Adapt MachineCertificates MERGE (no structural change)
- C3: Verify soft delete unaffected

### Epic D: Resilience & Observability
- D1: Circuit breaker instrumentation
- D2: Additional metrics (F5 failure rate, repository read errors)
- D3: Teams alerts for source-specific thresholds

### Epic E: Operations & Documentation
- E1: Credential rotation procedure (Key Vault)
- E2: Repository access validation script
- E3: Runbook updates

---
## 5. Dependencies & Sequencing
| Order | Dependency | Reason |
|-------|------------|-------|
| 1 | Phase 1 exit criteria met | Stability baseline required |
| 2 | F5 client core | Enables SSL profile harvesting |
| 3 | Repository scanner | Parallel development after F5 skeleton |
| 4 | Ingestion pipeline updates | After both collectors produce sample data |
| 5 | Resilience extensions | Leverages observed failure patterns |
| 6 | Ops documentation | Finalize once behavior validated |

---
## 6. Estimates
| Epic | Size | Notes |
|------|------|-------|
| A | L | External API + rate limiting complexity |
| B | M | PFX parsing + error handling |
| C | S | Minor enum & pipeline adjustments |
| D | S | Circuit breaker reuse + metrics |
| E | XS | Documentation only |

---
## 7. Risks
| ID | Risk | Likelihood | Impact | Mitigation |
|----|------|-----------|--------|-----------|
| R6 | F5 API schema variance | Medium | Medium | Device sampling + JSON schema validation |
| R7 | PFX password-protected files | Medium | Low | Skip with log; future enhancement for secure password store |
| R8 | Rate limiting misconfiguration | Low | High | Observability metrics + adjustable config |
| R9 | Repository network latency | Medium | Medium | Batching + async enumeration |

---
## 8. Acceptance Criteria
- F5 profiles mapped to certificates with BindingContext including virtual server
- Repository certificates appear with SourceType Repository and proper PathLocation
- Circuit breaker observed in controlled failure test & resets correctly
- Performance within +20% duration threshold

---
## 9. Exit Criteria
- Objectives O1–O6 satisfied across 3 harvest cycles
- No unresolved P1 risks (R6–R9 mitigated or deferred with note)
- Runbook updated and reviewed

---
## 10. Traceability
| Area | Reference |
|------|-----------|
| Architecture | `architecture-overview.md` (Extension Strategy) |
| ADRs | 001 (WinRM context), 003 (SQLite), 004 (Soft Delete), 007 (Surrogate Key) |
| Data Model | `data-model-design.md` (MachineCertificates BindingContext) |
| Resilience | Circuit breaker & retry strategy sections |

---
## 11. Open Questions
| ID | Question | Resolution Path |
|----|----------|----------------|
| Q4 | Need SSL profile to virtual server mapping edge cases? | Sample export from staging F5 |
| Q5 | Repository file naming conventions standard? | Survey current share contents Week 9 |

---
## 12. Reporting
- Weekly: F5 success rate, repository ingestion count
- Daily (initial weeks): API error rate snapshot

---
## 13. Next Steps (Pre-Kickoff)
1. Inventory F5 devices & credentials readiness
2. Confirm repository share path & permissions
3. Prepare mock JSON payloads for testing
