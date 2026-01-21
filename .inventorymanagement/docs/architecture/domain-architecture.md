# Domain Architecture

**Last Updated:** November 20, 2025
**Status:** Draft – Sections marked TODO will be completed during Phase 1.
**Owner:** Carl R. Yeager

---

## Purpose & Design Intent

The **Domain layer** contains pure business logic with **zero dependencies** on external systems, frameworks, or infrastructure. It defines:

- Core entities (Certificate, Machine, MachineCertificate)
- Business rules and invariants (thumbprint normalization, expiry logic)
- Port interfaces for external adapters (defined here, implemented in Infrastructure)
- Domain services for complex logic that doesn't belong in entities

**Design Philosophy:** Domain is the **architectural truth**—it dictates contracts; all other layers adapt to it.

---

## Architectural Responsibilities

### What Domain Owns

- Certificate data structures and lifecycle states
- Machine registration and environment classification
- Thumbprint normalization and validation rules
- Expiry evaluation logic (Critical/Warning/Valid states)
- Port interface definitions (contracts for Infrastructure adapters)

### What Domain Does NOT Own

- SQL persistence implementation (Infrastructure responsibility)
- WinRM remoting logic (Infrastructure responsibility)
- Configuration management (Agent responsibility)
- HTTP clients, file I/O, external API calls (Infrastructure responsibility)

---

## Design Constraints

1. **No External Dependencies:** Domain project references **ZERO** NuGet packages (except test frameworks in Domain.Tests)
2. **No I/O Operations:** No file access, network calls, database queries
3. **No Framework Dependencies:** No ASP.NET, Entity Framework, Dapper, etc.
4. **Pure C#:** Plain classes, interfaces, records—no attributes, no magic

---

## Key Abstractions

**TODO:** Fill in after implementation (Week 2-3 of Phase 1)

**Expected Entities:**

- `Certificate` (aggregate root)
- `Machine` (aggregate root)
- `MachineCertificate` (binding entity)
- `HarvestExecution` (run tracking entity)

**Expected Value Objects:**

- `Thumbprint` (if complexity justifies; otherwise plain `string`)
- `FQDN` (machine identifier with validation)
- `PathLocation` (certificate store path)

**Expected Domain Services:**

- `CertificateNormalizer` (thumbprint formatting, SAN extraction)
- `ExpiryEvaluator` (compute Critical/Warning/Valid from ValidTo date)
- `MachineEnvironmentDetector` (derive environment from FQDN suffix)

**Expected Port Interfaces:**

- `ICertificateStoreReader` (contract for WinRM, F5, Repository adapters)
- `IIngestionWriter` (contract for SQL persistence)
- `IF5RestClient` (contract for F5 API adapter)
- `ITeamsNotifier` (contract for Teams webhook publisher)

---

## Invariants & Design Rules

### Certificate Invariants

1. **Thumbprint Normalization:** Always uppercase, no delimiters
   - Input: `ab:cd:ef:12:34`
   - Output: `ABCDEF1234`
2. **ValidTo > ValidFrom:** Certificate validity period must be positive
3. **SANs Non-Empty for Wildcards:** If `Subject` contains `*`, SANs must have at least one entry
4. **Thumbprint Length:** Exactly 40 characters (SHA-1) or 64 characters (SHA-256)

### Machine Invariants

1. **Hostname Format:** Must be non-empty alphanumeric string (e.g., `SERVER01`, `WEB-PROD-03`)
2. **FQDN Optional:** Can be NULL; if present, must contain at least one dot (e.g., `server.domain.com`)
3. **Environment Values:** Limited to `DEV`, `TEST`, `INTG`, `UAT`, `PROD`, `DEMO`, `Unknown` (strict enum)
4. **LastSeen >= FirstSeen:** Machine lifecycle timestamps must be sequential

### MachineCertificate Invariants

1. **PathLocation Required:** Cannot be NULL (e.g., `LocalMachine\My`)
2. **BindingContext Validity:** If present, must be valid JSON
3. **Soft Delete Grace Period:** If `DeletedAt` set, must be >= `DateDiscovered`

**Database Enforcement:** For database-level constraints (CHECK constraints, unique keys, NOT NULL columns) implementing these invariants, see `data-model-design.md` § Invariants & Constraints.

---

## Collaboration Patterns

**TODO:** Add sequence diagrams after implementation

**Expected Interactions:**

1. **Certificate Harvest:**

   ```
   Application.HarvestUseCase
     → Domain.ICertificateStoreReader (port)
       → Infrastructure.WinRmCollector (adapter)
     → Domain.CertificateNormalizer (service)
     → Domain.IIngestionWriter (port)
       → Infrastructure.SqlServerPersistence (adapter)
   ```

2. **Machine Registration:**

   ```
   Application.RegisterMachineUseCase
     → Domain.MachineEnvironmentDetector (service)
     → Domain.IIngestionWriter (port)
       → Infrastructure.SqlServerPersistence (adapter - MERGE upsert)
   ```

---

## Failure & Resilience Design

### Domain Layer Error Handling

**Philosophy:** Domain **validates** but does NOT handle infrastructure failures.

**Validation:**

- Throw `ArgumentException` for invalid thumbprints (wrong length, invalid characters)
- Throw `InvalidOperationException` for business rule violations (e.g., `ValidTo < ValidFrom`)

**Infrastructure Failures (NOT handled here):**

