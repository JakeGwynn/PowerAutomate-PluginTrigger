<#
.SYNOPSIS
    PERF-TESTING COPY of ../../deploy/Invoke-LoadTest.ps1 - runs the SAME
    escalating concurrent-call load test, but immediately before each real
    batch, first fires the SAME number of concurrent GET WhoAmI calls (cheap,
    no plug-in execution) to pre-establish/warm that many TCP+TLS
    connections in the shared HttpClient connection pool, then fires the
    real batch right after so it can reuse those already-warm connections.

.DESCRIPTION
    This exists to answer one specific follow-up question raised by
    Get-PerfTestBreakdown.ps1's own findings: the dominant, concurrency-
    driven growth was isolated to the span between "client sends the
    request" and "the dispatcher plug-in's first line of code runs" - but
    that span itself blends network/TCP/TLS connection-establishment cost
    with Dataverse's own server-side request-admission queueing, and the two
    can't be told apart from the timestamps alone.

    This script provides a controlled comparison instead: if
    connection-establishment (TCP+TLS handshake cost under concurrent load)
    were the dominant driver, pre-warming the connections should make that
    same NetworkAndQueueMs span shrink back down close to the un-loaded
    baseline for the WARM run, since every real call can then reuse an
    already-open, already-authenticated-at-the-TLS-layer connection instead
    of negotiating a new one. If the growth persists at a similar magnitude
    even with warm connections, that rules out connection establishment and
    points at genuine server-side admission-queue/processing delay instead.

    Run this, then run Get-PerfTestBreakdown.ps1 against BOTH this script's
    output and the earlier COLD (non-warmed) results, and compare
    NetworkAndQueueMs between the two at matching batch sizes.

    WhoAmI was chosen for the warm-up calls specifically because it's cheap
    (no plug-in execution, no business logic), hits the exact same host and
    port as the real caller Custom API calls (so it warms the SAME
    connection pool entries), and is already used elsewhere in this repo's
    own tooling (Test-DataverseConnection).

.EXAMPLE
    .\Invoke-PerfTestWarmLoadTest.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer Default -PublisherPrefix flowperf
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [string] $Consumer = "Default",
    [string] $PublisherPrefix = "flowperf",
    [int[]] $BatchSizes = @(10, 25, 50, 100),
    [int] $DelayBetweenBatchesSeconds = 15,
    [int] $TimeoutSeconds = 150,
    [string] $ResultsCsvPath = (Join-Path $PSScriptRoot "perftest-warm-load-results.csv")
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Import-Module (Join-Path $repoRoot "deploy\DvHelper.psm1") -Force
Add-Type -AssemblyName System.Net.Http

function Write-Step($message) { Write-Host ">> $message" -ForegroundColor Cyan }
function Write-Ok($message)   { Write-Host "   OK: $message" -ForegroundColor Green }

$callerName = if ($Consumer -eq "Default") { "$($PublisherPrefix)_RunFlow" } else { "$($PublisherPrefix)_RunFlow_$Consumer" }
$uri = "$($EnvironmentUrl.TrimEnd('/'))/api/data/v9.2/$callerName"
$whoAmIUri = "$($EnvironmentUrl.TrimEnd('/'))/api/data/v9.2/WhoAmI"

Write-Step "Acquiring token and confirming connectivity"
$token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
$who = Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token
Write-Ok "Connected as $($who.UserId) - calling $callerName (warm-up target: WhoAmI on the same host)"

if (Test-Path $ResultsCsvPath) {
    Write-Ok "Appending to existing results file: $ResultsCsvPath"
} else {
    "RequestStartTimestamp,CompletionTimestamp,BatchSize,Index,DurationMs,HttpSuccess,HttpStatusCode,FlowStatus,FlowMessage,Error" | Out-File -FilePath $ResultsCsvPath -Encoding utf8
    Write-Ok "Created new results file: $ResultsCsvPath"
}

# Same HttpClient/connection-pool setup as ../../deploy/Invoke-LoadTest.ps1 - see
# that script's own remarks for why HttpClientHandler (not SocketsHttpHandler) and
# both connection-limit lines are needed for correctness on both PowerShell 5.1 and 7.
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
    # --- Warm-up phase: fire $batchSize concurrent WhoAmI GETs and wait for
    #     ALL of them to complete before starting the timed real batch. Not
    #     recorded as test data - purely to populate the connection pool with
    #     $batchSize already-established, already-TLS-negotiated connections
    #     to this same host, so the real batch immediately following can
    #     reuse them via HTTP keep-alive instead of negotiating new ones.
    Write-Step "Warm-up: $batchSize concurrent WhoAmI calls (not recorded)"
    $warmupTasks = for ($i = 0; $i -lt $batchSize; $i++) {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $whoAmIUri)
        $req.Headers.TryAddWithoutValidation("Authorization", "Bearer $token") | Out-Null
        $req.Headers.TryAddWithoutValidation("Accept", "application/json") | Out-Null
        $req.Headers.TryAddWithoutValidation("OData-MaxVersion", "4.0") | Out-Null
        $req.Headers.TryAddWithoutValidation("OData-Version", "4.0") | Out-Null
        $httpClient.SendAsync($req)
    }
    [System.Threading.Tasks.Task]::WaitAll($warmupTasks)
    foreach ($t in $warmupTasks) { $t.Dispose() }
    Write-Ok "$batchSize connections warmed"

    Write-Step "Batch: $batchSize concurrent calls to $callerName (WARM connections)"
    $batchStart = Get-Date

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

    Write-Ok "Batch $batchSize (warm) done in $($summary.WallClockSec)s wall-clock: $($summary.Succeeded) succeeded, $($summary.TimedOut) timed out, $($summary.HttpFailed) HTTP-failed"
    Write-Host "   Duration (ms): min=$($summary.MinMs) median=$($summary.MedianMs) p95=$($summary.P95Ms) max=$($summary.MaxMs)"

    if ($batchSize -ne $BatchSizes[-1]) {
        Write-Host "   Pausing $DelayBetweenBatchesSeconds s before next batch..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $DelayBetweenBatchesSeconds
    }
}

Write-Host ""
Write-Host "=== Warm-connection load test summary ($callerName @ $EnvironmentUrl) ===" -ForegroundColor Yellow
$allBatchSummaries | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Full per-call results: $ResultsCsvPath" -ForegroundColor Yellow
Write-Host "Compare against the COLD (non-warmed) results with Get-PerfTestBreakdown.ps1 against each file, focusing on NetworkAndQueueMs." -ForegroundColor Yellow
