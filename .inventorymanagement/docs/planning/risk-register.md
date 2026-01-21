# Risk Register

**Last Updated:** November 20, 2025
**Status:** Draft
**Owner:** Carl R. Yeager

---
## 1. Purpose
Central catalog of project risks across all phases with status & mitigation tracking.

---
## 2. Risk Legend
| Likelihood | Description |
|------------|-------------|
| Low | Unlikely (<25%) |
| Medium | Possible (25–60%) |
| High | Likely (>60%) |

| Impact | Description |
|--------|-------------|
| Low | Minor delay or negligible cost |
| Medium | Noticeable schedule/function impact |
| High | Major feature slip or operational incident |

---
## 3. Active Risks
| ID | Phase | Risk | Likelihood | Impact | Mitigation | Owner | Status |
|----|-------|------|-----------|--------|-----------|-------|--------|
| R1 | 1 | WinRM throttling causes timeouts | Medium | High | Adaptive backoff + pooling | Dev Lead | Open |
| R2 | 2 | IIS binding enumeration inconsistency | Medium | Medium | Command variant fallback | Dev Lead | Open |
| R3 | 3 | Incorrect soft delete marking | Low | High | Grace period before hard delete (ADR-004); manual resurrection available | Architect | Open |
| R4 | 2 | SQLite file corruption | Low | Medium | WAL mode + integrity check | Dev Lead | Open |
| R5 | 1 | MERGE locking/perf issues | Medium | Medium | Batch ops + indices | DBA | Monitoring |
| R5a | 3 | AD LDAP query timeout | Low | Medium | Timeout config + retry | Dev Lead | Open |
| R5b | 3 | Incorrect AD filtering logic | Medium | High | Test with sample AD data + manual validation | Architect | Open |
| R5c | 3 | AD OU reorganization breaks filters | Low | Medium | Config-driven exclusions + monitoring | Architect | Open |
| R6 | 4 | F5 API schema variance | Medium | Medium | Schema validation harness | Dev Lead | Open |
| R7 | 4 | Password-protected PFX files | Medium | Low | Skip + log; evaluate secure store | Architect | Open |
| R8 | 4 | Rate limiting misconfiguration | Low | High | Config tuning + metrics | Dev Lead | Open |
| R9 | 4 | Repository network latency | Medium | Medium | Async enumeration + batching | Dev Lead | Open |
| R10 | 5 | Query performance degradation | Medium | High | Index tuning + paging | Dev Lead | Open |
| R11 | 5 | Auth configuration issues | Low | High | Early staging validation | Architect | Open |
| R12 | 5 | Large export memory pressure | Medium | Medium | Streaming writes | Dev Lead | Open |
| R13 | 5 | Dashboard over-fetching | Low | Medium | Cache aggregation | Dev Lead | Open |

---
## 4. Retired Risks
| ID | Reason Retired | Date |
|----|----------------|------|
| (none yet) |  |  |

---
## 5. Escalation Criteria
- Any High/High risk moves to weekly stakeholder review
- Two or more Medium/High risks → add mitigation sprint task

---
## 6. Monitoring Cadence
- Phases 1-3: Weekly review (higher risk early phases)
- Phase 4: Bi-weekly unless High risk triggered
- Phase 5: Weekly + post-release evaluation

---
## 7. Related Documents
- `phase-1-plan.md`, `phase-2-plan.md`, `phase-3-plan.md`, `phase-4-plan.md`, `phase-5-plan.md`
- `implementation-roadmap.md` (Phase Structure Evolution)
- `release-management.md`
