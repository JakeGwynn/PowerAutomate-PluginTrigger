<#
.SYNOPSIS
    Grants (or revokes) a consumer's "Flow Trigger Caller - <Consumer>" security role
    to one or more individual users, by UPN/email.

.DESCRIPTION
    This is the whole access-control surface for one consumer's trigger: a user with
    this role holds exactly one privilege (Read on that consumer's
    <prefix>_ep_<slug> marker table), which is the shared ExecutePrivilegeName on
    BOTH that consumer's caller Custom API (<prefix>_RunFlow[_Consumer]) and its
    event Custom API (<prefix>_OnFlowRequested[_Consumer]) - so this one grant both
    lets a user invoke the trigger and blocks anyone without it from calling the
    event API directly. No other access is granted or implied. See
    docs/PERMISSIONS.md#caller-access-who-may-invoke-the-trigger.

    Idempotent: already-assigned users are skipped (reported, not re-added).

    For a group of users that will change over time, consider creating a Dataverse
    Team instead and assigning the role to the team once (Power Platform Admin
    Center > Environments > <env> > Teams > + New team > Security roles). This
    script targets individual users directly, matching a fixed, small list.

.EXAMPLE
    .\Add-CallerRoleMembers.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer TeamA -Users alice@contoso.com,bob@contoso.com,carol@contoso.com

.EXAMPLE
    Remove access instead of granting it:
    .\Add-CallerRoleMembers.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer TeamA -Users alice@contoso.com -Remove
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [Parameter(Mandatory)] [string] $Consumer,          # e.g. "TeamA" - must match an id in consumers.json
    [Parameter(Mandatory)] [string[]] $Users,           # UPNs / email addresses (systemuser.domainname)
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

$roleName = "Flow Trigger Caller - $Consumer"
Write-Step "Resolving role '$roleName'"
$roleId = Find-DataverseRecordId @dv -EntitySetName "roles" -IdField "roleid" -Filter "name eq '$roleName'"
if (-not $roleId) {
    throw "Role '$roleName' does not exist yet in $EnvironmentUrl. Run Deploy-FlowTriggerSolution.ps1 first (consumer '$Consumer' must be in consumers.json)."
}
Write-Ok "Role id: $roleId"

foreach ($upn in $Users) {
    Write-Step "User '$upn'"

    $userId = Find-DataverseRecordId @dv -EntitySetName "systemusers" -IdField "systemuserid" -Filter "domainname eq '$upn'"
    if (-not $userId) {
        Write-Host "   MISSING: no systemuser found with domainname '$upn' in this environment - skipping (they may need to sign in once, or check the UPN spelling)" -ForegroundColor Red
        continue
    }

    # Idempotency check: is this user already associated with the role?
    $existing = Invoke-Dataverse @dv -Method GET -Path "systemusers($userId)/systemuserroles_association?`$select=roleid&`$filter=roleid eq $roleId"
    $alreadyAssigned = $existing.value -and $existing.value.Count -gt 0

    if ($Remove) {
        if (-not $alreadyAssigned) {
            Write-Skip "'$upn' does not have '$roleName' - nothing to remove"
            continue
        }
        Invoke-Dataverse @dv -Method DELETE -Path "systemusers($userId)/systemuserroles_association($roleId)/`$ref" | Out-Null
        Write-Ok "Removed '$roleName' from '$upn'"
    }
    else {
        if ($alreadyAssigned) {
            Write-Skip "'$upn' already has '$roleName'"
            continue
        }
        Invoke-Dataverse @dv -Method POST -Path "systemusers($userId)/systemuserroles_association/`$ref" -Body @{
            "@odata.id" = "$($EnvironmentUrl.TrimEnd('/'))/api/data/v9.2/roles($roleId)"
        } | Out-Null
        Write-Ok "Granted '$roleName' to '$upn'"
    }
}
