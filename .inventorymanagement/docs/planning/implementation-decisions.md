# Implementation Decisions Log

**Last Updated:** November 20, 2025
**Status:** Draft
**Owner:** Carl R. Yeager

---
## Purpose
Track tactical (non-architectural) implementation decisions that do not warrant full ADRs but need traceability.

---
## Decision Entry Template
```markdown
### ID: IMP-XXX – Short Title
**Date:** YYYY-MM-DD
**Context:** What prompted the decision (issue, constraint, observation)
**Options Considered:**
1. Option A – pros/cons
2. Option B – pros/cons
**Decision:** Chosen option + concise rationale
**Impact:** Code areas / processes affected
**Revisit Criteria:** Conditions to trigger reconsideration
**Linked ADRs:** (if any)
```

---
## Initial Entries
### ID: IMP-001 – Thumbprint Normalization Helper Location
**Date:** 2025-11-20
**Context:** Need centralized logic for removing delimiters & uppercasing.
**Options Considered:**
1. Static helper in Certificate entity (violates SRP, bloats entity)
2. Dedicated CertificateNormalizer service (promotes testability, separation)
**Decision:** Option 2 – Service class.
**Impact:** Domain services folder; unit tests target service.
**Revisit Criteria:** If logic expands (wildcard SAN validation) consider value object.
**Linked ADRs:** ADR-002 (Hexagonal purity)

### ID: IMP-002 – WinRM Concurrency via SemaphoreSlim
**Date:** 2025-11-20
**Context:** Limit parallel sessions to avoid resource exhaustion & throttling.
**Options Considered:**
1. Parallel.ForEach with degree of parallelism (less granular control)
2. SemaphoreSlim + manual task scheduling
**Decision:** Option 2 – Fine control & future dynamic adjustment.
**Impact:** Collector implementation uses injected concurrency setting.
**Revisit Criteria:** If scaling beyond 300 servers; evaluate channel-based scheduler.
**Linked ADRs:** ADR-001 (Central orchestrator)

---
## Future Entries (Placeholders)
- IMP-003 – SQLite WAL Mode Configuration
- IMP-004 – IIS Binding Command Selection Strategy
- IMP-005 – F5 Rate Limiting Approach

---
## Related Documents
- `architectural-decisions.md`
- Phase plans
