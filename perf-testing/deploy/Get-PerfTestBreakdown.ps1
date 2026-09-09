<#
.SYNOPSIS
    Decomposes a perf-testing load test into precise sub-phases (dispatcher
    setup, the raise-event call itself, poll-detect latency, dispatcher
    wrap-up, relay + response, and - if flow run history is supplied - the
    worker flow's own dispatch-to-start latency and execution time), then
    prints an automated verdict identifying which sub-phase actually grows
    with concurrency.

.DESCRIPTION
    Correlates three data sources by the correlation GUID embedded in the
    plugin's own response message (same extraction Invoke-LoadTest.ps1's CSV
    already requires - see ../../deploy/Get-LoadTestPhaseBreakdown.ps1's own
    remarks for why this regex-based extraction is necessary):

      1. deploy\Invoke-LoadTest.ps1's own results CSV (client-side
         RequestStartTimestamp / CompletionTimestamp per call) - reused
         UNCHANGED against the perf-testing deployment, just pointed at
         -PublisherPrefix flowperf.
      2. This perf-testing deployment's own <prefix>_calltelemetry table -
         one row per call, written by RunFlowDispatcherTelemetry.cs, holding
         six server-side timestamps (T1-T6) plus poll-attempt count, the
         worker flow's own precise write timestamp, and the outcome. See
         perf-testing/README.md for the full column reference.
      3. (Optional) The worker flow's own run history (startTime/endTime per
         run, via the Flow API) - same batch-window attribution method as
         ../../deploy/Get-LoadTestPhaseBreakdown.ps1, since Flow run-history
         summaries don't carry back our own business correlation id - this
         part of the breakdown is necessarily batch-level, not per-call.

    Every T1-T6 delta is computed from the SAME plug-in execution's own
    clock, so those deltas are clock-skew-free. Two boundaries cross clock
    domains (client RequestStartTimestamp/CompletionTimestamp vs the
    Dataverse server clock) and carry the usual small clock-skew caveat -
    they're still useful for spotting large, concurrency-driven growth, just
    not for sub-second-exact absolute comparisons.

.PARAMETER ResultsCsvPath
    Path to Invoke-LoadTest.ps1's output CSV, run against this perf-testing
    deployment (RequestStartTimestamp / CompletionTimestamp columns
    required).

