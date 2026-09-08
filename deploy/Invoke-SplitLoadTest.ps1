<#
.SYNOPSIS
    Fires a single batch of truly-concurrent calls SPLIT across TWO different
    consumers (and therefore two different worker flows) simultaneously, to test
    whether dispatch latency is a PER-FLOW bottleneck (splitting helps) or a shared,
    environment-wide dispatch resource (splitting doesn't help).

.DESCRIPTION
    Reuses the same per-task completion-polling measurement approach as
    Invoke-LoadTest.ps1. Half the batch targets ConsumerA, half targets ConsumerB,
    fired together in the same concurrent wave.

    No confident, repeatable benefit from splitting has been demonstrated - ambient
    variance in the platform's own dispatch capacity is large enough to produce an
    apparently large effect by chance alone. Run this alongside Invoke-LoadTest.ps1
    in immediate alternation, multiple times, if you want to investigate this
    further yourself.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [string] $ConsumerA = "Default",
    [string] $ConsumerB = "TeamA",
    [string] $PublisherPrefix = "flowtrig",
    [int] $CallsPerConsumer = 50,
    [int] $TimeoutSeconds = 150,
    [string] $ResultsCsvPath = (Join-Path $PSScriptRoot "split-load-test-results.csv")
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "DvHelper.psm1") -Force

# Explicit, defensive assembly load: System.Net.Http is not guaranteed to already be
# loaded into the AppDomain at this point under Windows PowerShell 5.1 (.NET
# Framework) - unlike PowerShell 7, where it's part of the always-loaded base class
# library. Relying on some earlier statement (e.g. Invoke-WebRequest inside
# DvHelper.psm1) having loaded it as a side effect is fragile and invocation-order
# dependent: the same script can fail with "Unable to find type
# [System.Net.Http.HttpClientHandler]" depending on WinPS 5.1 invocation style.
# Add-Type -AssemblyName makes this deterministic regardless of invocation
# style or session history; it's a harmless no-op if the assembly is already loaded
# (as it always is on PowerShell 7).
Add-Type -AssemblyName System.Net.Http

function Write-Step($message) { Write-Host ">> $message" -ForegroundColor Cyan }
function Write-Ok($message)   { Write-Host "   OK: $message" -ForegroundColor Green }

$callerA = if ($ConsumerA -eq "Default") { "$($PublisherPrefix)_RunFlow" } else { "$($PublisherPrefix)_RunFlow_$ConsumerA" }
$callerB = if ($ConsumerB -eq "Default") { "$($PublisherPrefix)_RunFlow" } else { "$($PublisherPrefix)_RunFlow_$ConsumerB" }

$token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null
Write-Ok "Connected - will fire $CallsPerConsumer concurrent calls to '$callerA' AND $CallsPerConsumer to '$callerB' simultaneously ($($CallsPerConsumer*2) total in one wave)"

[System.Net.ServicePointManager]::DefaultConnectionLimit = 1000
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.MaxConnectionsPerServer = 1000
$httpClient = [System.Net.Http.HttpClient]::new($handler)
$httpClient.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

function New-Request($callerName, $consumerLabel, $index) {
    $uri = "$($EnvironmentUrl.TrimEnd('/'))/api/data/v9.2/$callerName"
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
    $req.Headers.TryAddWithoutValidation("Authorization", "Bearer $token") | Out-Null
    $req.Headers.TryAddWithoutValidation("Accept", "application/json") | Out-Null
    $req.Headers.TryAddWithoutValidation("OData-MaxVersion", "4.0") | Out-Null
    $req.Headers.TryAddWithoutValidation("OData-Version", "4.0") | Out-Null
    $body = "{`"InputJson`":`"{\`"split\`":\`"$consumerLabel\`",\`"index\`":$index}`"}"
    $req.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, "application/json")
    return $req
}

Write-Step "Firing $($CallsPerConsumer*2) concurrent calls (interleaved A/B) in one wave"
$inFlight = for ($i = 0; $i -lt $CallsPerConsumer; $i++) {
    $reqA = New-Request $callerA $ConsumerA $i
    [pscustomobject]@{ Consumer=$ConsumerA; Index=$i; RequestStart=Get-Date; Task=$httpClient.SendAsync($reqA); CompletionTime=$null }
    $reqB = New-Request $callerB $ConsumerB $i
    [pscustomobject]@{ Consumer=$ConsumerB; Index=$i; RequestStart=Get-Date; Task=$httpClient.SendAsync($reqB); CompletionTime=$null }
}

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
Write-Ok "All $($inFlight.Count) calls completed"

$results = foreach ($item in $inFlight) {
    $durationMs = [math]::Round(($item.CompletionTime - $item.RequestStart).TotalMilliseconds, 1)
    $httpSuccess = $false; $httpStatus = 0; $flowStatus = $null; $flowMessage = $null; $errorText = $null
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
            } catch { $errorText = "Could not parse response: $($_.Exception.Message)" }
        } else { $errorText = $contentText }
    } catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        $errorText = $inner.Message
    }
    [pscustomobject]@{
        RequestStartTimestamp = $item.RequestStart.ToString("o")
        CompletionTimestamp   = $item.CompletionTime.ToString("o")
        Consumer              = $item.Consumer
        Index                 = $item.Index
        DurationMs            = $durationMs
        HttpSuccess           = $httpSuccess
        HttpStatusCode        = $httpStatus
        FlowStatus            = $flowStatus
        FlowMessage           = $flowMessage
        Error                 = $errorText
    }
}
$results | Export-Csv -Path $ResultsCsvPath -NoTypeInformation -Encoding utf8

function Get-Percentile($sortedArray, [double]$p) {
    if ($sortedArray.Count -eq 0) { return 0 }
    $idx = [math]::Ceiling($p * $sortedArray.Count) - 1
    $idx = [math]::Max(0, [math]::Min($idx, $sortedArray.Count - 1))
    return $sortedArray[$idx]
}

Write-Host ""
Write-Host "=== Split-load results ($ConsumerA + $ConsumerB, $CallsPerConsumer each, fired simultaneously) ===" -ForegroundColor Yellow
$results | Group-Object Consumer | ForEach-Object {
    $durs = $_.Group.DurationMs | Sort-Object
    $succeeded = @($_.Group | Where-Object { $_.HttpSuccess -and $_.FlowStatus -eq "Succeeded" })
    [pscustomobject]@{
        Consumer  = $_.Name
        Succeeded = $succeeded.Count
        Total     = $_.Group.Count
        MedianMs  = [math]::Round((Get-Percentile $durs 0.50), 0)
        P95Ms     = [math]::Round((Get-Percentile $durs 0.95), 0)
        MaxMs     = [math]::Round(($durs | Select-Object -Last 1), 0)
    }
} | Format-Table -AutoSize
Write-Host "Full results: $ResultsCsvPath" -ForegroundColor Yellow
