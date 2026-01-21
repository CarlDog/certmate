# Release Management

**Last Updated:** November 20, 2025
**Status:** Draft
**Owner:** Carl R. Yeager

---
## 1. Purpose
Define versioning, branching, deployment, and rollback procedures for Inventory Management lifecycle across phases.

---
## 2. Versioning Strategy
- **Semantic Base:** MAJOR.MINOR.PATCH (e.g., 2.1.0)
- **Phase Alignment:** Increment MINOR at phase completion
  - v2.0.0: Phase 1 (Foundation & Basic OS Harvest)
  - v2.1.0: Phase 2 (Scale & Resilience)
  - v2.2.0: Phase 3 (Machine Discovery & Lifecycle)
  - v2.3.0: Phase 4 (F5 & Repository Integration)
  - v2.4.0: Phase 5 (WebUI & Reporting)
- **Patch Releases:** Bug fixes / performance improvements without schema change
- **Schema Changes:** Require migration script + bump MINOR unless backward compatible

---
## 3. Branching Model
| Branch | Purpose | Rules |
|--------|---------|-------|
| `main` | Stable production code | Tagged releases only; protected |
| `develop` | Aggregation of completed features | Auto CI build/test |
| `feature/*` | Isolated feature work | Rebase on `develop` frequently |
| `hotfix/*` | Production urgent fixes | Branch from `main`, merge back to `main` + `develop` |
| `release/*` | Stabilization before tag | No new features; only fixes & docs |

---
## 4. Environments
| Env | Purpose | Data | Deployment |
|-----|--------|------|-----------|
| Dev | Active development | Synthetic + partial real | CI auto on `develop` |
| Staging | Pre-production validation | Sanitized prod snapshot | Manual promote from `release/*` |
| Prod | Live operations | Full | Tagged release deploy |

---
## 5. Deployment Process
1. Create `release/x.y.0` branch from `develop`
2. Run full CI (build, tests, formatting, security scan)
3. Perform manual exploratory harvest test in Staging
4. Finalize release notes & verify migration script order
5. Tag `vX.Y.0` on `release` and merge to `main`
6. Deploy artifacts (service binaries + migrations) via runbook
7. Post-deploy validation (harvest execution + log sanity)

---
## 6. Rollback Strategy
- **Trigger Conditions:** Harvest failure rate spike > threshold, migration error, critical unhandled exceptions
- **Actions:**
  - Stop service
  - Restore pre-deploy database backup (if schema change)
  - Redeploy previous tag artifact
  - Re-enable service & monitor
- **Data Preservation:** Buffer pending rows before stop; ensure no data loss

---
## 7. Release Checklist
| Item | Completed |
|------|-----------|
| All tests green (unit + integration) |  |
| Lint & formatting pass |  |
| Security scan (dependency + static) |  |
| Migration scripts reviewed & tested |  |
| Release notes drafted |  |
| Rollback validated in staging |  |
| Monitoring thresholds updated |  |

---
## 8. Artifacts
- Binaries: Agent service, module assemblies
- Scripts: Migration SQL, health check, rollback scripts
- Docs: Release notes, runbook updates

---
## 9. Governance
- Release approval: Architect + Product Owner
- Emergency hotfix approval: Ops lead + Architect

---
## 10. Metrics
- Mean time between releases (goal: ≤8 weeks)
- Change failure rate (goal: <10%)
- Mean time to recovery (goal: <2 hours)

---
## 11. Related Documents
- `phase-1-plan.md`, `phase-2-plan.md`, `phase-3-plan.md`, `phase-4-plan.md`, `phase-5-plan.md`
- `implementation-roadmap.md` (Phase Structure Evolution)
- `risk-register.md`
- `dependency-map.md`
