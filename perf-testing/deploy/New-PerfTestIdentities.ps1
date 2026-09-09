<#
.SYNOPSIS
    Creates N throwaway Azure AD service principals + Dataverse Application
    Users, each granted the "Flow Trigger Caller - <Consumer>" role for the
    perf-testing deployment, to test whether spreading concurrent calls
    across multiple CALLING IDENTITIES changes the growth pattern
    Get-PerfTestBreakdown.ps1 found.

.DESCRIPTION
    Dataverse's documented service protection limits - including the
    concurrent-request limit (default 52 per web server) - are evaluated
    per authenticated USER, independently:
    https://learn.microsoft.com/power-apps/developer/data-platform/api-limits
    ("The system evaluates service protection API limits for each user.
    Each authenticated user has an independent limit."). This script creates
    the identities needed to test that directly: if the same total
    concurrency, split across more identities, stops growing the way a
    single identity's did, that confirms the bottleneck found earlier was
    genuinely per-identity admission queueing, not a whole-environment cap.

    Writes the created identities' client id/secret/tenant id to a file
    OUTSIDE this repository (default: $env:TEMP\perftest-identities.json),
    since these are real, usable credentials that must never be committed.
    Invoke-PerfTestMultiIdentityLoadTest.ps1 reads that file to acquire one
    token per identity via client_credentials.

    Idempotent by display name: re-running with the same -IdentityCount
    reuses any already-created app registrations/Application Users found by
    name, but always resets each one's secret (a prior secret can't be
    retrieved again after this script exits, so there's no way to reuse it).

.EXAMPLE
    .\New-PerfTestIdentities.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -TenantId $tenantId -IdentityCount 10
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [Parameter(Mandatory)] [string] $TenantId,
    [int] $IdentityCount = 10,
    [string] $Consumer = "Default",
    [string] $PublisherPrefix = "flowperf",
    [string] $NamePrefix = "CopilotPerfTest-Identity-",
    [string] $OutputPath = (Join-Path $env:TEMP "perftest-identities.json")
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Import-Module (Join-Path $repoRoot "deploy\DvHelper.psm1") -Force

function Write-Step($message) { Write-Host ">> $message" -ForegroundColor Cyan }
function Write-Ok($message)   { Write-Host "   OK: $message" -ForegroundColor Green }

Write-Step "Connecting to $EnvironmentUrl as the management identity"
$token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null
$dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }

$roleName = "Flow Trigger Caller - $Consumer"
$roleId = Find-DataverseRecordId @dv -EntitySetName "roles" -IdField "roleid" -Filter "name eq '$roleName'"
if (-not $roleId) { throw "Role '$roleName' not found - deploy the perf-testing environment first (Deploy-PerfTestEnvironment.ps1)." }
Write-Ok "Role '$roleName' resolved ($roleId)"

$rootBuId = (Invoke-Dataverse @dv -Method GET -Path "businessunits?`$select=businessunitid&`$filter=_parentbusinessunitid_value eq null&`$top=1").value[0].businessunitid

$identities = @()
for ($i = 1; $i -le $IdentityCount; $i++) {
    $name = "$NamePrefix{0:D2}" -f $i
    Write-Step "Identity $i/$IdentityCount : $name"

    $existingApps = az ad app list --display-name $name -o json 2>$null | ConvertFrom-Json
    if ($existingApps -and $existingApps.Count -gt 0) {
        $app = $existingApps[0]
        Write-Ok "App registration already exists ($($app.appId))"
    } else {
        $app = az ad app create --display-name $name -o json | ConvertFrom-Json
        Write-Ok "Created app registration ($($app.appId))"
    }
    $appId = $app.appId

    # Dataverse's systemusers.applicationid check needs a Service Principal
    # (Enterprise Application) object to exist for this app, not just the
    # App Registration - az ad app create only creates the latter. Without
    # this, the systemusers POST below fails with "We didn't find that
    # application ID ... in your Azure Active Directory."
    $existingSp = az ad sp list --filter "appId eq '$appId'" -o json 2>$null | ConvertFrom-Json
    if (-not $existingSp -or $existingSp.Count -eq 0) {
        az ad sp create --id $appId -o none
        Write-Ok "Created service principal for $appId"
        Start-Sleep -Seconds 8   # brief settle for cross-service (Azure AD -> Dataverse) propagation
    } else {
        Write-Ok "Service principal already exists"
    }

    $secretResult = az ad app credential reset --id $appId --years 1 -o json 2>$null | ConvertFrom-Json
    $secret = $secretResult.password
    Write-Ok "Secret reset"

    $existingUsers = (Invoke-Dataverse @dv -Method GET -Path "systemusers?`$select=systemuserid&`$filter=applicationid eq $appId").value
    if ($existingUsers.Count -gt 0) {
        $userId = $existingUsers[0].systemuserid
        Write-Ok "Application User already exists ($userId)"
    } else {
        # New app registrations/service principals can take longer than a
        # few seconds to propagate from Azure AD into Dataverse's own
        # directory cache - retry the specific "didn't find that
        # application ID" error a few times with backoff before giving up.
        $userId = $null
        $maxAttempts = 5
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                $userId = Invoke-Dataverse @dv -Method POST -Path "systemusers" -Body @{
                    applicationid = $appId
                    "businessunitid@odata.bind" = "/businessunits($rootBuId)"
                }
                break
            } catch {
                if ($_.Exception.Message -match "didn.t find that application ID" -and $attempt -lt $maxAttempts) {
                    $waitSec = 5 * $attempt
                    Write-Host "   Application ID not yet visible to Dataverse (attempt $attempt/$maxAttempts) - waiting ${waitSec}s..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds $waitSec
                } else {
                    throw
                }
            }
        }
        Write-Ok "Created Application User ($userId)"
        Start-Sleep -Seconds 2   # brief settle before role association
    }

    $existingRoles = (Invoke-Dataverse @dv -Method GET -Path "systemusers($userId)/systemuserroles_association?`$select=roleid&`$filter=roleid eq $roleId").value
    if ($existingRoles.Count -eq 0) {
        Invoke-Dataverse @dv -Method POST -Path "systemusers($userId)/systemuserroles_association/`$ref" -Body @{
            "@odata.id" = "$($EnvironmentUrl.TrimEnd('/'))/api/data/v9.2/roles($roleId)"
        } | Out-Null
        Write-Ok "Granted role '$roleName'"
    } else {
        Write-Ok "Role '$roleName' already granted"
    }

    $identities += [pscustomobject]@{
        Name         = $name
        ClientId     = $appId
        ClientSecret = $secret
        TenantId     = $TenantId
        SystemUserId = $userId
    }
}

$identities | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding utf8

Write-Host ""
Write-Host "=== $($identities.Count) identities ready, each holding '$roleName' ===" -ForegroundColor Yellow
$identities | Select-Object Name, ClientId, SystemUserId | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Credentials written to: $OutputPath" -ForegroundColor Yellow
Write-Host "This file contains real client secrets and lives OUTSIDE the repo on purpose - delete it when done testing." -ForegroundColor Red
