<#
.SYNOPSIS
    PERF-TESTING COPY of ../../deploy/Invoke-LoadTest.ps1 - runs the SAME
    escalating concurrent-call load test, but splits each batch's calls
    ROUND-ROBIN across multiple independent CALLING IDENTITIES (service
    principals created by New-PerfTestIdentities.ps1) instead of sending
    every call as the same single identity.

.DESCRIPTION
    Directly tests whether the growth found by Get-PerfTestBreakdown.ps1 -
    isolated to the span before the dispatcher plug-in starts running, and
    confirmed NOT to be network/TLS-connection-establishment-bound by
    Invoke-PerfTestWarmLoadTest.ps1 - is a per-CALLING-IDENTITY admission
    queue, per Dataverse's own documented behavior (service protection
    limits, including the concurrent-request limit, are evaluated "for each
    user" independently:
    https://learn.microsoft.com/power-apps/developer/data-platform/api-limits).

    Reads identities from -IdentitiesJsonPath (New-PerfTestIdentities.ps1's
    output - a JSON array of {Name, ClientId, ClientSecret, TenantId}),
    acquires ONE client_credentials token per identity up front, and for
    each batch assigns call index i to identity (i mod -IdentityCount) - so
    -IdentityCount 1 reproduces the original single-identity behavior,
    -IdentityCount 4 spreads a 100-call batch as 25 calls per identity, etc.
    Records an extra IdentityIndex column so the analysis can confirm even
    distribution and, if desired, group by identity.

    Everything else - the HttpClient setup, the per-task completion-polling
    measurement methodology, the output CSV shape (plus one extra column) -
    is identical to ../../deploy/Invoke-LoadTest.ps1. See that script's own
    remarks for why HttpClientHandler (not SocketsHttpHandler) and both
    connection-limit lines are needed for correctness on both PowerShell 5.1
    and 7.

