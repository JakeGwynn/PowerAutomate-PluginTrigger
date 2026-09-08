<#
.SYNOPSIS
    Breaks down a completed load test's results into three phases to isolate where
    time is actually going as concurrency increases: dispatch (event raised -> worker
    flow starts running), the flow's own execution (start -> finish), and poll-detect
    + respond (result written -> RunFlowDispatcher's poll notices it -> caller gets the
    HTTP response).

.DESCRIPTION
    Correlates three independent data sources by the correlation GUID embedded in the
    plugin's own response message (Invoke-LoadTest.ps1's CSV never records this GUID
    directly - it's extracted here via regex from each row's FlowMessage):

      1. deploy\Invoke-LoadTest.ps1's own results CSV (RequestStartTimestamp and
         CompletionTimestamp per call).
      2. The flow-result table's createdon timestamp for the row the worker flow
         wrote back (queried live from Dataverse) - this is "when the flow finished."
      3. The worker flow's own run history (startTime/endTime per run, via the Flow
         API) - this splits "when the flow finished" further into "when it started"
         and "how long its own logic took," so dispatch latency and the flow's own
         execution time can be told apart. Flow run history is capped at 250 rows by
         the underlying API and has no time-range filter, so for a load test with more
         than 250 total successful calls, only the most recent 250 runs are available -
         typically enough to cover the heaviest (most concurrent, and therefore most
         interesting) batches even if the lightest ones aren't individually covered.

.PARAMETER ResultsCsvPath
    Path to Invoke-LoadTest.ps1's output CSV (must have RequestStartTimestamp /
    CompletionTimestamp columns).

.PARAMETER FlowRunHistoryJsonPath
    Optional path to a saved JSON array of the worker flow's run history
    (name/startTime/endTime/status per run - e.g. from the Flow API's run-history
    endpoint or `flowagent-list_flows`/`get_run_history`). If omitted, only the
    flow-result-table-based Phase A+B breakdown is computed (no dispatch-vs-flow-
    execution split).

.EXAMPLE
    .\Get-LoadTestPhaseBreakdown.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -ResultsCsvPath .\load-test-results.csv -FlowRunHistoryJsonPath .\flow-runs.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [Parameter(Mandatory)] [string] $ResultsCsvPath,
    [string] $Consumer = "Default",
    [string] $PublisherPrefix = "flowtrig",
    [string] $FlowRunHistoryJsonPath,   # optional: raw JSON array from flowagent's get_run_history (name/startTime/endTime/status)
    [datetime] $WindowStartUtc,          # optional override; defaults to min(RequestStartTimestamp) - 1 minute
    [datetime] $WindowEndUtc             # optional override; defaults to max(CompletionTimestamp) + 1 minute
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "DvHelper.psm1") -Force

function Write-Step($message) { Write-Host ">> $message" -ForegroundColor Cyan }
function Write-Ok($message)   { Write-Host "   OK: $message" -ForegroundColor Green }

function Get-Percentile($sortedArray, [double]$p) {
    if ($sortedArray.Count -eq 0) { return 0 }
    $idx = [math]::Ceiling($p * $sortedArray.Count) - 1
    $idx = [math]::Max(0, [math]::Min($idx, $sortedArray.Count - 1))
    return $sortedArray[$idx]
}

