# Phase 3 Plan – WebUI & Reporting

**Last Updated:** November 20, 2025
**Status:** Draft – Pending Phase 2 Exit
**Owner:** Carl R. Yeager
**Phase Window:** Weeks 15–20 (target)

---

## 1. Scope

Deliver an ASP.NET Core WebUI for visibility, querying, and reporting over the unified certificate/machine inventory.
- Read-only UI (search, filters, expiry dashboards)
- Reporting generation (CSV/JSON export, scheduled summary)
- Basic alert subscription management (Teams channels mapping)
- Role-based access (internal AD groups / Windows auth integration)
- Performance baseline & paging for large datasets

Out of scope: Write operations (manual overrides), compliance rule authoring engine (future phase).

---

## 2. Objectives

| ID | Objective | Success Metric |
|----|-----------|----------------|
| O1 | Provide searchable inventory | Query returns first page < 2s under load |
| O2 | Expiry dashboard | Shows counts per status (Valid/Warning/Critical/Expired) updated each harvest |
| O3 | Export capability | CSV export completes < 10s for 10k rows |
| O4 | Alert subscription management | Users can configure Teams channel per expiry severity |
| O5 | Security | Authenticated access only; no anonymous endpoints |
| O6 | Stability | No unhandled exceptions in 1-week pilot |

---

## 3. Deliverables

| Deliverable | Description | Acceptance |
|-------------|-------------|------------|
| D1 | WebUI project scaffold | Shares Domain + Infrastructure assemblies |
| D2 | Inventory search pages | Filtering by FQDN, thumbprint, expiry status |
| D3 | Dashboard view | Aggregated metrics + trend charts |
| D4 | Export service | Server-side CSV generation w/ streaming |
| D5 | Alert subscription storage | Schema/table for subscriptions + Teams webhook mapping |
| D6 | Auth integration | Windows auth / AD group role mapping |
| D7 | Operational docs | Deployment + upgrade guide |

---

## 4. Work Breakdown Structure

### Epic A: WebUI Foundation

- A1: Project creation + DI wiring (reuse composition patterns)
- A2: Layout, navigation, base CSS (simple)
- A3: Auth configuration (Windows/Negotiate)

### Epic B: Search & Query

- B1: Repository query services (paging, sorting)
- B2: Controllers/UI for certificate & machine lists
- B3: Expiry status filter logic

### Epic C: Dashboard & Metrics

- C1: Aggregation query (group by ExpiryStatus)
- C2: Trend data (last N HarvestExecutions)
- C3: Chart rendering (lightweight library)

### Epic D: Export

- D1: Service for CSV streaming
- D2: Large dataset pagination & memory profiling
- D3: Integration tests (performance threshold)

### Epic E: Alert Subscriptions

- E1: Schema extension (Subscriptions table)
- E2: Read-only UI for viewing existing subscriptions (full CRUD deferred to post-Phase 3)
- E3: Teams webhook integration test

### Epic F: Hardening & Ops

- F1: Error page, logging enrichment (user context)
- F2: Load test (baseline concurrency)
- F3: Runbook updates

---

## 5. Dependencies & Sequencing

| Order | Dependency | Reason |
|-------|------------|-------|
| 1 | Phase 2 completion | Complete dataset sources needed |
| 2 | WebUI scaffold | Base for all UI epics |
| 3 | Search & Query | Enables data validation early |
| 4 | Dashboard | Requires aggregation logic built on query layer |
| 5 | Export | Depends on stable paging queries |
| 6 | Alert subscriptions | Requires Teams integration confidence |
| 7 | Hardening & Ops | Final polish & stability tasks |

---

## 6. Estimates

| Epic | Size | Notes |
|------|------|-------|
| A | M | New project scaffolding |
| B | M | Query complexity moderate |
| C | S | Simple counts & charts |
| D | M | Streaming + performance testing |
| E | S | Minimal schema + UI |
| F | S | Hardening tasks |

---

## 7. Risks

| ID | Risk | Likelihood | Impact | Mitigation |
|----|------|-----------|--------|-----------|
| R10 | Query performance degradation | Medium | High | Index tuning & paging strictness |
| R11 | Auth configuration issues | Low | High | Early test in staging domain |
| R12 | Large export memory pressure | Medium | Medium | Streamed writes + chunked retrieval |
| R13 | Dashboard over-fetching | Low | Medium | Cached aggregation results |

---

## 8. Acceptance Criteria

- All objectives O1–O6 met in staging pilot
- Export handles 25k row test without timeout
- Dashboard reflects most recent harvest within 5 minutes

---

## 9. Exit Criteria

- Pilot adoption sign-off (stakeholder review)
- Operational runbook updated for WebUI
- No P1 unresolved defects

---

## 10. Traceability

| Area | Reference |
|------|-----------|
| Architecture | `architecture-overview.md` (Extension & Evolution) |
| ADRs | 002 (Hexagonal), 003 (SQLite buffering context), 008 (Phased delivery) |
| Data Model | `data-model-design.md` (ExpiryStatus & HarvestExecutions) |

---

## 11. Open Questions

| ID | Question | Resolution Path |
|----|----------|----------------|
| Q6 | Subscription model: user vs channel mapping? | Decide after stakeholder review |
| Q7 | Need role-based filtering (Prod vs Non-Prod)? | Evaluate security requirements |

---

## 12. Reporting

- Weekly: UI performance metrics (avg query latency)
- Post-release: Monthly adoption metrics (active users)

---

## 13. Next Steps (Pre-Kickoff)

1. Confirm hosting environment (IIS / Kestrel + reverse proxy)
2. Gather initial UI requirements (fields, filters)
3. Prepare synthetic load test plan
