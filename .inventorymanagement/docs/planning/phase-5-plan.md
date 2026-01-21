# Phase 5 Plan – WebUI & Reporting

**Last Updated:** November 20, 2025
**Status:** Draft – Pending Phase 4 Exit
**Owner:** Carl R. Yeager
**Phase Window:** Weeks 18–22 (target)

---

## 1. Scope

Deliver **ASP.NET Core WebUI** for visibility, querying, and reporting over the unified certificate/machine inventory:

**In Scope:**
- WebUI project scaffold (ASP.NET Core Razor Pages or Blazor)
- Read-only inventory search (filter by FQDN, thumbprint, expiry status, source type)
- Expiry dashboard (counts by status: Valid/Warning/Critical/Expired, trend charts)
- CSV/JSON export (streaming for large datasets)
- Basic alert subscription management (Teams channels mapping—read-only UI)
- Windows authentication integration (AD groups for role mapping)
- Performance baseline (query latency <2s, export <10s for 10k rows)
- Paging for large datasets (server-side pagination)
- Deployment guide (IIS or Kestrel + reverse proxy)

**Out of Scope (Future Enhancements):**
- Write operations (manual cert overrides, machine edits)
- Compliance rule authoring engine
- Advanced reporting (custom queries, scheduled reports)
- Full CRUD for alert subscriptions (create/update deferred)

---

## 2. Objectives

| ID | Objective | Success Metric |
|----|-----------|----------------|
| O1 | Searchable inventory | Query returns first page <2s under load |
| O2 | Expiry dashboard | Shows counts per status updated each harvest |
| O3 | Export capability | CSV export completes <10s for 10k rows |
| O4 | Alert subscription visibility | Users can view existing Teams channel subscriptions |
| O5 | Security | Authenticated access only; no anonymous endpoints |
| O6 | Stability | No unhandled exceptions in 1-week pilot |

---

## 3. Deliverables

| Deliverable | Description | Acceptance |
|-------------|-------------|------------|
| D1 | WebUI project scaffold | ASP.NET Core with shared Domain + Infrastructure assemblies |
| D2 | Inventory search pages | Filter by FQDN, thumbprint, expiry status, source type |
| D3 | Dashboard view | Aggregated metrics (counts by status) + trend charts |
| D4 | Export service | Server-side CSV generation with streaming |
| D5 | Alert subscription UI | Read-only view of existing subscriptions |
| D6 | Auth integration | Windows auth + AD group role mapping |
| D7 | Deployment guide | IIS/Kestrel setup, DB connection, auth config |

---

## 4. Work Breakdown Structure

### Epic A: WebUI Foundation

- A1: Create ASP.NET Core project (Razor Pages or Blazor)
- A2: Reference Domain + Infrastructure projects (DI composition)
- A3: Configure Kestrel or IIS hosting
- A4: Add layout, navigation, base CSS (simple, functional)
- A5: Configure Windows authentication (Negotiate)
- A6: Map AD groups to roles (Admin, ReadOnly)
- A7: Basic health check endpoint (/health)

### Epic B: Search & Query

- B1: Implement repository query services (paging, sorting, filtering)
- B2: Create certificate search page (filter by thumbprint, subject, expiry status)
- B3: Create machine search page (filter by FQDN, environment, last seen)
- B4: Implement server-side paging (page size 50, configurable)
- B5: Add expiry status filter (Valid, Warning, Critical, Expired)
- B6: Add source type filter (OS, IIS, F5, Repository)
- B7: Performance testing (query latency <2s for first page)

### Epic C: Dashboard & Metrics

- C1: Create dashboard aggregation query (GROUP BY ExpiryStatus)
- C2: Implement trend data query (last 30 HarvestExecutions)
- C3: Add chart rendering (lightweight library: Chart.js or similar)
- C4: Display certificate counts by status
- C5: Display expiry trend over time (certificates expiring per week)
- C6: Cache aggregation results (5-minute TTL)

### Epic D: Export

- D1: Implement CSV export service (streaming via CsvHelper)
- D2: Add export endpoints (/export/certificates, /export/machines)
- D3: Implement pagination for large exports (chunked retrieval)
- D4: Memory profiling (ensure <500MB memory for 25k row export)
- D5: Performance testing (export 10k rows in <10s)

