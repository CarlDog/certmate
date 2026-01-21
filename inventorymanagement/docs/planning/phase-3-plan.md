# Phase 3 Plan – Machine Discovery & Lifecycle

**Last Updated:** November 20, 2025
**Status:** Draft – Pending Phase 2 Exit
**Owner:** Carl R. Yeager
**Phase Window:** Weeks 9–12 (target)

---

## 1. Scope

Add **automated machine discovery** from Active Directory and implement **soft delete lifecycle** for certificates and machines:

**In Scope:**
- MachineDiscoveryWorker BackgroundService (ADR-009 AD sync)
- LDAP query for AD computer objects (objectClass=computer)
- Application-side filtering (OS=Server, exclude patterns, OU exclusions)
- MERGE into Machines table with soft delete resurrection
- Soft delete lifecycle for MachineCertificates (detect missing certs, set DeletedAt)
- Recovery logic (clear DeletedAt if cert reappears within grace period)
- Machine-level soft delete (servers removed from AD marked inactive)
- Configuration management (include/exclude lists, sync interval, grace period)
- Manual override script for false-positive soft deletes

**Out of Scope (Deferred to Later Phases):**
- F5, Repository (Phase 4)
- WebUI (Phase 5)

---

## 2. Objectives

| ID | Objective | Success Metric |
|----|-----------|----------------|
| O1 | AD sync operational | Machines table populated with ≥95% of AD servers; daily sync working |
| O2 | Automatic discovery | New servers added to AD appear in Machines table within 24 hours |
| O3 | Soft delete working | Missing certs marked with DeletedAt within one harvest cycle |
| O4 | Recovery validated | Cert reappears → DeletedAt cleared, IsDeleted flag reset |
| O5 | Machine lifecycle | Servers removed from AD marked inactive; resurrection on re-add |
| O6 | Configuration flexibility | Include/exclude lists configurable without code change |

---

## 3. Deliverables

| Deliverable | Description | Acceptance |
|-------------|-------------|------------|
| D1 | MachineDiscoveryWorker | BackgroundService with daily schedule (configurable) |
| D2 | LDAP query logic | Query AD for computer objects with filtering |
| D3 | Application-side filters | Exclude by OU, hostname pattern, OS type |
| D4 | Machine MERGE with resurrection | Resurrect inactive machines on AD re-add |
| D5 | Soft delete detection | Compare current harvest vs. previous state |
| D6 | Recovery logic | Clear DeletedAt if cert reappears |
| D7 | Configuration | appsettings.json with sync interval, include/exclude, grace period |
| D8 | Manual override script | Clear soft delete flag for false positives |
| D9 | Ops runbook | AD sync troubleshooting, manual override procedure |

---

## 4. Work Breakdown Structure

### Epic A: Machine Discovery Worker

- A1: Implement MachineDiscoveryWorker BackgroundService (ADR-009)
- A2: LDAP query for AD computer objects (objectClass=computer)
- A3: Application-side filtering (OS=Server, exclude OUs, exclude patterns)
- A4: Extract FQDN, NetBiosName, Environment from AD attributes
- A5: MERGE into Machines table (upsert with LastSeen update)
- A6: Unit tests for filtering logic
- A7: Integration test with test AD instance

### Epic B: Machine Resurrection Logic

- B1: Detect inactive machines (servers removed from AD)
- B2: Set IsActive=0 for machines not in current AD sync
- B3: Implement resurrection (clear IsActive=0 if machine re-added to AD)
- B4: Configuration for inactivity grace period (default 90 days)
- B5: Integration test (remove machine from AD → inactive → re-add → active)

### Epic C: Certificate Soft Delete

- C1: Compare current harvest vs. previous MachineCertificates state
- C2: Detect missing certificates (present in previous, absent in current)
- C3: Set DeletedAt and IsDeleted flags for missing certs
- C4: Configuration for soft delete grace period (default 90 days)
- C5: Unit tests for detection logic
- C6: Integration test (remove cert → soft delete → verify flag set)

### Epic D: Certificate Recovery Logic