.PARAMETER IdentityCount
    How many of the identities in -IdentitiesJsonPath to actually use for
    this run (taken from the start of that file's list) - lets one
    New-PerfTestIdentities.ps1 -IdentityCount 10 run back this script with
    -IdentityCount 1, 2, 4, or 10 without regenerating identities each time.

.EXAMPLE
    .\Invoke-PerfTestMultiIdentityLoadTest.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -IdentitiesJsonPath $env:TEMP\perftest-identities.json -IdentityCount 4 -BatchSizes 100
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [Parameter(Mandatory)] [string] $IdentitiesJsonPath,
    [Parameter(Mandatory)] [int] $IdentityCount,
    [string] $Consumer = "Default",
    [string] $PublisherPrefix = "flowperf",
    [int[]] $BatchSizes = @(100),
    [int] $DelayBetweenBatchesSeconds = 15,
    [int] $TimeoutSeconds = 150,
    [string] $ResultsCsvPath
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http

function Write-Step($message) { Write-Host ">> $message" -ForegroundColor Cyan }
function Write-Ok($message)   { Write-Host "   OK: $message" -ForegroundColor Green }

if (-not $ResultsCsvPath) { $ResultsCsvPath = Join-Path $PSScriptRoot "perftest-multiidentity-$IdentityCount.csv" }

# ---------------------------------------------------------------------------
# 1. Load identities and acquire one client_credentials token per identity.
# ---------------------------------------------------------------------------
$allIdentities = Get-Content $IdentitiesJsonPath -Raw | ConvertFrom-Json
if ($allIdentities.Count -lt $IdentityCount) {
    throw "-IdentitiesJsonPath only has $($allIdentities.Count) identities, but -IdentityCount $IdentityCount was requested. Run New-PerfTestIdentities.ps1 -IdentityCount $IdentityCount first."
}
$selected = $allIdentities | Select-Object -First $IdentityCount

Write-Step "Acquiring client_credentials tokens for $IdentityCount identity/identities"
$tokens = for ($idx = 0; $idx -lt $selected.Count; $idx++) {
    $identity = $selected[$idx]
    $tokenEndpoint = "https://login.microsoftonline.com/$($identity.TenantId)/oauth2/v2.0/token"
    $form = @{
        client_id     = $identity.ClientId
        client_secret = $identity.ClientSecret
        scope         = "$($EnvironmentUrl.TrimEnd('/'))/.default"
        grant_type    = "client_credentials"
    }
    $response = Invoke-RestMethod -Uri $tokenEndpoint -Method Post -Body $form -ContentType "application/x-www-form-urlencoded"
    Write-Ok "Token acquired for $($identity.Name) (index $idx)"
    $response.access_token
}

# Confirm each token actually authenticates before running the real test -
# fail fast with a clear error rather than discovering a bad token mid-batch.
Write-Step "Confirming each identity's token authenticates (WhoAmI)"
for ($idx = 0; $idx -lt $tokens.Count; $idx++) {
    $whoAmIUri = "$($EnvironmentUrl.TrimEnd('/'))/api/data/v9.2/WhoAmI"
    try {
        $who = Invoke-RestMethod -Uri $whoAmIUri -Headers @{ Authorization = "Bearer $($tokens[$idx])"; Accept = "application/json" }
        Write-Ok "$($selected[$idx].Name) -> UserId $($who.UserId)"
    } catch {
        throw "Identity '$($selected[$idx].Name)' (index $idx) failed WhoAmI - confirm it holds the 'Flow Trigger Caller - $Consumer' role. $($_.Exception.Message)"
    }
}

$callerName = if ($Consumer -eq "Default") { "$($PublisherPrefix)_RunFlow" } else { "$($PublisherPrefix)_RunFlow_$Consumer" }
$uri = "$($EnvironmentUrl.TrimEnd('/'))/api/data/v9.2/$callerName"

if (Test-Path $ResultsCsvPath) {
    Write-Ok "Appending to existing results file: $ResultsCsvPath"
} else {
    "RequestStartTimestamp,CompletionTimestamp,BatchSize,Index,IdentityIndex,DurationMs,HttpSuccess,HttpStatusCode,FlowStatus,FlowMessage,Error" | Out-File -FilePath $ResultsCsvPath -Encoding utf8
    Write-Ok "Created new results file: $ResultsCsvPath"
}

# Same HttpClient/connection-pool setup as ../../deploy/Invoke-LoadTest.ps1.
[System.Net.ServicePointManager]::DefaultConnectionLimit = 1000
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.MaxConnectionsPerServer = 1000
$httpClient = [System.Net.Http.HttpClient]::new($handler)
$httpClient.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

function Get-Percentile($sortedArray, [double]$p) {
    if ($sortedArray.Count -eq 0) { return 0 }
    $idx = [math]::Ceiling($p * $sortedArray.Count) - 1
    $idx = [math]::Max(0, [math]::Min($idx, $sortedArray.Count - 1))
    return $sortedArray[$idx]
}

$allBatchSummaries = @()

foreach ($batchSize in $BatchSizes) {
    Write-Step "Batch: $batchSize concurrent calls to $callerName, spread across $IdentityCount identity/identities (round-robin)"
    $batchStart = Get-Date

    $inFlight = for ($i = 0; $i -lt $batchSize; $i++) {
        $identityIndex = $i % $IdentityCount
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
        $req.Headers.TryAddWithoutValidation("Authorization", "Bearer $($tokens[$identityIndex])") | Out-Null
        $req.Headers.TryAddWithoutValidation("Accept", "application/json") | Out-Null
        $req.Headers.TryAddWithoutValidation("OData-MaxVersion", "4.0") | Out-Null
        $req.Headers.TryAddWithoutValidation("OData-Version", "4.0") | Out-Null
        $body = "{`"InputJson`":`"{\`"batch\`":$batchSize,\`"index\`":$i}`"}"
        $req.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, "application/json")

        [pscustomobject]@{
            Index            = $i
            IdentityIndex    = $identityIndex
            RequestStart     = Get-Date
            Task             = $httpClient.SendAsync($req)
            CompletionTime   = $null
        }
    }

    # Same per-task completion-polling approach as ../../deploy/Invoke-LoadTest.ps1
    # (not a batch-wide Task.WaitAll) - see that script's own remarks for why.
    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $inFlight) { $pending.Add($item) }
    while ($pending.Count -gt 0) {
        Start-Sleep -Milliseconds 15
        for ($p = $pending.Count - 1; $p -ge 0; $p--) {
            if ($pending[$p].Task.IsCompleted) {
                $pending[$p].CompletionTime = Get-Date
                $pending.RemoveAt($p)
            }
        }
    }

    $batchResults = foreach ($item in $inFlight) {
        $durationMs = [math]::Round(($item.CompletionTime - $item.RequestStart).TotalMilliseconds, 1)
        $httpSuccess = $false
        $httpStatus = 0
        $flowStatus = $null
        $flowMessage = $null
        $errorText = $null

        try {
            $response = $item.Task.GetAwaiter().GetResult()
            $httpStatus = [int]$response.StatusCode
            $httpSuccess = $response.IsSuccessStatusCode
            $contentText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ($httpSuccess) {
                try {
                    $parsed = $contentText | ConvertFrom-Json
                    $outputJson = $parsed.OutputJson | ConvertFrom-Json
                    $flowStatus = $outputJson.status
                    $flowMessage = $outputJson.message
                } catch {
                    $errorText = "Could not parse response body: $($_.Exception.Message)"
                }
            } else {
                $errorText = $contentText
            }
        } catch {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            $errorText = $inner.Message
        }

        [pscustomobject]@{
            RequestStartTimestamp = $item.RequestStart.ToString("o")
            CompletionTimestamp   = $item.CompletionTime.ToString("o")
            BatchSize             = $batchSize
            Index                 = $item.Index
            IdentityIndex         = $item.IdentityIndex
            DurationMs            = $durationMs
            HttpSuccess           = $httpSuccess
            HttpStatusCode        = $httpStatus
            FlowStatus            = $flowStatus
            FlowMessage           = $flowMessage
            Error                 = $errorText
        }
    }

    $batchResults | Export-Csv -Path $ResultsCsvPath -Append -NoTypeInformation -Encoding utf8

    $durations = $batchResults.DurationMs | Sort-Object
    $succeeded = @($batchResults | Where-Object { $_.HttpSuccess -and $_.FlowStatus -eq "Succeeded" })
    $timedOut  = @($batchResults | Where-Object { $_.HttpSuccess -and $_.FlowStatus -eq "Timeout" })
    $httpFailed = @($batchResults | Where-Object { -not $_.HttpSuccess })
    $errorGroups = $httpFailed | Group-Object HttpStatusCode, Error | Sort-Object Count -Descending

    $summary = [pscustomobject]@{
        BatchSize       = $batchSize
        IdentityCount   = $IdentityCount
        WallClockSec    = [math]::Round(((Get-Date) - $batchStart).TotalSeconds, 1)
        Succeeded       = $succeeded.Count
        TimedOut        = $timedOut.Count
        HttpFailed      = $httpFailed.Count
        MinMs           = [math]::Round(($durations | Select-Object -First 1), 0)
        MedianMs        = [math]::Round((Get-Percentile $durations 0.50), 0)
        P95Ms           = [math]::Round((Get-Percentile $durations 0.95), 0)
        MaxMs           = [math]::Round(($durations | Select-Object -Last 1), 0)
    }
    $allBatchSummaries += $summary

    Write-Ok "Batch $batchSize ($IdentityCount identities) done in $($summary.WallClockSec)s wall-clock: $($summary.Succeeded) succeeded, $($summary.TimedOut) timed out, $($summary.HttpFailed) HTTP-failed"
    Write-Host "   Duration (ms): min=$($summary.MinMs) median=$($summary.MedianMs) p95=$($summary.P95Ms) max=$($summary.MaxMs)"
    if ($errorGroups) {
        Write-Host "   Error breakdown:" -ForegroundColor Yellow
        foreach ($g in $errorGroups) {
            $sample = $g.Group[0]
            Write-Host "     [$($sample.HttpStatusCode)] x$($g.Count): $($sample.Error)" -ForegroundColor Yellow
        }
    }

    if ($batchSize -ne $BatchSizes[-1]) {
        Write-Host "   Pausing $DelayBetweenBatchesSeconds s before next batch..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $DelayBetweenBatchesSeconds
    }
}

Write-Host ""
Write-Host "=== Multi-identity load test summary ($callerName @ $EnvironmentUrl, $IdentityCount identity/identities) ===" -ForegroundColor Yellow
$allBatchSummaries | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Full per-call results: $ResultsCsvPath" -ForegroundColor Yellow
