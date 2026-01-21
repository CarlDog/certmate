# Metrics & KPIs

**Last Updated:** November 20, 2025
**Status:** Draft
**Owner:** Carl R. Yeager

---
## 1. Purpose
Define quantitative measures aligned to architectural goals (Reliability, Traceability, Performance, Extensibility, Operability).

---
## 2. Core Operational Metrics
| Metric | Definition | Goal | Phase Introduced |
|--------|-----------|------|------------------|
| Harvest Success Rate | Successful target harvests / total targets | ≥99% | 1 |
| Harvest Duration | Total time per full cycle | <30 min (300 servers) | 2 |
| Buffer Utilization | Rows in SQLite buffer | <500 avg | 2 |
| Expiring Certificates (Critical) | Count ValidTo ≤30 days | Trending ↓ | 1 |
| Soft Delete Recovery Rate | % soft-deleted certs recovered | TBD—baseline in Phase 3 (>10% indicates high transient rate) | 3 |
| F5 Profile Coverage | Profiles with mapped cert / total profiles | ≥95% | 4 |
| Repository Read Success | Successfully parsed PFX / total files | 100% non-protected | 4 |
| WebUI Query Latency | P95 search latency | <2s | 5 |
| Export Throughput | Rows/sec in CSV export | ≥2,500 | 5 |
| Alert Delivery Time | Time from expiry threshold to Teams alert | <5 min | 5 |

---
## 3. Reliability Sub-Metrics
| Sub-Metric | Description |
|------------|-------------|
| WinRM Failure Rate | % WinRM sessions failing after retries |
| Circuit Breaker Trips | Count per day (F5) |
| Replay Lag | Time between buffer write and replay success |

---
## 4. Traceability Metrics
| Metric | Description |
|--------|-------------|
| Log Correlation Coverage | % harvest log entries with HarvestExecutionId |
| Audit Completeness | % of lifecycle transitions (soft delete, recovery) logged |

---
## 5. Performance Metrics Detail
| Metric | Collection Method |
|--------|------------------|
| Harvest Duration | Start/End timestamps comparison |
| Query Latency | Middleware timing + percentile aggregation |
| Export Throughput | Row count / elapsed timer |

---
## 6. Data Quality Metrics
| Metric | Goal |
|--------|-----|
| Duplicate Certificates | 0 duplicates outside test fixtures |
| Invalid Thumbprints | 0 persisted invalid lengths |
| Missing PathLocation | 0 rows with NULL PathLocation |

---
## 7. Alerting Thresholds (Initial)
| Metric | Warning | Critical |
|--------|---------|----------|
| Harvest Success Rate | <98% | <95% |
| WinRM Failure Rate | >5% | >10% |
| Buffer Utilization | >1000 | >5000 |
| Circuit Breaker Trips (daily) | >5 | >15 |

---
## 8. Dashboard Layout (Phase 3)
Sections: Harvest Health, Expiry Risk, Source Coverage, Performance Trends, Alerts Summary.

---
## 9. Reporting Cadence
| Report | Frequency | Audience |
|--------|----------|----------|
| Harvest Summary | Daily | Ops, Dev |
| Weekly KPI Digest | Weekly | Stakeholders |
| Reliability Trends | Monthly | Architecture Review |
| Expiry Projection | Monthly | Security / Compliance |

---
## 10. Related Documents
- `testing-strategy.md`
- Phase plans
- `architecture-overview.md`