# Dataverse (via Invoke-Dataverse -> ConvertFrom-Json) and the flow-run-history raw
# JSON parsed later in this script both hand back ISO 8601 UTC timestamps
# ("...T...Z") - but PowerShell 7's ConvertFrom-Json auto-converts these to a real
# [datetime] with Kind=Utc and correct wall-clock digits, while Windows PowerShell
# 5.1's ConvertFrom-Json leaves them as plain strings. A naive
# [datetime]::SpecifyKind([datetime]$value, 'Utc') is NOT safe across both engines:
# on 5.1, casting the still-"Z"-suffixed STRING to [datetime] first silently
# converts it to local wall-clock time (.NET's default DateTime.Parse behavior for a
# "Z" string), and then SpecifyKind(Utc) mislabels those already-local digits as
# UTC - shifting the value by exactly the local UTC offset (a real bug hit during
# development). Coercing to a canonical ISO string FIRST and re-parsing via
# DateTimeOffset with DateTimeStyles.RoundtripKind (which forces the string's own
# explicit "Z"/offset marker to be honored instead of auto-converted) gives one
# single, verified-identical code path on both engines regardless of which type
# that engine's own JSON deserializer produced.
function ConvertTo-UtcDateTimeOffset {
    param($Value)
    if ($Value -is [datetime]) {
        $isoString = $Value.ToString("o")
    } else {
        $isoString = [string]$Value
    }
    return [datetimeoffset]::Parse($isoString, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
}

$csv = Import-Csv $ResultsCsvPath
if (-not ($csv | Get-Member -Name RequestStartTimestamp)) {
    throw "'$ResultsCsvPath' has no RequestStartTimestamp column - this analysis requires the fixed version of Invoke-LoadTest.ps1 (per-task completion polling, not a batch-wide Task.WaitAll). Re-run the load test first."
}

$starts = $csv.RequestStartTimestamp | ForEach-Object { [datetimeoffset]$_ }
$completions = $csv.CompletionTimestamp | ForEach-Object { [datetimeoffset]$_ }
if (-not $WindowStartUtc) { $WindowStartUtc = ($starts | Sort-Object)[0].UtcDateTime.AddMinutes(-1) }
if (-not $WindowEndUtc)   { $WindowEndUtc   = ($completions | Sort-Object)[-1].UtcDateTime.AddMinutes(1) }
Write-Ok "Test window: $($WindowStartUtc.ToString('o')) to $($WindowEndUtc.ToString('o'))"

Write-Step "Querying $($PublisherPrefix)_flowresult rows written during the test window"
$token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null
$dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }
$filterStart = $WindowStartUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
$filterEnd = $WindowEndUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
$correlationIdField = "$($PublisherPrefix)_correlationid"
$flowResultRows = (Invoke-Dataverse @dv -Method GET -Path "$($PublisherPrefix)_flowresults?`$select=$correlationIdField,createdon&`$filter=createdon ge $filterStart and createdon le $filterEnd&`$orderby=createdon asc&`$top=5000").value
Write-Ok "$($flowResultRows.Count) $($PublisherPrefix)_flowresult rows found"

$flowResultsByCorr = @{}
foreach ($r in $flowResultRows) {
    $flowResultsByCorr[$r.$correlationIdField] = ConvertTo-UtcDateTimeOffset $r.createdon
}

Write-Step "Joining CSV rows to $($PublisherPrefix)_flowresult rows via correlation GUID"
$joined = foreach ($row in $csv) {
    if ($row.HttpSuccess -ne "True" -or $row.FlowStatus -ne "Succeeded") { continue }
    if ($row.FlowMessage -notmatch "correlation ([0-9a-fA-F\-]{36})") { continue }
    $corrId = $Matches[1]
    if (-not $flowResultsByCorr.ContainsKey($corrId)) { continue }

    $reqStart = [datetimeoffset]$row.RequestStartTimestamp
    $writtenAt = $flowResultsByCorr[$corrId]

    [pscustomobject]@{
        BatchSize          = [int]$row.BatchSize
        CorrelationId      = $corrId
        ReqStart           = $reqStart
        WrittenAt          = $writtenAt
        TotalDurationMs    = [double]$row.DurationMs
        DispatchRunWriteMs = ($writtenAt - $reqStart).TotalMilliseconds
    }
}
Write-Ok "$($joined.Count) of $($csv.Count) CSV rows joined to a $($PublisherPrefix)_flowresult row"

