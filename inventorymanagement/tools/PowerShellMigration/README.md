# PowerShell Migration Notes

This folder contains notes and utilities for migrating PowerShell v1.0 scripts to the C# hexagonal architecture.

## Migration Strategy

1. **Phase 0:** Analyze existing PS scripts for business logic and external dependencies
2. **Phase 1:** Map PS script functionality to C# domain entities and ports
3. **Phase 2:** Implement adapters for external systems (SQL, F5, WinRM)
4. **Phase 3:** Create use cases that replicate PS script workflows
5. **Phase 4:** Run parallel (PS and C# side-by-side) with comparison logging
6. **Phase 5:** Decommission PowerShell scripts after validation

## Script Mapping

| PowerShell Script | Domain Entities | Infrastructure Adapters | Use Case |
|-------------------|-----------------|-------------------------|----------|
| certsRepo.ps1 | Certificate | RepositoryPfxReader | HarvestRepositoryCertificates |
| f5*.ps1 | Certificate, MachineCertificate | F5RestClient | HarvestF5Certificates |
| certsOS.ps1 | Certificate | WindowsCertStoreReader | HarvestLocalCertificates |
| machineList.ps1 | Machine | (TBD - AD query adapter) | DiscoverMachines |

## Parity Testing

- Compare row counts between PS and C# ingestion
- Validate thumbprint matching
- Check for missing or extra certificates in each approach

---
Placeholder for migration utilities and comparison scripts.
