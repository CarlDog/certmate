# Agent Architecture Map

This document provides a visual map showing how the 7 specialized agents align with the hexagonal architecture and development workflow.

## Agent-to-Architecture Mapping

```
┌─────────────────────────────────────────────────────────────────────┐
│                     DEVELOPMENT WORKFLOW LAYER                      │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────┐    │
│  │  @dev-workflow Agent                                       │    │
│  │  • dotnet build/test/run                                   │    │
│  │  • Environment setup (SQL, WinRM, Azure)                   │    │
│  │  • Git workflow & commit conventions                       │    │
│  │  • Troubleshooting & diagnostics                           │    │
│  │  • Windows Service deployment                              │    │
│  └───────────────────────────────────────────────────────────┘    │
│                                                                     │
└──────────────────────┬──────────────────────────────────────────────┘
                       │
                       │ Supports all layers
                       │
┌──────────────────────┴──────────────────────────────────────────────┐
│                   PROJECT MANAGEMENT LAYER                          │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────┐    │
│  │  @phase-implementation Agent                               │    │
│  │  • Progress tracking (implementation-tracker.md)           │    │
│  │  • Phase/stage transitions (5 phases, 22 weeks)            │    │
│  │  • Blocker management & risk register                      │    │
│  │  • Acceptance criteria validation                          │    │
│  │  • Velocity tracking & reporting                           │    │
│  └───────────────────────────────────────────────────────────┘    │
│                                                                     │
└──────────────────────┬──────────────────────────────────────────────┘
                       │
                       │ Orchestrates
                       │
┌──────────────────────┴──────────────────────────────────────────────┐
│                   HEXAGONAL ARCHITECTURE                            │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │  Agent Layer (Windows Service)                            │     │
│  │  • Worker.cs - BackgroundService                          │     │
│  │  • Program.cs - DI Composition Root                       │     │
│  │  • appsettings.json - Configuration                       │     │
│  │                                                            │     │
│  │  Supported by: @application-orchestrator, @dev-workflow   │     │
│  └──────────────────────────────────────────────────────────┘     │
│                             ▲                                       │
│                             │                                       │
│  ┌──────────────────────────┴─────────────────────────────────┐   │
│  │  Application Layer                                          │   │
│  │  ┌────────────────────────────────────────────────────┐    │   │
│  │  │  @application-orchestrator Agent                    │    │   │
│  │  │  • Use cases (HarvestCertificatesUseCase)           │    │   │
│  │  │  • Orchestrators (CollectionOrchestrator)           │    │   │
│  │  │  • Commands/Queries (CQRS pattern)                  │    │   │
│  │  │  • Transaction coordination                          │    │   │
│  │  │  • Error handling & Result patterns                 │    │   │
│  │  └────────────────────────────────────────────────────┘    │   │
│  └───────────────────────┬──────────────────────────────────────┘ │
│                          │                                         │
│                          │ Depends on                              │
│                          │                                         │
│  ┌───────────────────────┴──────────────────────────────────────┐ │
│  │  Domain Layer (Pure Business Logic)                          │ │
│  │  ┌────────────────────────────────────────────────────┐      │ │
│  │  │  @domain-architect Agent                            │      │ │
│  │  │  • Entities (Certificate, Machine)                  │      │ │
│  │  │  • Domain Services (CertificateNormalizer)          │      │ │
│  │  │  • Port Interfaces (ICertificateStoreReader)        │      │ │
│  │  │  • Value Objects & Invariants                       │      │ │
│  │  │  ⚠️  ZERO external dependencies                      │      │ │
│  │  └────────────────────────────────────────────────────┘      │ │
│  └─────────────────────────▲────────────────────────────────────┘ │
│                            │                                       │
│                            │ Implements ports                      │
│                            │                                       │
│  ┌─────────────────────────┴──────────────────────────────────┐   │
│  │  Infrastructure Layer (External Adapters)                  │   │
│  │  ┌────────────────────────────────────────────────────┐    │   │
│  │  │  @infrastructure-adapter Agent                      │    │   │
│  │  │  • WinRM collectors (WinRmOSCollector)              │    │   │
│  │  │  • F5 REST clients                                  │    │   │
│  │  │  • Azure Key Vault integration                      │    │   │
│  │  │  • Polly retry policies & resilience               │    │   │
│  │  └────────────────────────────────────────────────────┘    │   │
│  │                                                              │   │
│  │  ┌────────────────────────────────────────────────────┐    │   │
│  │  │  @data-persistence Agent                            │    │   │
│  │  │  • SQL Server persistence                           │    │   │
│  │  │  • MERGE-based upserts                              │    │   │
│  │  │  • Schema design & migrations                       │    │   │
│  │  │  • Stored procedures & TVPs                         │    │   │
│  │  └────────────────────────────────────────────────────┘    │   │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                     │
└──────────────────────┬──────────────────────────────────────────────┘
                       │
                       │ Validated by
                       │
┌──────────────────────┴──────────────────────────────────────────────┐
│                       TESTING LAYER                                 │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────┐    │
│  │  @test-engineer Agent                                      │    │
│  │  • Unit tests (Domain - pure, no mocking)                  │    │
│  │  • Integration tests (Infrastructure - Testcontainers)     │    │
│  │  • Use case tests (Application - mocked ports)             │    │
│  │  • Coverage analysis (≥80% target)                         │    │
│  │  • AAA pattern (Arrange, Act, Assert)                      │    │
│  └───────────────────────────────────────────────────────────┘    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Agent Collaboration Patterns

### Pattern 1: Feature Implementation (Full Stack)

When implementing a complete feature (e.g., certificate harvesting):

```
1. @phase-implementation
   → Identify tasks from implementation tracker
   → Understand acceptance criteria

