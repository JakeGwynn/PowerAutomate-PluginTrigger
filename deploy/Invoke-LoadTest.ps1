<#
.SYNOPSIS
    Fires an escalating series of TRULY CONCURRENT calls against a consumer's caller
    Custom API (flowtrig_RunFlow[_Consumer]) to find this deployment's practical
    concurrency ceiling, recording the duration and outcome of every individual call.

.DESCRIPTION
    Uses raw .NET HttpClient + Task (NOT PowerShell jobs/runspaces/ForEach-Object
    -Parallel) for concurrency: every call in a batch is fired via HttpClient.SendAsync
    (a real async I/O call, not a background thread running PowerShell script), then
    awaited together with [Threading.Tasks.Task]::WaitAll. This avoids PowerShell
    runspace overhead/limits entirely and gives an accurate picture of how many
    concurrent HTTP calls (and therefore concurrent plug-in executions) the environment
    can sustain.

    All calls in every batch authenticate as the SAME identity (whichever principal is
    currently signed in via az login) and therefore share that identity's Dataverse
    service-protection limits: https://learn.microsoft.com/power-apps/developer/data-platform/api-limits.
    Expect throttling (HTTP 429) once a batch exceeds that identity's budget, by
    design - that IS the ceiling this script exists to find.

    Every individual call's outcome is written to -ResultsCsvPath (append mode, so
    re-running accumulates a full history) with columns: RequestStartTimestamp,
    CompletionTimestamp, BatchSize, Index, DurationMs, HttpSuccess, HttpStatusCode,
    FlowStatus, FlowMessage, Error. A per-batch summary (success/failure counts,
    min/avg/p50/p95/max duration, distinct errors) is printed after each batch.

    Per-call completion is detected by polling each Task's own IsCompleted flag
    (every 15ms) rather than a single Task.WaitAll() over the whole batch, so each
    row's DurationMs reflects that call's own completion time, not the batch's
    slowest call.

.PARAMETER BatchSizes
    The sequence of concurrency levels to test, in order. Default 10,25,50,100,250,500.

.PARAMETER DelayBetweenBatchesSeconds
    Pause between batches, so one batch's tail (e.g. still-polling plug-in executions)
    doesn't bleed into the next batch's measurement. Default 15s.

.PARAMETER TimeoutSeconds
    Per-call HttpClient timeout. Must exceed the plug-in's own PollBudget (currently
    110s) or you'll see client-side timeouts that aren't real server-side failures.
    Default 150s.

.EXAMPLE
    .\Invoke-LoadTest.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer Default

.EXAMPLE
    Just the small batches, writing to a custom path:
    .\Invoke-LoadTest.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer Default -BatchSizes 10,25,50 -ResultsCsvPath C:\temp\quick.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [string] $Consumer = "Default",
    [string] $PublisherPrefix = "flowtrig",
    [int[]] $BatchSizes = @(10, 25, 50, 100, 250, 500),
    [int] $DelayBetweenBatchesSeconds = 15,
    [int] $TimeoutSeconds = 150,
    [string] $ResultsCsvPath = (Join-Path $PSScriptRoot "load-test-results.csv")
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "DvHelper.psm1") -Force

# Explicit, defensive assembly load: System.Net.Http is not guaranteed to already be
# loaded into the AppDomain at this point under Windows PowerShell 5.1 (.NET
# Framework) - unlike PowerShell 7, where it's part of the always-loaded base class
# library. Relying on some earlier statement having loaded it as a side effect is
# fragile and invocation-order dependent: an otherwise-identical script can fail
# with "Unable to find type [System.Net.Http.HttpClientHandler]" depending on
# WinPS 5.1 invocation style. Add-Type -AssemblyName makes this deterministic
# regardless of invocation style or session history; it's a harmless no-op if
# the assembly is already loaded (as it always is on PowerShell 7).
Add-Type -AssemblyName System.Net.Http

function Write-Step($message) { Write-Host ">> $message" -ForegroundColor Cyan }
function Write-Ok($message)   { Write-Host "   OK: $message" -ForegroundColor Green }

$callerName = if ($Consumer -eq "Default") { "$($PublisherPrefix)_RunFlow" } else { "$($PublisherPrefix)_RunFlow_$Consumer" }
$uri = "$($EnvironmentUrl.TrimEnd('/'))/api/data/v9.2/$callerName"

Write-Step "Acquiring token and confirming connectivity"
$token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
$who = Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token
Write-Ok "Connected as $($who.UserId) - calling $callerName"

if (Test-Path $ResultsCsvPath) {
    Write-Ok "Appending to existing results file: $ResultsCsvPath"
} else {
    "RequestStartTimestamp,CompletionTimestamp,BatchSize,Index,DurationMs,HttpSuccess,HttpStatusCode,FlowStatus,FlowMessage,Error" | Out-File -FilePath $ResultsCsvPath -Encoding utf8
    Write-Ok "Created new results file: $ResultsCsvPath"
}

