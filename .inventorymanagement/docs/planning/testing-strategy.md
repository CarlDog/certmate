# Testing Strategy

**Last Updated:** November 20, 2025
**Status:** Draft
**Owner:** Carl R. Yeager

---
## 1. Purpose
Define multi-layer test approach mapped to hexagonal architecture ensuring correctness, reliability, and traceability.

---
## 2. Test Layers
| Layer | Scope | Tools | Isolation |
|-------|-------|-------|----------|
| Domain Unit | Entities, value logic, services | xUnit | Pure (no I/O) |
| Application Use Case | Orchestration logic | xUnit + Moq | Ports mocked |
| Infrastructure Integration | Adapters (SQL, WinRM, F5, Repository) | xUnit + Testcontainers + Mock HTTP | Real external surfaces (where feasible) |
| End-to-End Harvest | Full pipeline (subset targets) | PowerShell harness / xUnit | Staging resources |
| Performance | Harvest duration, query latency | BenchmarkDotNet / custom timers | Controlled dataset |
| Resilience | Retry, circuit breaker, buffer replay | Fault injection scripts | Isolated environment |
| Security | Auth/access (Phase 5 WebUI) | Selenium / integration | Staging WebUI |

---
## 3. Coverage Goals
| Layer | Coverage Target |
|-------|----------------|
| Domain Unit | ≥80% lines / 100% critical invariants |
| Application Use Case | ≥70% lines / all branching paths |
| Infrastructure Integration | ≥60% lines / all adapter success & failure modes |
| End-to-End | Core workflows (Machine Discovery from AD, Machine Registration, Certificate Harvest, Soft Delete) |

---
## 4. Test Data Management
- **Synthetic Certificates:** Generated with varying expiry windows
- **Machine Fixtures:** Configurable FQDN patterns (Prod/Staging/Dev)
- **F5 Mock Payloads:** Captured sample JSON + edge cases
- **Repository Samples:** Valid, password-protected, corrupted PFX files
- **Isolation:** Separate test database per run (Testcontainers)

---
## 5. Fault Injection
| Failure Mode | Injection Technique |
|--------------|--------------------|
| SQL Outage | Drop network / pause container |
| WinRM Timeout | Artificial delay wrapper |
| F5 Rate Limit | Mock 429 responses sequence |
| Repository Share Inaccessible | Remove permissions mid-run |
| Buffer Replay Error | Corrupt one staged record intentionally |

---
## 6. Performance Benchmarks
| Metric | Target |
|--------|--------|
| Harvest Duration (Phase 2 @ 300 servers) | <30 min |
| F5 Harvest Addition (Phase 4) | +≤20% duration increase |
| WebUI Query (10k rows, Phase 5) | <2s first page |
| CSV Export (25k rows, Phase 5) | <10s completion |

---
## 7. Resilience Validation
- Retry policies succeed after transient simulated failures
- Circuit breaker opens after threshold & resets post cooldown
- SQLite buffer replays 100% staged rows

---
## 8. Tooling & Automation
- CI executes unit + integration tests on PR
- Nightly scheduled performance snapshot on staging
- Weekly resilience drill (scripted fault injection)

---
## 9. Reporting
- Test coverage summaries per layer
- Flaky test detection (rerun on failure)
- Historical performance trend charts

---
## 10. Exit Criteria per Phase
| Phase | Must Pass |
|-------|-----------|
| 1 | Domain unit tests + WinRM OS integration + Basic E2E harvest (5 machines) |
| 2 | Parallel execution + IIS integration + Buffer replay + E2E harvest (50 machines) |
| 3 | Machine Discovery (AD sync) + Soft delete lifecycle + Resurrection logic |
| 4 | F5 REST integration + Repository PFX scanner + Circuit breaker validation |
| 5 | WebUI security tests + Query performance + Export performance |

---
## 11. Related Documents
- Architecture: `architecture-overview.md`
- Data Model: `data-model-design.md`
- Plans: Phase documents
