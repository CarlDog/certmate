# Application Architecture

**Last Updated:** November 20, 2025
**Status:** Draft – Sections marked TODO will be completed during Phase 1.
**Owner:** Carl R. Yeager

---

## Purpose & Design Intent

The **Application layer** orchestrates use cases by coordinating Domain entities and Infrastructure adapters. It defines the **workflow logic** without implementing external system details.

**Key Responsibility:** "What the system does" (not "how it does it").

---

## Architectural Responsibilities

### What Application Owns

- Use case orchestration (e.g., HarvestCertificatesUseCase)
- Transaction boundaries and commit points
- Error propagation and retry coordination
- Port interface definitions (contracts that Infrastructure implements)
- Command/query patterns

### What Application Does NOT Own

- Domain invariants (Domain responsibility)
- Adapter implementations (Infrastructure responsibility)
- HTTP routing, DI configuration (Agent responsibility)

---

## Design Constraints

1. **Depends on Domain Only:** No references to Infrastructure, Agent, or external frameworks
2. **No I/O Implementation:** Defines ports; Infrastructure implements adapters
3. **Stateless Use Cases:** No instance state; dependencies injected via constructor

---

## Key Abstractions

**TODO:** Populate during Phase 1 implementation (Weeks 2-4)

**Expected Use Cases:**

- `LocalCertificates` (orchestrate WinRM collection + SQL persistence)
- `RegisterMachineUseCase` (MERGE upsert for dynamic discovery)
- `VerifyMachineCertificatesUseCase` (soft delete unverified certs)

**Expected Command Handlers:**

- `ICertificateCollectionCommand`
- `IMachineRegistrationCommand`

**Expected Orchestrators:**

- `CollectionOrchestrator` (coordinates multiple collectors in parallel)

---

## Collaboration Patterns

**TODO:** Add after implementation

---

## Error & Resilience Design

**Application Layer Responsibilities:**

- Define retry policies (Polly integration points)
- Coordinate failure recovery (e.g., fallback to SQLite buffer)
- Propagate errors to Agent for logging

**NOT Application's Job:**

- Implement retry logic (Infrastructure responsibility via Polly)
- Handle specific exceptions (Infrastructure adapters do this)

---

## Testing Strategy

**TODO:** Populate during Phase 1

**Expected Tests:**

- Use case tests with mocked ports (Application.Tests)
- Verify orchestration logic without real I/O

---

## Extension Points

**TODO:** Document after initial implementation

---

## Related Documents

- **Domain Architecture:** `domain-architecture.md`
- **Infrastructure Architecture:** `infrastructure-architecture.md`

---

## Related ADRs

| ADR | Topic | Reason for Relevance |
|-----|-------|----------------------|
| 002 | Hexagonal Architecture | Establishes layering & Application dependency rules |
| 003 | Conditional SQLite Buffering | Application coordinates fallback invocation |
| 004 | Soft Delete with Grace Period | Use cases drive verification and deletion workflows |
| 006 | Machine Registration via MERGE | Use case orchestrates registration transaction boundary |
| 007 | Surrogate Key Strategy | Use case logic depends on returned surrogate IDs |
| 009 | Dedicated Discovery Worker | Separation of concerns between harvest vs discovery orchestration |