# One HttpClient for the whole run - HttpClient is explicitly designed to be reused
# across many concurrent requests (unlike disposing/recreating per-call, which can
# exhaust ephemeral ports under load). Bump connection limits well past any batch size
# tested here so the .NET layer itself is never the bottleneck being measured.
#
# HttpClientHandler (NOT SocketsHttpHandler) is used deliberately: SocketsHttpHandler
# only exists on .NET Core/5+ (PowerShell 7+) - it throws a type-not-found error under
# Windows PowerShell 5.1's .NET Framework runtime. HttpClientHandler.MaxConnectionsPerServer
# has been present in both runtimes since .NET Framework 4.7.1 / .NET Core 2.0, so this
# one line works unchanged on both. ServicePointManager.DefaultConnectionLimit is ALSO
# set explicitly below - on classic .NET Framework specifically (Windows PowerShell
# 5.1), HttpClient still funnels through ServicePointManager under the hood, whose
# historic default (2 connections per host) would otherwise silently serialize most of
# a "concurrent" batch; this line is a no-op on PowerShell 7/.NET Core but required for
# correctness on 5.1.
[System.Net.ServicePointManager]::DefaultConnectionLimit = 1000
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.MaxConnectionsPerServer = 1000
$httpClient = [System.Net.Http.HttpClient]::new($handler)
$httpClient.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

$allBatchSummaries = @()

foreach ($batchSize in $BatchSizes) {
    Write-Step "Batch: $batchSize concurrent calls to $callerName"
    $batchStart = Get-Date

    # Phase 1: fire every request. SendAsync returns immediately with a Task - the
    # actual HTTP I/O runs on .NET's own async infrastructure, not a blocking call, so
    # this loop itself completes in well under a second even for 500 calls; all of them
    # are genuinely in flight concurrently once the loop finishes.
    $inFlight = for ($i = 0; $i -lt $batchSize; $i++) {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
        $req.Headers.TryAddWithoutValidation("Authorization", "Bearer $token") | Out-Null
        $req.Headers.TryAddWithoutValidation("Accept", "application/json") | Out-Null
        $req.Headers.TryAddWithoutValidation("OData-MaxVersion", "4.0") | Out-Null
        $req.Headers.TryAddWithoutValidation("OData-Version", "4.0") | Out-Null
        $body = "{`"InputJson`":`"{\`"batch\`":$batchSize,\`"index\`":$i}`"}"
        $req.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, "application/json")

        [pscustomobject]@{
            Index            = $i
            RequestStart     = Get-Date
            Task             = $httpClient.SendAsync($req)
            CompletionTime   = $null
        }
    }

    # Phase 2: poll for each task's OWN completion individually (every 15ms) and record
    # the exact wall-clock moment THAT task finished - deliberately NOT a single
    # Task.WaitAll() over the whole batch. WaitAll only unblocks once every task in the
    # batch has reached a terminal state, so stopping a stopwatch only after WaitAll
    # returns would collapse every row's recorded duration to approximately the
    # slowest call in the batch, not that row's own true completion time (see module
    # remarks above). 15ms polling granularity keeps this simple and safe on BOTH
    # Windows PowerShell 5.1 and PowerShell 7 (Task.IsCompleted is a plain BCL
    # property, no version-specific async PowerShell language features needed) at
    # the cost of at most ~15ms of jitter per call - negligible at the scale being
    # measured here.
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

    # Phase 3: harvest results now that everything has completed.
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
            # SendAsync itself faulted (connection reset, DNS, client-side timeout, etc.)
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            $errorText = $inner.Message
        }

        [pscustomobject]@{
            RequestStartTimestamp = $item.RequestStart.ToString("o")
            CompletionTimestamp   = $item.CompletionTime.ToString("o")
            BatchSize             = $batchSize
            Index                 = $item.Index
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

    function Get-Percentile($sortedArray, [double]$p) {
        if ($sortedArray.Count -eq 0) { return 0 }
        $idx = [math]::Ceiling($p * $sortedArray.Count) - 1
        $idx = [math]::Max(0, [math]::Min($idx, $sortedArray.Count - 1))
        return $sortedArray[$idx]
    }

    $summary = [pscustomobject]@{
        BatchSize       = $batchSize
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

    Write-Ok "Batch $batchSize done in $($summary.WallClockSec)s wall-clock: $($summary.Succeeded) succeeded, $($summary.TimedOut) timed out (flow never answered), $($summary.HttpFailed) HTTP-failed"
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
Write-Host "=== Load test summary ($callerName @ $EnvironmentUrl) ===" -ForegroundColor Yellow
$allBatchSummaries | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Full per-call results: $ResultsCsvPath" -ForegroundColor Yellow