- SQL connection failures → Infrastructure layer responsibility
- WinRM timeout → Infrastructure layer responsibility
- Network errors → Infrastructure layer responsibility

**Example:**

```csharp
public class Certificate
{
    public string Thumbprint { get; }

    public Certificate(string thumbprint, ...)
    {
        if (string.IsNullOrWhiteSpace(thumbprint))
            throw new ArgumentException("Thumbprint cannot be null or empty", nameof(thumbprint));

        if (thumbprint.Length != 40 && thumbprint.Length != 64)
            throw new ArgumentException("Thumbprint must be 40 (SHA-1) or 64 (SHA-256) characters", nameof(thumbprint));

        Thumbprint = CertificateNormalizer.NormalizeThumbprint(thumbprint);
    }
}
```

---

## Testing Strategy

### Unit Test Scope

**What to Test:**

- Entity constructors validate invariants
- Domain services produce correct outputs (normalization, expiry evaluation)
- Port interfaces are correctly defined (compile-time verification)

**What NOT to Test:**

- Infrastructure adapter implementations (tested in Infrastructure.Tests)
- Database MERGE logic (tested in Infrastructure.Tests with Testcontainers)
- WinRM remoting (tested in Infrastructure.Tests with mocks)

**Example Test:**

```csharp
[Fact]
public void Certificate_NormalizesThumbprint_OnConstruction()
{
    var cert = new Certificate("ab:cd:ef:12:34...", ...);
    Assert.Equal("ABCDEF1234...", cert.Thumbprint);
}

[Theory]
[InlineData("invalid")]
[InlineData("")]
[InlineData("123")]  // Too short
public void Certificate_ThrowsArgumentException_ForInvalidThumbprint(string thumbprint)
{
    Assert.Throws<ArgumentException>(() => new Certificate(thumbprint, ...));
}
```

---

## Extension Points

### Adding New Certificate Sources

**Pattern:** Define new port interface in Domain, implement adapter in Infrastructure.

**Example: Azure Key Vault Certificates**

1. **Define Port:**

   ```csharp
   public interface IAzureKeyVaultReader
   {
       Task<Certificate[]> ListCertificatesAsync(string vaultUri, CancellationToken ct);
   }
   ```

2. **No Domain Changes Required:** Entity models (Certificate, Machine) remain unchanged

### Adding New Entity Properties

**Safe Additions (Non-Breaking):**

- Add nullable properties to existing entities
- Add new computed properties (e.g., `IsExpiringSoon`)
- Add new domain services (e.g., `ComplianceEvaluator`)

**Breaking Changes (Require Migration):**

- Change primary key structure (affects Infrastructure persistence)
- Remove existing properties (breaks Infrastructure adapters)
- Change invariant rules (may invalidate existing data)

---

## Design Trade-offs

### Value Objects vs. Primitive Types

**Decision (Deferred):** Start with primitive `string` for Thumbprint; refactor to value object if validation logic becomes complex.

**Rationale:**

- YAGNI: Don't create value objects until second use case appears
- Simplicity: `string` is easier to serialize/deserialize
- Future-proof: Can refactor to value object without breaking Infrastructure layer (encapsulated in Domain)

### Domain Services vs. Entity Methods

**Guideline:**

- **Entity Methods:** Logic that operates on single entity state (e.g., `cert.IsExpired()`)
- **Domain Services:** Logic that requires external data or crosses entity boundaries (e.g., `ExpiryEvaluator.Evaluate(cert, currentTime)`)

**Example:**

```csharp
// Entity method (encapsulated state)
public class Certificate
{
    public bool HasPrivateKey { get; }
    public bool CanBeUsedForSigning() => HasPrivateKey && KeyUsages.Contains("DigitalSignature");
}

// Domain service (external dependency: current time)
public class ExpiryEvaluator
{
    public ExpiryStatus Evaluate(Certificate cert, DateTime currentTime)
    {
        var daysUntilExpiry = (cert.ValidTo - currentTime).Days;
        return daysUntilExpiry switch
        {
            < 0 => ExpiryStatus.Expired,
            <= 30 => ExpiryStatus.Critical,
            <= 60 => ExpiryStatus.Warning,
            _ => ExpiryStatus.Valid
        };
    }
}
```

---

## Change Impact Guidelines

### When to Modify Domain

**Triggers:**

- New business rule discovered (e.g., "Certificates in Production must be 2048-bit minimum")
- New entity property required (e.g., "Track certificate revocation status")
- New port interface needed (e.g., "Integrate with LDAP for user certificates")

**Impact Analysis:**

1. **Entity Changes:** May require database migration (coordinate with Infrastructure)
2. **Port Interface Changes:** May require Infrastructure adapter updates
3. **Invariant Changes:** May invalidate existing data (require data migration)

### When NOT to Modify Domain

**Anti-Patterns:**

- Adding SQL-specific annotations (belongs in Infrastructure)
- Adding HTTP client configuration (belongs in Infrastructure)
- Adding logging logic (belongs in Agent or Infrastructure)
- Adding framework-specific attributes (violates pure C# principle)

---

## Related Documents

- **Architecture Overview:** `architecture-overview.md`
- **ADRs:** `architectural-decisions.md` (especially ADR-002, ADR-007)
- **Data Model:** `data-model-design.md` (schema design rationale)
- **Application Architecture:** `application-architecture.md` (use case orchestration)
- **Infrastructure Architecture:** `infrastructure-architecture.md` (adapter implementations)
