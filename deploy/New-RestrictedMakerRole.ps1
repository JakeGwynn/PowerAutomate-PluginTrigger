<#
.SYNOPSIS
    Creates (or refreshes) "Restricted Maker (Basic CustomAPI Read)" - a
    clone of the built-in Environment Maker role with exactly one change:
    Read on the customapi table is granted at Basic depth instead of Global.

.DESCRIPTION
    See docs/PERMISSIONS.md#maker-access-who-may-seebuild-a-flow-using-this-trigger.
    `customapi` is a UserOwned table, so - unlike `catalog`/`catalogassignment`,
    which are Organization-owned and can only ever be Global-depth - its Read
    privilege genuinely supports per-record ownership and sharing. The
    out-of-box Environment Maker role grants Global depth, so by default every
    maker sees every event's Custom API record regardless of ownership. This
    script produces the one thing needed to make that restrictable: a maker
    role that grants only Basic depth instead, so a maker only sees event
    Custom APIs they own or that have been explicitly shared with them (via
    Grant-EventVisibility.ps1 in this folder).

    Since Dataverse privilege grants are cumulative across every role a user
    holds (the highest depth always wins), this role must be assigned INSTEAD
    OF the standard Environment Maker role, not in addition to it - holding
    both would still resolve to Global depth.

    The underlying Dataverse table read is confirmed restricted at Basic depth;
    confirm the trigger picker's UI itself honors it with the manual test
    procedure in docs/PERMISSIONS.md#manual-verification-procedure.

    Idempotent: safe to re-run - re-creates the full privilege set each time
    (picking up anything new in Environment Maker, e.g. after a Dataverse
    platform update) while keeping the CustomAPI Read override at Basic depth.

.EXAMPLE
    .\New-RestrictedMakerRole.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [string] $RoleName = "Restricted Maker (Basic CustomAPI Read)",
    [string] $SourceRoleName = "Environment Maker"
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "DvHelper.psm1") -Force

function Write-Step($message) { Write-Host ">> $message" -ForegroundColor Cyan }
function Write-Ok($message)   { Write-Host "   OK: $message" -ForegroundColor Green }

$token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null
$dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }

Write-Step "Resolving source role '$SourceRoleName'"
$sourceRoleId = Find-DataverseRecordId @dv -EntitySetName "roles" -IdField "roleid" -Filter "name eq '$SourceRoleName'"
if (-not $sourceRoleId) {
    throw "Role '$SourceRoleName' was not found in $EnvironmentUrl."
}
Write-Ok "Source role id: $sourceRoleId"

Write-Step "Reading '$SourceRoleName' privileges"
$sourcePrivileges = (Invoke-Dataverse @dv -Method GET -Path "RetrieveRolePrivilegesRole(RoleId=$sourceRoleId)").RolePrivileges
Write-Ok "$($sourcePrivileges.Count) privileges found"

Write-Step "Resolving Read privilege on 'customapi'"
$customApiReadId = ($sourcePrivileges | Where-Object { $_.PrivilegeName -eq "prvReadCustomAPI" } | Select-Object -First 1).PrivilegeId
if (-not $customApiReadId) {
    throw "'$SourceRoleName' does not grant prvReadCustomAPI at all - nothing to restrict. Add Read on Custom API to it first, or point -SourceRoleName at a role that has it."
}
Write-Ok "prvReadCustomAPI id: $customApiReadId (forcing this one to Basic depth; leaving every other privilege untouched)"

Write-Step "Resolving/creating role '$RoleName'"
$roleId = Find-DataverseRecordId @dv -EntitySetName "roles" -IdField "roleid" -Filter "name eq '$RoleName'"
if (-not $roleId) {
    $rootBusinessUnitId = (Invoke-Dataverse @dv -Method GET -Path "businessunits?`$select=businessunitid&`$filter=parentbusinessunitid eq null&`$top=1").value[0].businessunitid
    $roleId = Invoke-Dataverse @dv -Method POST -Path "roles" -Body @{
        name = $RoleName
        "businessunitid@odata.bind" = "/businessunits($rootBusinessUnitId)"
    }
    Write-Ok "Created role ($roleId)"
} else {
    Write-Ok "Role already exists ($roleId) - refreshing its privilege set"
}

Write-Step "Applying $($sourcePrivileges.Count) privileges (in batches)"
$batchSize = 200
for ($i = 0; $i -lt $sourcePrivileges.Count; $i += $batchSize) {
    $slice = $sourcePrivileges[$i..[Math]::Min($i + $batchSize - 1, $sourcePrivileges.Count - 1)]
    $batch = $slice | ForEach-Object {
        $depth = if ($_.PrivilegeId -eq $customApiReadId) { "Basic" } else { $_.Depth }
        @{ PrivilegeId = $_.PrivilegeId; Depth = $depth }
    }
    Invoke-Dataverse @dv -Method POST -Path "roles($roleId)/Microsoft.Dynamics.CRM.AddPrivilegesRole" -Body @{ Privileges = $batch } | Out-Null
    Write-Ok "Batch $([math]::Floor($i / $batchSize) + 1) applied ($($batch.Count) privileges)"
}

Write-Host ""
Write-Host "=== '$RoleName' ready in $EnvironmentUrl ($roleId) ===" -ForegroundColor Green
Write-Host "Assign this role INSTEAD OF '$SourceRoleName' to any maker whose event-Custom-API"
Write-Host "visibility you want to restrict, then use Grant-EventVisibility.ps1 to share specific"
Write-Host "consumers' events with them."