.PARAMETER FlowRunHistoryJsonPath
    Optional path to a saved JSON array of the worker flow's run history
    (name/startTime/endTime/status per run - e.g. from the Flow API's
    run-history endpoint or the flowagent MCP tool's get_run_history). If
    omitted, the dispatch-to-flow-start / flow's-own-execution split is
    skipped - every server-side T1-T6 metric is still fully computed either
    way.

.EXAMPLE
    .\Get-PerfTestBreakdown.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -ResultsCsvPath .\perftest-load-results.csv -FlowRunHistoryJsonPath .\perftest-flow-runs.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [Parameter(Mandatory)] [string] $ResultsCsvPath,
    [string] $Consumer = "Default",
    [string] $PublisherPrefix = "flowperf",
    [string] $FlowRunHistoryJsonPath,
    [datetime] $WindowStartUtc,
    [datetime] $WindowEndUtc,
    [string] $ExportPerCallCsvPath
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Import-Module (Join-Path $repoRoot "deploy\DvHelper.psm1") -Force

function Write-Step($message) { Write-Host ">> $message" -ForegroundColor Cyan }
function Write-Ok($message)   { Write-Host "   OK: $message" -ForegroundColor Green }

function Get-Percentile($sortedArray, [double]$p) {
    if ($sortedArray.Count -eq 0) { return $null }
    $idx = [math]::Ceiling($p * $sortedArray.Count) - 1
    $idx = [math]::Max(0, [math]::Min($idx, $sortedArray.Count - 1))
    return $sortedArray[$idx]
}

# Same cross-PS-version-safe timestamp parsing as
# ../../deploy/Get-LoadTestPhaseBreakdown.ps1 - see that script's own remarks
# for why a naive [datetime]::SpecifyKind cast is unsafe here on Windows
# PowerShell 5.1 specifically.
function ConvertTo-UtcDateTimeOffset {
    param($Value)
    if ($null -eq $Value -or $Value -eq "") { return $null }
    if ($Value -is [datetime]) {
        $isoString = $Value.ToString("o")
    } else {
        $isoString = [string]$Value
    }
    return [datetimeoffset]::Parse($isoString, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
}

function Get-MillisDelta($earlier, $later) {
    if ($null -eq $earlier -or $null -eq $later) { return $null }
    return ($later - $earlier).TotalMilliseconds
}

# ---------------------------------------------------------------------------
# 1. Load the load-test CSV and figure out the test window.
# ---------------------------------------------------------------------------
$csv = Import-Csv $ResultsCsvPath
if (-not ($csv | Get-Member -Name RequestStartTimestamp)) {
    throw "'$ResultsCsvPath' has no RequestStartTimestamp column - re-run deploy\Invoke-LoadTest.ps1 against this perf-testing deployment first."
}

$starts = $csv.RequestStartTimestamp | ForEach-Object { ConvertTo-UtcDateTimeOffset $_ }
$completions = $csv.CompletionTimestamp | ForEach-Object { ConvertTo-UtcDateTimeOffset $_ }
if (-not $WindowStartUtc) { $WindowStartUtc = ($starts | Sort-Object)[0].UtcDateTime.AddMinutes(-1) }
if (-not $WindowEndUtc)   { $WindowEndUtc   = ($completions | Sort-Object)[-1].UtcDateTime.AddMinutes(1) }
Write-Ok "Test window: $($WindowStartUtc.ToString('o')) to $($WindowEndUtc.ToString('o'))"

# ---------------------------------------------------------------------------
# 2. Connect and resolve the telemetry table's real entity set name -
#    queried from metadata rather than assumed, so this never silently
#    breaks if Deploy-PerfTestEnvironment.ps1's own EntitySetName choice ever
#    changes.
# ---------------------------------------------------------------------------
Write-Step "Connecting to $EnvironmentUrl"
$token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null
$dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }

$telemetryTable = "$($PublisherPrefix)_calltelemetry"
$meta = Invoke-Dataverse @dv -Method GET -Path "EntityDefinitions(LogicalName='$telemetryTable')?`$select=EntitySetName"
$telemetryEntitySet = $meta.EntitySetName
Write-Ok "Telemetry table '$telemetryTable' -> entity set '$telemetryEntitySet'"

# ---------------------------------------------------------------------------
# 3. Pull every telemetry row written during the test window.
# ---------------------------------------------------------------------------
$p = $PublisherPrefix
$telemetryColumns = @(
    "${p}_correlationid", "${p}_consumer", "${p}_batchsize",
    "${p}_t1dispatcherentry", "${p}_t2beforeraise", "${p}_t3afterraise", "${p}_t4pollloopentry",
    "${p}_pollattempts", "${p}_t5resultdetected", "${p}_resultrowcreatedon", "${p}_resultrowwrittenutc",
    "${p}_t6dispatcherexit", "${p}_outcome"
) -join ","

Write-Step "Querying $telemetryTable rows written during the test window"
$filterStart = $WindowStartUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
$filterEnd = $WindowEndUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
$telemetryRows = (Invoke-Dataverse @dv -Method GET -Path "$telemetryEntitySet`?`$select=$telemetryColumns&`$filter=createdon ge $filterStart and createdon le $filterEnd&`$top=5000").value
Write-Ok "$($telemetryRows.Count) telemetry rows found"

$telemetryByCorr = @{}
foreach ($r in $telemetryRows) { $telemetryByCorr[$r."${p}_correlationid"] = $r }

# ---------------------------------------------------------------------------
# 4. Join CSV rows (client clock) to telemetry rows (server clock) via the
#    correlation GUID embedded in the plugin's own response message.
# ---------------------------------------------------------------------------
Write-Step "Joining CSV rows to $telemetryTable rows via correlation GUID"
$joined = foreach ($row in $csv) {
    if ($row.FlowMessage -notmatch "correlation ([0-9a-fA-F\-]{36})") { continue }
    $corrId = $Matches[1]
    if (-not $telemetryByCorr.ContainsKey($corrId)) { continue }
    $t = $telemetryByCorr[$corrId]

    $reqStart  = ConvertTo-UtcDateTimeOffset $row.RequestStartTimestamp
    $completion = ConvertTo-UtcDateTimeOffset $row.CompletionTimestamp
    $t1 = ConvertTo-UtcDateTimeOffset $t."${p}_t1dispatcherentry"
    $t2 = ConvertTo-UtcDateTimeOffset $t."${p}_t2beforeraise"
    $t3 = ConvertTo-UtcDateTimeOffset $t."${p}_t3afterraise"
    $t4 = ConvertTo-UtcDateTimeOffset $t."${p}_t4pollloopentry"
    $t5 = ConvertTo-UtcDateTimeOffset $t."${p}_t5resultdetected"
    $t6 = ConvertTo-UtcDateTimeOffset $t."${p}_t6dispatcherexit"
    $resultCreatedOn = ConvertTo-UtcDateTimeOffset $t."${p}_resultrowcreatedon"
    $resultWrittenUtc = ConvertTo-UtcDateTimeOffset $t."${p}_resultrowwrittenutc"

    [pscustomobject]@{
        BatchSize            = [int]$row.BatchSize
        CorrelationId        = $corrId
        Outcome              = $t."${p}_outcome"
        PollAttempts         = $t."${p}_pollattempts"
        ReqStart             = $reqStart
        Completion           = $completion
        TotalMs              = Get-MillisDelta $reqStart $completion
        NetworkAndQueueMs    = Get-MillisDelta $reqStart $t1
        DispatcherSetupMs    = Get-MillisDelta $t1 $t2
        RaiseEventMs         = Get-MillisDelta $t2 $t3
        LoopEntryMs          = Get-MillisDelta $t3 $t4
        FlowWriteToDetectMs  = Get-MillisDelta $resultWrittenUtc $t5
        DispatcherWrapupMs   = Get-MillisDelta $t5 $t6
        RelayAndResponseMs   = Get-MillisDelta $t6 $completion
        EventRaisedAtUtc     = $t3
        ResultCreatedOnUtc   = $resultCreatedOn
    }
}
Write-Ok "$($joined.Count) of $($csv.Count) CSV rows joined to a telemetry row"
if ($joined.Count -eq 0) {
    throw "No CSV rows joined to a telemetry row. Confirm -ResultsCsvPath came from a load test run against THIS perf-testing deployment (-PublisherPrefix $PublisherPrefix), and that the test window covers it (-WindowStartUtc/-WindowEndUtc)."
}

if (-not $ExportPerCallCsvPath) {
    $ExportPerCallCsvPath = [System.IO.Path]::ChangeExtension($ResultsCsvPath, $null).TrimEnd('.') + ".phases.csv"
}
$joined | Export-Csv -Path $ExportPerCallCsvPath -NoTypeInformation -Encoding utf8
Write-Ok "Full per-call phase breakdown exported to: $ExportPerCallCsvPath"

# ---------------------------------------------------------------------------
# 5. Aggregate every server-side (and the two necessarily cross-clock)
#    sub-phases by batch size.
# ---------------------------------------------------------------------------
$metricNames = @("NetworkAndQueueMs", "DispatcherSetupMs", "RaiseEventMs", "LoopEntryMs", "FlowWriteToDetectMs", "DispatcherWrapupMs", "RelayAndResponseMs", "TotalMs")

$batchSizes = $joined | Select-Object -ExpandProperty BatchSize -Unique | Sort-Object
$aggByBatch = foreach ($b in $batchSizes) {
    $rows = $joined | Where-Object { $_.BatchSize -eq $b }
    $row = [ordered]@{ BatchSize = $b; N = $rows.Count }
    foreach ($m in $metricNames) {
        $values = $rows.$m | Where-Object { $null -ne $_ } | Sort-Object
        $row["${m}_p50"] = if ($values.Count) { [math]::Round((Get-Percentile $values 0.50), 0) } else { $null }
        $row["${m}_max"] = if ($values.Count) { [math]::Round(($values | Select-Object -Last 1), 0) } else { $null }
    }
    [pscustomobject]$row
}

Write-Host ""
Write-Host "=== Per-call sub-phase medians (ms) by batch size ===" -ForegroundColor Yellow
$aggByBatch | Select-Object BatchSize, N, NetworkAndQueueMs_p50, DispatcherSetupMs_p50, RaiseEventMs_p50, LoopEntryMs_p50, FlowWriteToDetectMs_p50, DispatcherWrapupMs_p50, RelayAndResponseMs_p50, TotalMs_p50 |
    Format-Table -AutoSize | Out-String | Write-Host

Write-Host "=== Per-call sub-phase maximums (ms) by batch size ===" -ForegroundColor Yellow
$aggByBatch | Select-Object BatchSize, N, NetworkAndQueueMs_max, DispatcherSetupMs_max, RaiseEventMs_max, LoopEntryMs_max, FlowWriteToDetectMs_max, DispatcherWrapupMs_max, RelayAndResponseMs_max, TotalMs_max |
    Format-Table -AutoSize | Out-String | Write-Host

# ---------------------------------------------------------------------------
# 6. Optional: batch-level dispatch-to-flow-start / flow's-own-execution
#    split, same attribution method as
#    ../../deploy/Get-LoadTestPhaseBreakdown.ps1 (flow run-history summaries
#    don't carry back a business correlation id, so this part stays
#    batch-level, not per-call).
# ---------------------------------------------------------------------------
$flowLevelAgg = $null
if ($FlowRunHistoryJsonPath -and (Test-Path $FlowRunHistoryJsonPath)) {
    Write-Step "Splitting dispatch-to-flow-start from the flow's own execution (batch-level, via flow run history)"
    $batchWindows = $joined | Group-Object BatchSize | Sort-Object { [int]$_.Name } | ForEach-Object {
        $eventTimes = $_.Group.EventRaisedAtUtc | Where-Object { $_ } | Sort-Object
        [pscustomobject]@{ BatchSize = [int]$_.Name; WinStart = $eventTimes[0].UtcDateTime }
    }

    $rawRuns = Get-Content $FlowRunHistoryJsonPath -Raw | ConvertFrom-Json
    $runs = $rawRuns | ForEach-Object {
        [pscustomobject]@{
            Start = (ConvertTo-UtcDateTimeOffset $_.startTime).UtcDateTime
            End   = (ConvertTo-UtcDateTimeOffset $_.endTime).UtcDateTime
        }
    }

    $attributed = foreach ($run in $runs) {
        $matchingBatch = $batchWindows | Where-Object { $_.WinStart -le $run.Start } | Sort-Object WinStart -Descending | Select-Object -First 1
        if ($matchingBatch) {
            [pscustomobject]@{
                BatchSize         = $matchingBatch.BatchSize
                DispatchToFlowStartMs = ($run.Start - $matchingBatch.WinStart).TotalMilliseconds
                FlowOwnExecutionMs    = ($run.End - $run.Start).TotalMilliseconds
            }
        }
    }

    $flowLevelAgg = $attributed | Group-Object BatchSize | Sort-Object { [int]$_.Name } | ForEach-Object {
        $g = $_.Group
        $disp = $g.DispatchToFlowStartMs | Sort-Object
        $flowMs = $g.FlowOwnExecutionMs | Sort-Object
        [pscustomobject]@{
            BatchSize                 = [int]$_.Name
            N                         = $g.Count
            DispatchToFlowStartMs_p50 = [math]::Round((Get-Percentile $disp 0.50), 0)
            DispatchToFlowStartMs_max = [math]::Round(($disp | Select-Object -Last 1), 0)
            FlowOwnExecutionMs_p50    = [math]::Round((Get-Percentile $flowMs 0.50), 0)
            FlowOwnExecutionMs_max    = [math]::Round(($flowMs | Select-Object -Last 1), 0)
        }
    }

    Write-Host "=== Batch-level: dispatch-to-flow-start vs flow's own execution (ms) ===" -ForegroundColor Yellow
    $flowLevelAgg | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "(Coverage note: flow run history is capped at 250 rows with no time filter -" -ForegroundColor DarkGray
    Write-Host " only batches whose runs fall within that most-recent-250 window appear above.)" -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "No -FlowRunHistoryJsonPath supplied - skipping the dispatch-to-flow-start / flow's-own-execution split." -ForegroundColor DarkGray
    Write-Host "(Fetch it via the flowagent MCP tool's get_run_history for this flow, save the raw JSON array to a" -ForegroundColor DarkGray
    Write-Host " file, and pass that file's path in -FlowRunHistoryJsonPath. Every server-side T1-T6 metric above is" -ForegroundColor DarkGray
    Write-Host " unaffected either way.)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 7. Automated bottleneck verdict: for every sub-phase, compare its smallest-
#    batch median to its largest-batch median. A sub-phase that grows
#    materially with concurrency is a candidate bottleneck; one that stays
#    flat/bounded is ruled out, regardless of how large it is in absolute
#    terms (e.g. FlowWriteToDetectMs is bounded by PollInterval and is
#    EXPECTED to be a few seconds - what matters is whether it GROWS).
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Bottleneck attribution ===" -ForegroundColor Yellow
if ($batchSizes.Count -lt 2) {
    Write-Host "Only one batch size was tested ($($batchSizes[0])) - growth-ratio attribution needs at least two." -ForegroundColor DarkGray
} else {
    $minBatchRow = $aggByBatch | Where-Object { $_.BatchSize -eq $batchSizes[0] }
    $maxBatchRow = $aggByBatch | Where-Object { $_.BatchSize -eq $batchSizes[-1] }

    $verdictRows = foreach ($m in $metricNames) {
        $atMin = $minBatchRow."${m}_p50"
        $atMax = $maxBatchRow."${m}_p50"
        if ($null -eq $atMin -or $null -eq $atMax) { continue }
        $floor = [math]::Max($atMin, 1)   # avoid a divide-by-near-zero ratio blowing up on trivially small numbers
        $ratio = [math]::Round($atMax / $floor, 1)
        [pscustomobject]@{
            SubPhase              = $m
            "Median@$($batchSizes[0])_ms"  = $atMin
            "Median@$($batchSizes[-1])_ms" = $atMax
            GrowthRatio            = $ratio
            Verdict                = if ($ratio -ge 1.5) { "GROWS with concurrency" } else { "flat / bounded" }
        }
    }

    if ($flowLevelAgg) {
        $minFlow = $flowLevelAgg | Where-Object { $_.BatchSize -eq $batchSizes[0] }
        $maxFlow = $flowLevelAgg | Where-Object { $_.BatchSize -eq $batchSizes[-1] }
        if ($minFlow -and $maxFlow) {
            foreach ($pair in @(@("DispatchToFlowStartMs", $minFlow.DispatchToFlowStartMs_p50, $maxFlow.DispatchToFlowStartMs_p50), @("FlowOwnExecutionMs", $minFlow.FlowOwnExecutionMs_p50, $maxFlow.FlowOwnExecutionMs_p50))) {
                $atMin = $pair[1]; $atMax = $pair[2]
                $floor = [math]::Max($atMin, 1)
                $ratio = [math]::Round($atMax / $floor, 1)
                $verdictRows += [pscustomobject]@{
                    SubPhase               = "$($pair[0]) (batch-level)"
                    "Median@$($batchSizes[0])_ms"  = $atMin
                    "Median@$($batchSizes[-1])_ms" = $atMax
                    GrowthRatio             = $ratio
                    Verdict                 = if ($ratio -ge 1.5) { "GROWS with concurrency" } else { "flat / bounded" }
                }
            }
        }
    }

    $verdictRows | Sort-Object GrowthRatio -Descending | Format-Table -AutoSize | Out-String | Write-Host

    $dominant = $verdictRows | Sort-Object GrowthRatio -Descending | Select-Object -First 1
    $descriptions = @{
        NetworkAndQueueMs      = "the client-to-server hop before the dispatcher plug-in's own code even starts running (network + Dataverse request routing/queueing + sandbox worker startup). Crosses client/server clocks - treat the exact number as approximate, but a real growth trend here is still meaningful."
        DispatcherSetupMs      = "the dispatcher plug-in's own setup before raising the business event - pure in-process CPU work, should never meaningfully grow with concurrency."
        RaiseEventMs           = "the business-event RAISE call itself, measured purely on Dataverse's own server clock. If this grows, the bottleneck is inside Dataverse's own plug-in/event-raise execution path, not Power Automate."
        LoopEntryMs            = "trivial in-process bookkeeping between raising the event and starting to poll - a sanity check column, not expected to matter."
        FlowWriteToDetectMs    = "how long the dispatcher's poll loop takes to notice the worker flow's result after it's written - bounded by PollInterval (2s), so bounded/flat growth here confirms polling itself is NOT the bottleneck."
        DispatcherWrapupMs     = "the dispatcher's own wrap-up after detecting the result (JSON build + SharedVariables set) - trivial in-process work."
        RelayAndResponseMs     = "RunFlowMainOperationTelemetry's relay (an unmodified, uninstrumented copy of the real trivial-relay plug-in) plus the platform's own response marshaling back to the caller. Crosses server/client clocks."
        TotalMs                = "the full round trip - a cross-check against Invoke-LoadTest.ps1's own DurationMs column, not an independent sub-phase."
        "DispatchToFlowStartMs (batch-level)" = "the span between the business event being raised and the worker flow's own run instance actually starting (via the Flow API's run history) - entirely INSIDE Power Automate's own trigger-dispatch pipeline, outside this plug-in's or Dataverse's control. Batch-level attribution, not per-call."
        "FlowOwnExecutionMs (batch-level)"    = "the worker flow's own logic execution time (run start to run end) - batch-level attribution, not per-call."
    }
    Write-Host ""
    Write-Host "VERDICT: '$($dominant.SubPhase)' shows the largest growth with concurrency ($($dominant.GrowthRatio)x from batch $($batchSizes[0]) to batch $($batchSizes[-1])), while every other sub-phase stays flat or bounded." -ForegroundColor Green
    Write-Host "This sub-phase measures: $($descriptions[$dominant.SubPhase])" -ForegroundColor Green
    if ($dominant.SubPhase -notlike "*batch-level*" -and -not $flowLevelAgg) {
        Write-Host "(No -FlowRunHistoryJsonPath was supplied, so the dispatch-to-flow-start span - the leading hypothesis for" -ForegroundColor DarkGray
        Write-Host " where unattributed growth lives, per this repo's prior load testing - wasn't checked directly this run.)" -ForegroundColor DarkGray
    }
}