2. @domain-architect
   → Define entities (Certificate, Machine)
   → Create domain services (CertificateNormalizer)
   → Define port interfaces (ICertificateStoreReader)

3. @infrastructure-adapter
   → Implement WinRM collector (WinRmOSCollector)
   → Apply retry policies with Polly
   → Handle external system integration

4. @data-persistence
   → Design SQL schema (Certificates table)
   → Create MERGE upserts (UpsertCertificates)
   → Build stored procedures and TVPs

5. @application-orchestrator
   → Create use case (HarvestCertificatesUseCase)
   → Coordinate domain + infrastructure
   → Handle errors and transactions

6. @test-engineer
   → Write domain unit tests (no mocking)
   → Create infrastructure integration tests (Testcontainers)
   → Build application tests (mocked ports)

7. @dev-workflow
   → Run build and tests
   → Verify code quality
   → Deploy to test environment

8. @phase-implementation
   → Mark tasks complete
   → Update progress tracker
   → Validate acceptance criteria
```

### Pattern 2: Bug Fix Workflow

When fixing a production bug:

```
1. @dev-workflow
   → Review logs and diagnostics
   → Reproduce issue locally

2. @test-engineer
   → Write failing test that reproduces bug
   → Verify test fails with current code

3. [Layer-specific agent]
   → @domain-architect (if business logic bug)
   → @infrastructure-adapter (if external system bug)
   → @application-orchestrator (if orchestration bug)
   → Fix the issue

4. @test-engineer
   → Verify test now passes
   → Add additional regression tests

5. @dev-workflow
   → Run full test suite
   → Verify build clean

6. @phase-implementation
   → Document fix in tracker
   → Update risk register if needed
```

### Pattern 3: Code Review Workflow

When reviewing a pull request:

```
1. @dev-workflow
   → Checkout PR branch
   → Run build and tests locally

2. [Layer-specific agent]
   → @domain-architect → Verify domain purity, no external dependencies
   → @infrastructure-adapter → Check retry policies, error handling
   → @application-orchestrator → Validate orchestration patterns
   → @data-persistence → Review SQL performance, MERGE correctness

3. @test-engineer
   → Verify test coverage ≥80%
   → Check test quality (AAA pattern, no flaky tests)

4. @dev-workflow
   → Check code formatting (dotnet format)
   → Verify commit messages follow convention

5. @phase-implementation
   → Ensure implementation tracker updated
   → Verify acceptance criteria met