Write-Host ""
Write-Host "=== Phase A+B (dispatch + flow execution + result write) vs Phase C (poll-detect + respond) ===" -ForegroundColor Yellow
$phaseAbc = $joined | Group-Object BatchSize | Sort-Object { [int]$_.Name } | ForEach-Object {
    $g = $_.Group
    $ab = $g.DispatchRunWriteMs | Sort-Object
    $c = ($g | ForEach-Object { $_.TotalDurationMs - $_.DispatchRunWriteMs }) | Sort-Object
    [pscustomobject]@{
        BatchSize   = [int]$_.Name
        N           = $g.Count
        'AB_p50_s'  = [math]::Round((Get-Percentile $ab 0.50) / 1000, 1)
        'AB_max_s'  = [math]::Round(($ab | Select-Object -Last 1) / 1000, 1)
        'C_p50_s'   = [math]::Round((Get-Percentile $c 0.50) / 1000, 1)
        'C_max_s'   = [math]::Round(($c | Select-Object -Last 1) / 1000, 1)
    }
}
$phaseAbc | Format-Table -AutoSize | Out-String | Write-Host

if ($FlowRunHistoryJsonPath -and (Test-Path $FlowRunHistoryJsonPath)) {
    Write-Step "Splitting Phase A+B into dispatch latency vs flow's own execution time"
    $batchWindows = $csv | Group-Object BatchSize | Sort-Object { [int]$_.Name } | ForEach-Object {
        $winStarts = $_.Group.RequestStartTimestamp | ForEach-Object { [datetimeoffset]$_ } | Sort-Object
        [pscustomobject]@{ BatchSize = [int]$_.Name; WinStart = $winStarts[0].UtcDateTime }
    }

    $rawRuns = Get-Content $FlowRunHistoryJsonPath -Raw | ConvertFrom-Json
    $runs = $rawRuns | ForEach-Object {
        [pscustomobject]@{
            Start = (ConvertTo-UtcDateTimeOffset $_.startTime).UtcDateTime
            End   = (ConvertTo-UtcDateTimeOffset $_.endTime).UtcDateTime
        }
    }

    # Batches never overlap in firing time (Invoke-LoadTest.ps1 waits for 100% of the
    # current batch to complete, plus a fixed pause, before the next batch's first
    # request fires) - so attributing each run to the latest batch whose window
    # started at or before that run's own start time is unambiguous.
    $attributed = foreach ($run in $runs) {
        $matchingBatch = $batchWindows | Where-Object { $_.WinStart -le $run.Start } | Sort-Object WinStart -Descending | Select-Object -First 1
        if ($matchingBatch) {
            [pscustomobject]@{
                BatchSize         = $matchingBatch.BatchSize
                DispatchLatencyMs = ($run.Start - $matchingBatch.WinStart).TotalMilliseconds
                FlowRunMs         = ($run.End - $run.Start).TotalMilliseconds
            }
        }
    }

    $dispatchSplit = $attributed | Group-Object BatchSize | Sort-Object { [int]$_.Name } | ForEach-Object {
        $g = $_.Group
        $disp = $g.DispatchLatencyMs | Sort-Object
        $flowMs = $g.FlowRunMs | Sort-Object
        [pscustomobject]@{
            BatchSize              = [int]$_.Name
            N                      = $g.Count
            DispatchLatency_p50_s  = [math]::Round((Get-Percentile $disp 0.50) / 1000, 1)
            DispatchLatency_max_s  = [math]::Round(($disp | Select-Object -Last 1) / 1000, 1)
            FlowOwnExecution_p50_ms = [math]::Round((Get-Percentile $flowMs 0.50), 0)
            FlowOwnExecution_max_ms = [math]::Round(($flowMs | Select-Object -Last 1), 0)
        }
    }
    $dispatchSplit | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "(Coverage note: flow run history is capped at 250 rows with no time filter -" -ForegroundColor DarkGray
    Write-Host " only batches whose runs fall within that most-recent-250 window appear above.)" -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "No -FlowRunHistoryJsonPath supplied - skipping the dispatch-vs-flow-execution split." -ForegroundColor DarkGray
    Write-Host "(Fetch it via the flowagent MCP tool's get_run_history for this flow, save the raw" -ForegroundColor DarkGray
    Write-Host " JSON array to a file, and pass that file's path in -FlowRunHistoryJsonPath.)" -ForegroundColor DarkGray
}