- D1: Detect reappearing certificates (DeletedAt IS NOT NULL but cert found in current harvest)
- D2: Clear DeletedAt and IsDeleted flags
- D3: Log recovery event (structured log with HarvestExecutionId)
- D4: Integration test (soft delete → re-add cert → verify recovery)

### Epic E: Configuration & Operations

- E1: Add configuration schema (sync interval, include/exclude lists, grace periods)
- E2: Create manual override script (clear soft delete flags)
- E3: Document AD sync troubleshooting (LDAP errors, timeout, incorrect filtering)
- E4: Document soft delete lifecycle (grace period, recovery, manual override)
- E5: Create diagnostic script (preview AD query results without persisting)

---

## 5. Sequencing & Dependencies

| Order | Epic | Reason |
|-------|------|--------|
| 1 | A (Discovery Worker) | Populates Machines table for lifecycle tracking |
| 2 | B (Machine Resurrection) | Depends on Discovery Worker data flow |
| 3 | C (Cert Soft Delete) | Requires historical harvest data (Phase 2 runs) |
| 4 | D (Cert Recovery) | Depends on Soft Delete detection logic |
| 5 | E (Config & Ops) | Consolidates after features validated |

---

## 6. Estimates

| Epic | Size | Notes |
|------|------|-------|
| A | M | LDAP query + filtering logic |
| B | S | Resurrection logic straightforward |
| C | M | State comparison + detection logic |
| D | S | Recovery logic mirrors soft delete |
| E | S | Configuration + documentation |

**Total:** ~2 Large equivalents (4-week phase)

---

## 7. Risks & Mitigations

| ID | Risk | Likelihood | Impact | Mitigation |
|----|------|-----------|--------|-----------|
| R8 | AD LDAP query timeout | Low | Medium | Timeout config + retry; async query patterns |
| R9 | Incorrect AD filtering logic | Medium | High | Test with sample AD data + manual validation; preview script |
| R10 | AD OU reorganization breaks filters | Low | Medium | Config-driven exclusions + monitoring; documented update procedure |
| R11 | Incorrect soft delete marking | Low | High | Grace period before hard delete (ADR-004); manual override available |

---

## 8. Acceptance Criteria

- MachineDiscoveryWorker populates Machines table from AD (≥95% coverage)
- Daily AD sync operational (configurable interval)
- New server added to AD appears in Machines table within 24 hours
- Soft delete marks missing certs with DeletedAt
- Cert reappears → DeletedAt cleared (recovery validated)
- Machine removed from AD → IsActive=0 after grace period
- Machine re-added to AD → IsActive=1 (resurrection validated)
- Manual override script clears soft delete flags

---

## 9. Exit Criteria

- All Epics A–E complete with passing tests
- **Demonstration:** AD sync, soft delete lifecycle, recovery, manual override
- Ops runbook reviewed and validated
- No P1 unresolved risks
- Product Owner approval to proceed to Phase 4

---

## 10. Traceability Links

| Area | Reference |
|------|-----------|
| Architecture | `architecture-overview.md` (Core Workflows §1, §3) |
| ADRs | 004 (Soft Delete), 006 (MERGE), 009 (Machine Discovery) |
| Data Model | `data-model-design.md` (Machines, MachineCertificates lifecycle) |
| Phase 1 | `phase-1-plan.md` (foundation entities) |
| Phase 2 | `phase-2-plan.md` (harvest tracking for state comparison) |

---

## 11. Open Questions

| ID | Question | Resolution Path |
|----|----------|----------------|
| Q5 | AD query filter criteria finalized? | Review with AD admins during Week 9 |
| Q6 | Soft delete grace period 90 days confirmed? | Validate with stakeholders (may adjust) |

---

## 12. Reporting Cadence

- Weekly: Epic progress, AD sync success rate
- Daily (Weeks 11-12): Soft delete/recovery event counts during validation

---

## 13. Next Steps (Pre-Kickoff)

1. Confirm AD access credentials (LDAP read permission)
2. Identify AD OUs to include/exclude
3. Validate LDAP query against test AD
4. Begin MachineDiscoveryWorker implementation (Epic A)