```

## Agent Expertise Matrix

| Concern                    | Primary Agent              | Secondary Agent          | Tertiary Agent             |
| -------------------------- | -------------------------- | ------------------------ | -------------------------- |
| **Business Logic**         | `domain-architect`         | `test-engineer`          | `application-orchestrator` |
| **WinRM Integration**      | `infrastructure-adapter`   | `test-engineer`          | `dev-workflow`             |
| **SQL Persistence**        | `data-persistence`         | `infrastructure-adapter` | `test-engineer`            |
| **Use Case Orchestration** | `application-orchestrator` | `domain-architect`       | `test-engineer`            |
| **Testing Strategy**       | `test-engineer`            | [layer-agent]            | `dev-workflow`             |
| **Progress Tracking**      | `phase-implementation`     | -                        | -                          |
| **Build/Deploy**           | `dev-workflow`             | `phase-implementation`   | -                          |
| **Error Handling**         | `application-orchestrator` | `infrastructure-adapter` | `domain-architect`         |
| **Performance**            | `infrastructure-adapter`   | `data-persistence`       | `application-orchestrator` |
| **Security**               | `infrastructure-adapter`   | `dev-workflow`           | `application-orchestrator` |

## Common Scenarios

### Scenario: "I'm new to the project, where do I start?"

**Agent sequence:**

1. `@dev-workflow` → Setup environment
2. `@phase-implementation` → Understand current phase/status
3. `@domain-architect` → Learn domain model
4. `@test-engineer` → Run tests to validate setup

### Scenario: "I need to implement OS certificate collection"

**Agent sequence:**

1. `@phase-implementation` → Check if this is current phase task
2. `@domain-architect` → Define ICertificateStoreReader port
3. `@infrastructure-adapter` → Implement WinRmOSCollector
4. `@test-engineer` → Create integration tests
5. `@dev-workflow` → Run and verify
6. `@phase-implementation` → Mark complete

### Scenario: "SQL queries are slow, need optimization"

**Agent sequence:**

1. `@dev-workflow` → Profile queries, collect diagnostics
2. `@data-persistence` → Analyze schema, add indexes
3. `@infrastructure-adapter` → Optimize batch sizes
4. `@test-engineer` → Add performance tests
5. `@dev-workflow` → Measure improvements

### Scenario: "Need to track expiring certificates"

**Agent sequence:**

1. `@domain-architect` → Implement ExpiryEvaluator service
2. `@data-persistence` → Create GetExpiringCertificates query
3. `@application-orchestrator` → Build SendWeeklyDigest
4. `@infrastructure-adapter` → Implement TeamsWebhookPublisher
5. `@test-engineer` → Test end-to-end workflow
6. `@dev-workflow` → Schedule as background task

### Scenario: "Phase 1 complete, ready for Phase 2"

**Agent sequence:**

1. `@phase-implementation` → Verify all Phase 1 acceptance criteria
2. `@test-engineer` → Confirm ≥80% coverage
3. `@dev-workflow` → Deploy to test environment
4. `@phase-implementation` → Generate completion report
5. `@phase-implementation` → Groom Phase 2 backlog

## Agent Communication Diagram

```
                    ┌─────────────────────┐
                    │  @phase-             │
                    │   implementation     │◄───── Tracks all progress
                    └──────────┬───────────┘
                               │
                 Coordinates all agents
                               │
         ┌─────────────────────┼──────────────────────┐
         │                     │                      │
         ▼                     ▼                      ▼
┌────────────────┐   ┌──────────────────┐   ┌───────────────┐
│  @domain-      │   │  @application-   │   │  @infra-      │
│   architect    │◄──┤   orchestrator   │──►│   structure-  │
│                │   │                  │   │   adapter     │
└────────┬───────┘   └────────┬─────────┘   └───────┬───────┘
         │                    │                     │
         │                    │                     │
         │          Defines   │  Implements         │
         │          ports     │  adapters           │
         │                    │                     │
         └────────────────────┼─────────────────────┘
                              │
                              │
                    ┌─────────┴─────────┐
                    │  @data-           │
                    │   persistence     │
                    └─────────┬─────────┘
                              │
                              │ All tested by
                              │
                    ┌─────────▼─────────┐
                    │  @test-           │
                    │   engineer        │
                    └─────────┬─────────┘
                              │
                              │ Executed via
                              │
                    ┌─────────▼─────────┐
                    │  @dev-            │
                    │   workflow        │
                    └───────────────────┘
```

## Quick Decision Tree

**"Which agent should I ask?"**

```
Is it about project tracking/progress?
├─ YES → @phase-implementation
└─ NO
    │
    Is it about build/test/deploy/environment?
    ├─ YES → @dev-workflow
    └─ NO
        │
        What layer am I working in?
        │
        ├─ src/Domain/
        │  └─ @domain-architect
        │
        ├─ src/Application/
        │  └─ @application-orchestrator
        │
        ├─ src/Infrastructure/
        │  ├─ SQL-related?
        │  │  └─ @data-persistence
        │  └─ External systems?
        │     └─ @infrastructure-adapter
        │
        └─ tests/
           └─ @test-engineer
```

---

**Last Updated**: 2025-11-21
**Total Agents**: 7
**Coverage**: All architectural layers + DevOps + Project Management
