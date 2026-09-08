<#
.SYNOPSIS
    Grants (or revokes) a maker's ability to *see* one consumer's event
    Custom API (the "On Flow Requested (<Consumer>)" business event) by
    sharing (or unsharing) that specific record with them.

.DESCRIPTION
    This only does something useful for a user who holds the "Restricted
    Maker (Basic CustomAPI Read)" role (see New-RestrictedMakerRole.ps1)
    INSTEAD OF the standard "Environment Maker" role - Environment Maker's
    Global-depth Read on customapi means a maker already sees every event
    regardless of sharing, so sharing/unsharing has no visible effect for
    them (Dataverse privilege grants are cumulative - the highest depth
    always wins across every role a user holds).

    This is unrelated to, and does not replace, Add-CallerRoleMembers.ps1, which
    controls who may INVOKE the trigger (<prefix>_RunFlow[_Consumer], and now also
    <prefix>_OnFlowRequested[_Consumer] directly). This script controls who can SEE
    that consumer's EVENT Custom API in the trigger picker as a maker building a
    flow. A user can hold invoke rights without visibility rights, or vice versa -
    they are deliberately independent axes. See docs/PERMISSIONS.md for the full
    caller-vs-maker breakdown.

    Whether Power Automate's own trigger picker UI actually reflects this
    sharing (versus resolving its dropdown via an elevated/service identity
    that ignores it) is not verified end-to-end - only the underlying
    Dataverse table-level read is confirmed restricted. See
    docs/PERMISSIONS.md#manual-verification-procedure to confirm the picker
    itself honors it.

.EXAMPLE
    .\Grant-EventVisibility.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer TeamC -Users alice@contoso.com

.EXAMPLE
    Remove visibility instead of granting it:
    .\Grant-EventVisibility.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer TeamC -Users alice@contoso.com -Remove
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [Parameter(Mandatory)] [string] $Consumer,          # e.g. "TeamC" - "Default" means the unsuffixed event
    [Parameter(Mandatory)] [string[]] $Users,           # UPNs / email addresses (systemuser.domainname)
    [string] $PublisherPrefix = "flowtrig",          # must match the prefix this environment was deployed with
    [switch] $Remove                                     # revoke instead of grant
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "DvHelper.psm1") -Force

function Write-Step($message) { Write-Host ">> $message" -ForegroundColor Cyan }
function Write-Ok($message)   { Write-Host "   OK: $message" -ForegroundColor Green }
function Write-Skip($message) { Write-Host "   SKIP: $message" -ForegroundColor DarkYellow }

$token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null
$dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }

$eventName = if ($Consumer -eq "Default") { "$($PublisherPrefix)_OnFlowRequested" } else { "$($PublisherPrefix)_OnFlowRequested_$Consumer" }

Write-Step "Resolving event Custom API '$eventName'"
$eventId = Find-DataverseRecordId @dv -EntitySetName "customapis" -IdField "customapiid" -Filter "uniquename eq '$eventName'"
if (-not $eventId) {
    throw "No Custom API named '$eventName' exists in $EnvironmentUrl yet. Run Deploy-FlowTriggerSolution.ps1 first (consumer '$Consumer' must be in its consumers.json)."
}
Write-Ok "Event Custom API id: $eventId"

$targetRef = @{ "@odata.type" = "Microsoft.Dynamics.CRM.customapi"; customapiid = $eventId }

foreach ($upn in $Users) {
    Write-Step "User '$upn'"

    $userId = Find-DataverseRecordId @dv -EntitySetName "systemusers" -IdField "systemuserid" -Filter "domainname eq '$upn'"
    if (-not $userId) {
        Write-Host "   MISSING: no systemuser found with domainname '$upn' in this environment - skipping (they may need to sign in once, or check the UPN spelling)" -ForegroundColor Red
        continue
    }

    # Idempotency check: is this record already shared with this user? The
    # shared principal's id comes back under Principal.ownerid, per
    # RetrieveSharedPrincipalsAndAccess's actual response shape.
    $shared = Invoke-Dataverse @dv -Method GET -Path "RetrieveSharedPrincipalsAndAccess(Target=@p1)?@p1={'@odata.id':'customapis($eventId)'}"
    $alreadyShared = $shared.PrincipalAccesses | Where-Object { $_.Principal.ownerid -eq $userId }

    if ($Remove) {
        if (-not $alreadyShared) {
            Write-Skip "'$upn' does not have visibility into '$Consumer's event - nothing to remove"
            continue
        }
        Invoke-Dataverse @dv -Method POST -Path "RevokeAccess" -Body @{
            Target  = $targetRef
            Revokee = @{ "@odata.type" = "Microsoft.Dynamics.CRM.systemuser"; systemuserid = $userId }
        } | Out-Null
        Write-Ok "Revoked '$upn's visibility into '$Consumer's event"
    }
    else {
        if ($alreadyShared) {
            Write-Skip "'$upn' already has visibility into '$Consumer's event"
            continue
        }
        Invoke-Dataverse @dv -Method POST -Path "GrantAccess" -Body @{
            Target          = $targetRef
            PrincipalAccess = @{
                Principal  = @{ "@odata.type" = "Microsoft.Dynamics.CRM.systemuser"; systemuserid = $userId }
                AccessMask = "ReadAccess"
            }
        } | Out-Null
        Write-Ok "Granted '$upn' visibility into '$Consumer's event (ReadAccess on $eventName)"
    }
}

Write-Host ""
Write-Host "Reminder: this only affects makers holding 'Restricted Maker (Basic CustomAPI Read)'" -ForegroundColor DarkYellow
Write-Host "instead of the standard 'Environment Maker' role - see New-RestrictedMakerRole.ps1." -ForegroundColor DarkYellow
