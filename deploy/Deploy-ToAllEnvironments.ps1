<#
.SYNOPSIS
    Deploys the Flow Trigger solution to every environment passed via
    -EnvironmentUrls, continuing past any single environment's failure so one
    blocked/misconfigured sandbox doesn't stop the others.

.DESCRIPTION
    If your tenant has Dataverse's IP firewall enabled with different
    settings per environment, some of these may fail with a 403 until each
    environment's allow list includes this machine's current public IP. This
    wrapper reports a clear per-environment PASS/FAIL summary at the end
    instead of stopping at the first failure.

.EXAMPLE
    .\Deploy-ToAllEnvironments.ps1
    .\Deploy-ToAllEnvironments.ps1 -EnvironmentUrls "https://org1....crm.dynamics.com","https://org2....crm.dynamics.com"
#>
[CmdletBinding()]
param(
    # No default list is provided - pass your own environment URLs explicitly,
    # e.g. -EnvironmentUrls "https://yourorg1.crm.dynamics.com","https://yourorg2.crm.dynamics.com"
    [string[]] $EnvironmentUrls = @()
)

if (-not $EnvironmentUrls -or $EnvironmentUrls.Count -eq 0) {
    throw "Pass at least one target environment via -EnvironmentUrls, e.g. -EnvironmentUrls 'https://yourorg.crm.dynamics.com'."
}

$results = @()

foreach ($url in $EnvironmentUrls) {
    Write-Host ""
    Write-Host "################################################################" -ForegroundColor Magenta
    Write-Host "# Deploying to $url" -ForegroundColor Magenta
    Write-Host "################################################################" -ForegroundColor Magenta

    try {
        & (Join-Path $PSScriptRoot "Deploy-FlowTriggerSolution.ps1") -EnvironmentUrl $url
        $results += [pscustomobject]@{ Environment = $url; Result = "Success"; Detail = "" }
    }
    catch {
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $results += [pscustomobject]@{ Environment = $url; Result = "FAILED"; Detail = $_.Exception.Message }
    }
}

Write-Host ""
Write-Host "=== Deployment summary ===" -ForegroundColor Yellow
$results | Format-Table -AutoSize -Wrap | Out-String | Write-Host

if ($results | Where-Object { $_.Result -eq "FAILED" }) {
    Write-Host "One or more environments failed - see per-environment errors above. IP-firewall 403s are the most likely cause; add this machine's public IP to that environment's allow list (or switch it to Audit mode temporarily) and re-run this script - it's safe to re-run, already-deployed environments are untouched." -ForegroundColor Yellow
    exit 1
}
