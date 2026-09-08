# FlowTriggerToolkit

A tenant-agnostic PowerShell module for provisioning, operating, and **governing** the
synchronous Dataverse flow-trigger pattern documented in this repo's root
[README.md](../../README.md) and [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md).
Every function wraps the same Dataverse Web API calls already used by the
individual `deploy\*.ps1` scripts one level up - this module exists to give an operator
a single, discoverable, `Get-Help`-able surface instead of needing to know which of a
dozen loose scripts to run in which order, in which tenant.

**Compatibility**: every function runs unchanged on both **Windows PowerShell 5.1**
(.NET Framework) and **PowerShell 7+** (.NET/.NET Core), tested against a real
Dataverse environment under both engines. No version-specific cmdlets, operators
(`??`, ternary `?:`, `&&`/`||`), or BCL types (e.g. `SocketsHttpHandler`, which only
exists on .NET Core) are used anywhere in this module.

## Install

```powershell
Import-Module .\FlowTriggerToolkit.psd1
```

Requires `..\DvHelper.psm1` (imported automatically) and Azure CLI, signed in to the
target tenant:
```powershell
az login
az account set --subscription "<subscription tied to the target Dataverse tenant>"
```
`New-FlowTriggerEnvironment` additionally requires the Power Platform CLI, signed in to
the same tenant (`pac auth create`).

## Quick start: brand new tenant, from zero

```powershell
# 1. (Optional) provision a fresh environment for this solution
$envUrl = New-FlowTriggerEnvironment -Name "Contoso Flow Trigger" -Type Production

# 2. Deploy the whole solution: publisher, solution, flowtrig_flowresult table, the
#    two-stage plug-in (RunFlowDispatcher at PreValidation + RunFlowMainOperation as
#    Main Operation), the business-event catalog, and every consumer in consumers.json
Install-FlowTriggerSolution -EnvironmentUrl $envUrl

# 3. Turn on native Dataverse auditing for governance (who created/changed/deleted
#    what, and when)
Enable-FlowTriggerAuditing -EnvironmentUrl $envUrl

# 4. Onboard one new consumer at a time (a single, independently reviewable action -
#    no need to hand-edit a JSON file for a one-off addition)
Add-FlowTriggerConsumer -EnvironmentUrl $envUrl -Consumer Finance

# 5. Grant a caller access to invoke a consumer's trigger
Grant-FlowTriggerCallerAccess -EnvironmentUrl $envUrl -Consumer Default -Users alice@contoso.com

# 6. One-time per real flow: after a real person has interactively consented to a
#    Dataverse connection in the portal (this one step cannot be automated - see
#    docs/ARCHITECTURE.md), wire up the actual worker flow
New-FlowTriggerWorkerFlow -EnvironmentUrl $envUrl -Consumer Default -ConnectionName <connection-name> -Activate

# 7. Prove it end-to-end
Test-FlowTriggerConsumer -EnvironmentUrl $envUrl -Consumer Default

# 8. Anytime later: full access + health/drift audit report
Get-FlowTriggerAccessReport -EnvironmentUrl $envUrl | Format-Table
Get-FlowTriggerDeploymentStatus -EnvironmentUrl $envUrl | Format-Table
Get-FlowTriggerAuditLog -EnvironmentUrl $envUrl | Format-Table
```

## Function reference

