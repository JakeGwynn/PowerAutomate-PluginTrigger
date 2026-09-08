<#
.SYNOPSIS
    Calls a deployed consumer's caller Custom API (e.g. flowtrig_RunFlow or
    flowtrig_RunFlow_TeamA) and prints the synchronous result.

.DESCRIPTION
    Supports -ImpersonateUpn for genuinely testing per-consumer isolation:
    it calls the Custom API as if a DIFFERENT, real Dataverse user made the
    request (via the documented MSCRMCallerID impersonation header - see
    https://learn.microsoft.com/power-apps/developer/data-platform/impersonate-another-user-web-api),
    without needing that user's own credentials. Your own identity needs the
    'Act on Behalf of Another User' privilege (prvActOnBehalfOfAnotherUser,
    included in the Delegate role, or already held by System Administrator)
    for this to work - the effective privilege set used is the *intersection*
    of your own and the impersonated user's, so this cannot be used to gain
    access the impersonated user doesn't actually have.

.EXAMPLE
    .\Invoke-FlowTrigger.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer Default -InputJson '{"hello":"world"}'
    .\Invoke-FlowTrigger.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer TeamA

.EXAMPLE
    Prove isolation: call as a specific other user instead of yourself.
    .\Invoke-FlowTrigger.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer TeamC -ImpersonateUpn alice@contoso.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [string] $Consumer = "Default",
    [string] $InputJson = '{"message":"triggered from Invoke-FlowTrigger.ps1"}',
    [string] $PublisherPrefix = "flowtrig",
    [string] $ImpersonateUpn
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "DvHelper.psm1") -Force

$callerName = if ($Consumer -eq "Default") { "$($PublisherPrefix)_RunFlow" } else { "$($PublisherPrefix)_RunFlow_$Consumer" }

$token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null

$extraHeaders = @{}
if ($ImpersonateUpn) {
    $dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }
    $impersonateUserId = Find-DataverseRecordId @dv -EntitySetName "systemusers" -IdField "systemuserid" -Filter "domainname eq '$ImpersonateUpn'"
    if (-not $impersonateUserId) {
        throw "No systemuser found with domainname '$ImpersonateUpn' in $EnvironmentUrl."
    }
    $extraHeaders["MSCRMCallerID"] = $impersonateUserId
    Write-Host "Impersonating '$ImpersonateUpn' ($impersonateUserId)" -ForegroundColor DarkYellow
}

Write-Host "Calling $callerName ..." -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $response = Invoke-Dataverse -EnvironmentUrl $EnvironmentUrl -Token $token -Method POST -Path $callerName -Body @{ InputJson = $InputJson } -ExtraHeaders $extraHeaders
    $sw.Stop()
    Write-Host "Responded in $([math]::Round($sw.Elapsed.TotalSeconds, 1))s:" -ForegroundColor Green
    $response | ConvertTo-Json -Depth 5 | Write-Host
}
catch {
    $sw.Stop()
    Write-Host "FAILED after $([math]::Round($sw.Elapsed.TotalSeconds, 1))s:" -ForegroundColor Red
    Write-Host $_.Exception.Message
}