### Epic E: Alert Subscriptions (Read-Only)

- E1: Create Subscriptions table schema (Teams channel URL, expiry threshold, severity)
- E2: Implement read-only UI for viewing subscriptions
- E3: Add Teams webhook test endpoint (validate URL reachable)
- E4: Document subscription creation (manual SQL insert for now)

### Epic F: Hardening & Operations

- F1: Error pages (404, 500 with user-friendly messages)
- F2: Logging enrichment (user context: username, IP, action)
- F3: Load testing (baseline concurrency: 20 concurrent users)
- F4: Security review (OWASP top 10 checklist)
- F5: Create deployment guide (IIS setup, DB connection string, auth config)
- F6: Ops runbook updates (WebUI troubleshooting, user access management)

---

## 5. Sequencing & Dependencies

| Order | Epic | Reason |
|-------|------|--------|
| 1 | A (Foundation) | Base for all UI epics |
| 2 | B (Search) | Enables data validation early |
| 3 | C (Dashboard) | Requires aggregation logic built on query layer |
| 4 | D (Export) | Depends on stable paging queries |
| 5 | E (Subscriptions) | Requires Teams integration confidence |
| 6 | F (Hardening) | Final polish & stability tasks |

---

## 6. Estimates

| Epic | Size | Notes |
|------|------|-------|
| A | M | New project scaffolding + auth |
| B | M | Query complexity moderate |
| C | S | Simple counts & charts |
| D | M | Streaming + performance testing |
| E | S | Minimal schema + UI |
| F | S | Hardening tasks |

**Total:** ~2.5 Large equivalents (5-week phase)

---

## 7. Risks & Mitigations

| ID | Risk | Likelihood | Impact | Mitigation |
|----|------|-----------|--------|-----------|
| R16 | Query performance degradation | Medium | High | Index tuning & paging strictness; query profiling |
| R17 | Auth configuration issues | Low | High | Early test in staging domain; document auth setup |
| R18 | Large export memory pressure | Medium | Medium | Streamed writes + chunked retrieval; memory profiling |
| R19 | Dashboard over-fetching | Low | Medium | Cached aggregation results (5-min TTL) |

---

## 8. Acceptance Criteria

- All objectives O1–O6 met in staging pilot
- Query returns first page <2s under load (20 concurrent users)
- Export handles 10k rows in <10s without timeout
- Dashboard reflects most recent harvest within 5 minutes
- No unhandled exceptions in 1-week pilot
- Security review passed (OWASP checklist)

---

## 9. Exit Criteria

- All Epics A–F complete with passing tests
- **Demonstration:** Search, dashboard, export, alert subscriptions (read-only)
- Pilot adoption sign-off (stakeholder review)
- Deployment guide validated (successful IIS deployment)
- Ops runbook reviewed and validated
- No P1 unresolved risks
- Product Owner approval for production release

---

## 10. Traceability Links

| Area | Reference |
|------|-----------|
| Architecture | `architecture-overview.md` (Extension & Evolution) |
| ADRs | 002 (Hexagonal—WebUI shares Domain/Infrastructure), 008 (Phased delivery) |
| Data Model | `data-model-design.md` (ExpiryStatus, HarvestExecutions, Subscriptions) |
| Phase 1-4 | Build on complete data collection foundation |

---

## 11. Open Questions

| ID | Question | Resolution Path |
|----|----------|----------------|
| Q9 | Hosting environment: IIS or Kestrel + reverse proxy? | Confirm with infrastructure team Week 18 |
| Q10 | Subscription model: user-specific or channel-only? | Decide after stakeholder review Week 19 |
| Q11 | Need role-based filtering (Prod vs Non-Prod)? | Evaluate security requirements Week 19 |

---

## 12. Reporting Cadence

- Weekly: UI performance metrics (avg query latency, export duration)
- Post-release: Monthly adoption metrics (active users, queries per day)

---

## 13. Next Steps (Pre-Kickoff)

1. Confirm hosting environment (IIS version, Kestrel support)
2. Gather initial UI requirements (stakeholder interviews: desired fields, filters)
3. Prepare synthetic load test plan (20 concurrent users baseline)
4. Begin WebUI foundation (Epic A)