| Function | Purpose |
|---|---|
| `New-FlowTriggerEnvironment` | Provisions a brand-new Power Platform environment (`pac admin create` wrapper) |
| `Install-FlowTriggerSolution` | Full idempotent solution deploy from a consumers.json-shaped config |
| `Get-FlowTriggerConsumer` | Lists every consumer currently deployed |
| `Add-FlowTriggerConsumer` | Onboards exactly ONE new consumer - a single, auditable, reviewable change |
| `New-FlowTriggerWorkerFlow` | Creates/activates a real worker flow for one consumer (needs a pre-consented connection) |
| `Grant-FlowTriggerCallerAccess` / `Revoke-FlowTriggerCallerAccess` | Caller-access grant/revoke - the per-consumer privilege that gates both invoking the trigger and direct calls to its event API |
| `New-FlowTriggerRestrictedMakerRole` | Creates the Basic-depth-CustomAPI-read maker role (trigger-picker visibility restriction prerequisite) |
| `Grant-FlowTriggerMakerVisibility` / `Revoke-FlowTriggerMakerVisibility` | Grants/revokes a maker's ability to see an event in the trigger picker |
| `Test-FlowTriggerConsumer` | Calls a consumer's trigger and prints the result (supports `-ImpersonateUpn` for isolation proof) |
| `Get-FlowTriggerLoadTestPhaseBreakdown` | After a load test, isolates WHERE time is going: dispatch (event raised → flow starts), the flow's own execution, or poll-detect + respond |
| `Enable-FlowTriggerAuditing` | Turns on Dataverse's native audit history for the tables that matter here |
| `Get-FlowTriggerAuditLog` | Reads that audit history back, combined and chronological |
| `Get-FlowTriggerAccessReport` | **The** governance artifact - who currently has caller-invoke and picker-visibility access, per consumer |
| `Get-FlowTriggerDeploymentStatus` | Health/drift check - confirms the exact plug-in/stage/type configuration this pattern depends on is actually in place |

## Governance model this toolkit supports

- **Least privilege by construction**: every consumer gets its own dedicated
  privilege via a marker table - `Grant-/Revoke-FlowTriggerCallerAccess` never
  grants more than "may invoke this one specific consumer."
- **Two independent axes**: who may *invoke* a trigger (`Grant-FlowTriggerCallerAccess`)
  vs. who may *see/build against* its event in the flow designer
  (`Grant-FlowTriggerMakerVisibility`) are deliberately separate - a user can hold
  either without the other. See docs/PERMISSIONS.md for the full Caller vs Maker
  breakdown.
- **One-change-at-a-time onboarding**: `Add-FlowTriggerConsumer` lets a new consumer be
  added as a single, independently reviewable action (e.g. tied to one change ticket),
  rather than requiring a bulk redeploy from a hand-edited config file.
- **Live, queryable access snapshot**: `Get-FlowTriggerAccessReport` is the
  authoritative "who can do what, right now" artifact - export it (`Export-Csv`) as
  evidence for an access review.
- **Durable history via native platform auditing**: `Enable-FlowTriggerAuditing` +
  `Get-FlowTriggerAuditLog` give a real, tamper-evident change history (who
  created/updated/deleted which Custom API, role, or worker flow, and when) using
  Dataverse's own audit subsystem - not a bespoke logging mechanism this toolkit would
  otherwise have to build and maintain itself.
- **Drift detection**: `Get-FlowTriggerDeploymentStatus` catches configuration drift
  (e.g. a consumer whose PreValidation step or `AllowedCustomProcessingStepType` isn't
  correctly in place) proactively, rather than waiting for a ~100+ second timeout to
  surface it in production - see
  [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md#two-stage-plug-in-design)
  for why that specific configuration matters.

### Known platform limitations (not fixable by this toolkit)

- Dataverse does **not** natively audit `systemuserroles_association` (security-role
  membership) or shared-record access grants (`GrantAccess`/`RevokeAccess`) at the row
  level. `Get-FlowTriggerAccessReport`'s live snapshot is the authoritative way to see
  *current* caller-access grants; pair this toolkit with your own change-ticket/pipeline
  process if you need a durable history of *those specific* grants over time.
- `customapi` frequently reports `IsAuditEnabled.CanBeChanged = false` - a platform-side
  restriction `Enable-FlowTriggerAuditing` detects and skips (with a clear warning)
  rather than failing.
- `role` and `workflow` entity metadata can fail `Enable-FlowTriggerAuditing`'s required
  full-definition PUT with a `ClusterMode` validation error in non-clustered
  organizations - a known Dataverse Web API metadata round-trip inconsistency for these
  two specific system entities, isolated so it doesn't block auditing being enabled on
  the others. See that function's own help (`Get-Help Enable-FlowTriggerAuditing -Full`)
  for the exact errors observed and a possible workaround.
- **This solution is deployed as an *unmanaged* solution per environment** (matching
  the rest of this repo). For a fully governed ALM pipeline (dev → test → prod
  promotion via managed solutions), export it with `pac solution export --managed` /
  `pac solution pack` from a completed dev environment and import it downstream instead
  of re-running `Install-FlowTriggerSolution` per environment - this toolkit does not
  currently wrap that workflow.
