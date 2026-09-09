# Perf-testing: precise bottleneck telemetry

A fully separate, side-by-side copy of the Flow Trigger solution, instrumented to
answer one question with hard, per-call evidence: **which specific part of the
round trip actually grows as concurrency increases?**

Nothing under `plugin/`, `deploy/`, or `docs/` is modified by anything in this
folder. Every file here is either a new, perf-testing-only file, or an
instrumented **copy** of an existing one - the production plug-in assembly and
deploy scripts are never rebuilt, touched, or redeployed by this folder's tooling.

## Why a separate deployment

The instrumented plug-in writes one extra database row per call (to a new
telemetry table) and the worker flow writes one extra column. Deploying this
under its own publisher prefix (`flowperf` by default) means:

- The real `flowtrig_`-prefixed (or whatever prefix you use) production
  deployment is completely unaffected - different tables, different Custom
  APIs, different plug-in assembly.
- Side-by-side deployment to the same environment under a different prefix is
  already proven safe by this repo's own history.
- Deleting everything afterward is a single, contained cleanup (see
  [Tearing it down](#tearing-it-down)) - nothing to reconcile against production.

## What's instrumented, and why

The production plug-in (`RunFlowDispatcher.cs`) is a black box from the
outside: you can see the caller's total round-trip time, and (with flow run
history) when the worker flow itself ran - but not what happened *inside* the
plug-in's own execution, or how much of the total time was spent where.

`RunFlowDispatcherTelemetry.cs` (the instrumented copy) captures six UTC
timestamps at the meaningful points in its own execution, plus a poll-attempt
counter, and writes them - along with the worker flow's own precise write
timestamp - to a new `<prefix>_calltelemetry` table:

```
Caller                Dispatcher plug-in (PreValidation)              Worker flow
  |                          |                                             |
  |--- HTTP request -------->|                                             |
  |                        T1 (dispatcher entry)                          |
  |                          |-- setup --                                  |
  |                        T2 (before raise)                               |
  |                          |-- raises business event -------------------->|
  |                        T3 (after raise)                     [Power Automate's own
  |                          |                                   trigger-dispatch pipeline -
  |                        T4 (poll loop entry, ~= T3)            NOT instrumented by this
  |                          |-- polls flowresult table --        plug-in; only visible via
  |                          |   every 2s ...                     Flow run history]
  |                          |                                             |
  |                          |                                    flow runs, writes result
  |                          |                                    row + precise WrittenUtc
  |                          |<-- poll detects the row --------------------|
  |                        T5 (result detected)
  |                          |-- wrap-up (JSON + SharedVariables) --
  |                        T6 (dispatcher exit)
  |                          |-- writes ONE row to <prefix>_calltelemetry --
  |                          |-- RunFlowMainOperationTelemetry relay ------->
  |<-- HTTP response --------|                     (unmodified, uninstrumented copy)
```

| Sub-phase | Span | Clock | What it means if it grows |
|---|---|---|---|
| `NetworkAndQueueMs` | client request sent → T1 | client → server (crosses clock domains) | Network, or Dataverse's own request routing/queueing/sandbox-worker startup, is slowing down under load |
| `DispatcherSetupMs` | T1 → T2 | server-only | In-process CPU work before raising the event is slowing down (unexpected - pure computation) |
| `RaiseEventMs` | T2 → T3 | server-only | **The raise-event call itself** is slowing down - would point at Dataverse's own plug-in/event-raise execution path, not Power Automate |
| `LoopEntryMs` | T3 → T4 | server-only | Sanity check only - should always be ~0 |
| *(external)* dispatch-to-flow-start | T3/T4 → the worker flow's own run start (Flow run history) | server (Dataverse) → Power Automate's flow-runtime clock | **This is the one span this plug-in cannot instrument directly.** If this grows while everything above stays flat, the bottleneck is proven to live entirely inside Power Automate's own trigger-dispatch pipeline |
| flow's own execution | flow run start → end (Flow run history) | Power Automate's own clock | The worker flow's own logic is slowing down |
| `FlowWriteToDetectMs` | flow's precise `WrittenUtc` → T5 | flow → server (crosses clock domains, both near-simultaneous typically) | True poll-detect latency - bounded by `PollInterval` (2s); should stay flat/bounded regardless of concurrency |
| `DispatcherWrapupMs` | T5 → T6 | server-only | Sanity check only - trivial JSON build + `SharedVariables` set |
| `RelayAndResponseMs` | T6 → client response received | server → client (crosses clock domains) | `RunFlowMainOperationTelemetry`'s relay (an **unmodified, uninstrumented** copy of the real trivial-relay plug-in) plus platform response marshaling is slowing down |
| `TotalMs` | client request sent → client response received | client-only | Cross-check against `Invoke-LoadTest.ps1`'s own `DurationMs` column - not an independent sub-phase |

Every T1-T6 delta is read from the **same plug-in execution's own clock**, so
those deltas are clock-skew-free. The three spans marked "crosses clock
domains" above are still useful for spotting large, concurrency-driven growth
- just not for sub-second-exact absolute comparisons.

**A broken telemetry write never breaks the caller's response.** The write to
`<prefix>_calltelemetry` is wrapped in its own try/catch in
`RunFlowDispatcherTelemetry.cs` - if it fails for any reason, the failure is
traced and the call still returns its normal result.

`RunFlowMainOperationTelemetry.cs` is a byte-for-byte-equivalent, **uninstrumented**
copy of the real relay plug-in - it does no extra work and records no
timestamps of its own. The entire point of `RelayAndResponseMs` is to measure
the real trivial-relay step's actual cost; adding instrumentation to it would
make it measure this test harness instead of the production design.

## What's new vs. what's reused

| | New (perf-testing-only) | Reused unchanged |
|---|---|---|
| Plug-in | `RunFlowDispatcherTelemetry.cs`, `RunFlowMainOperationTelemetry.cs`, own `.csproj` | - |
| Deploy | `Deploy-PerfTestEnvironment.ps1` (a copy of `../deploy/Deploy-FlowTriggerSolution.ps1` - see below for why), `Create-PerfTestWorkerFlow.ps1`, `Get-PerfTestBreakdown.ps1`, `Invoke-PerfTestWarmLoadTest.ps1`, `New-PerfTestIdentities.ps1`, `Invoke-PerfTestMultiIdentityLoadTest.ps1`, `consumers.perftest.json` | `../deploy/DvHelper.psm1`, `../deploy/Invoke-LoadTest.ps1` (run exactly as-is against this deployment for the COLD/baseline comparison) |

`Deploy-PerfTestEnvironment.ps1` had to be a genuine copy, not just a differently-parameterized
invocation: the real script's plugin-assembly/plugin-type lookups use hardcoded literal names
("FlowTrigger.Plugins", "FlowTrigger.Plugins.RunFlowDispatcher") rather than deriving them from
whichever assembly is actually being deployed. Pointing the real script at this repo's
differently-named, independently-signed `FlowTrigger.Plugins.PerfTest.dll` would find the
*production* pluginassemblies record (same hardcoded name) and try to PATCH its content -
which Dataverse rejects outright ("Plugin Assembly fully qualified name has changed"). The copy
fixes just those name references; every other line is unchanged from the real script.

## Deploying

```powershell
# 1. Build the instrumented plugin
dotnet build perf-testing\plugin\FlowTrigger.Plugins.PerfTest.csproj -c Release

# 2. Deploy the side-by-side environment (publisher/solution/tables/Custom APIs +
#    the two perf-testing-only additions: <prefix>_flowresult.writtenutc and the
#    new <prefix>_calltelemetry table)
.\perf-testing\deploy\Deploy-PerfTestEnvironment.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com

# 3. Create and activate the worker flow (needs a pre-existing, interactively
#    consented shared_commondataserviceforapps connection - same requirement as
#    ../deploy/Create-WorkerFlow.ps1)
.\perf-testing\deploy\Create-PerfTestWorkerFlow.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer Default -ConnectionName <connection-name> -Activate
```

## Running the load test and analyzing it

```powershell
# Reuse the real load-test harness UNCHANGED, just pointed at this deployment
.\deploy\Invoke-LoadTest.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer Default -PublisherPrefix flowperf -ResultsCsvPath .\perf-testing\deploy\perftest-load-results.csv

# Decompose the results into sub-phases and get the automated bottleneck verdict
.\perf-testing\deploy\Get-PerfTestBreakdown.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -ResultsCsvPath .\perf-testing\deploy\perftest-load-results.csv
```

Add `-FlowRunHistoryJsonPath <file>` (a raw JSON array of
`name`/`startTime`/`endTime`/`status` per run, e.g. from the flowagent MCP
tool's `get_run_history`) to also include the worker flow's own
dispatch-to-start and execution-time split. That split is necessarily
**batch-level**, not per-call - Flow run-history summaries don't carry back
this solution's own business correlation id - whereas every T1-T6 metric above
is precise per individual call.

## Reading the output

`Get-PerfTestBreakdown.ps1` prints, in order:

1. Per-call sub-phase **medians** by batch size.
2. Per-call sub-phase **maximums** by batch size.
3. (If flow run history was supplied) the batch-level dispatch-to-flow-start
   / flow's-own-execution split.
4. **Bottleneck attribution**: for every sub-phase, the median at the smallest
   and largest batch size tested, the growth ratio between them, and a
   Flat/Grows verdict (≥1.5x = grows). Sorted so the largest-growth sub-phase
   is first.
5. A one-paragraph plain-English **verdict** naming the dominant sub-phase and
   explaining what it means.

The full per-call join (every metric, every row) is also exported to
`<ResultsCsvPath>.phases.csv` for your own further analysis.

## Tearing it down

Everything this folder creates lives under the `flowperf` publisher prefix (or
whatever `-PublisherPrefix` you passed) in its own `FlowTriggerPerfTest`
solution - delete that solution in the target environment (Power Platform
Admin Center, or `Invoke-Dataverse -Method DELETE -Path "solutions(<id>)"`) to
remove every table, Custom API, plug-in registration, and Security Role this
folder created in one step. This does not touch the production solution at
all, since it's a completely separate solution/publisher.

Known side effect: the per-consumer Security Role name
(`Flow Trigger Caller - <Consumer>`) is not publisher-prefix-qualified in the
real, unmodified `Deploy-FlowTriggerSolution.ps1` - so a perf-testing
consumer with the same id as a production consumer (e.g. "Default") shares
that role object with production rather than getting its own. This is a
pre-existing characteristic of the real script (not introduced by this
folder) and has no bearing on any telemetry measurement - it just means the
role isn't as fully isolated as the tables/Custom APIs/plug-in are.

If you ran the multi-identity follow-up test, also clean up the throwaway
Azure AD app registrations it created (`az ad app list --display-name
CopilotPerfTest-Identity- --query "[].appId" -o tsv | ForEach-Object { az ad
app delete --id $_ }` deletes all of them at once) and delete
`$env:TEMP\perftest-identities.json`.

## Findings from the first live run (flowtrigger-prod, 10-100 concurrent calls)

**The growth is not inside this solution's code.** Every server-side sub-phase
inside the plug-in stayed flat regardless of concurrency:

| Sub-phase | @ batch 10 | @ batch 100 | Verdict |
|---|---|---|---|
| Dispatcher's own setup | 16ms | 0ms | flat |
| The raise-event call itself | 156ms | 31ms | flat |
| Poll-detect latency | 1.1s | 1.2s | flat (bounded by `PollInterval`) |
| Dispatcher wrap-up | 0ms | 0ms | flat |
| Relay + response marshaling | 2.5s | 2.5s | flat (constant, not scaling) |
| Flow's own execution logic | 279ms | 227ms | flat |
| Client sends request → plug-in's first line runs | ~0s | ~26s | **grows** |
| Event raised → worker flow's run actually starts | 3.2s | 28.1s | **grows** |

100% of the round-trip's growth (4.4x, 6.9s → 30.2s median) sits in those last
two rows - before the plug-in starts, and between the event being raised and
the flow starting. Not in polling, not in the flow's own logic, not in the relay.

### Follow-up: is it network/TLS, or Dataverse's own admission queue?

Those two growing spans blend network/TLS connection-establishment cost with
Dataverse's own server-side request-admission queueing, and timestamps alone
can't separate them. `Invoke-PerfTestWarmLoadTest.ps1` runs a controlled
comparison: it fires the same number of concurrent `WhoAmI` GET calls (cheap,
no plug-in execution) immediately before each real batch, to pre-establish
that many TCP+TLS connections in the shared connection pool, so the real
batch's calls can reuse already-warm connections instead of negotiating new
ones.

**Result: pre-warming connections made no difference - if anything, the warm
run was slightly slower at every batch size** (e.g. batch 100 median: 30.2s
cold vs. 37.2s warm; `NetworkAndQueueMs` median: 25.7s cold vs. 32.7s warm).
If connection establishment were the driver, warm connections should have
shown a clear improvement. Since they didn't, **TCP/TLS setup is ruled out**,
and the bottleneck is conclusively **Dataverse's own server-side admission
queue for this identity's concurrent synchronous requests** - not a
client-side or network artifact. (The warm run being slightly *slower* is
consistent with the warm-up burst itself competing for the same per-identity
concurrency budget as the real calls that immediately follow it.)

```powershell
.\Invoke-PerfTestWarmLoadTest.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer Default -PublisherPrefix flowperf
.\Get-PerfTestBreakdown.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -ResultsCsvPath .\perftest-warm-load-results.csv
# Compare NetworkAndQueueMs against the earlier cold-connection run at matching batch sizes.
```

## Follow-up: does spreading load across multiple calling identities help?

Dataverse's service protection limits - including the concurrent-request limit
(default 52 per web server) - are documented as evaluated **per authenticated
user, independently**:
https://learn.microsoft.com/power-apps/developer/data-platform/api-limits.
Since the bottleneck above was isolated to a per-identity admission delay, the
natural follow-up is: does splitting the SAME total concurrency across
multiple calling identities avoid it?

`New-PerfTestIdentities.ps1` creates N throwaway Azure AD service principals +
Dataverse Application Users, each granted the same `Flow Trigger Caller -
<Consumer>` role a real caller would need. Credentials are written to
`$env:TEMP\perftest-identities.json` - **outside this repository, never
committed** - since they're real, usable client secrets.
`Invoke-PerfTestMultiIdentityLoadTest.ps1` then acquires one `client_credentials`
token per identity and round-robins a batch's calls across however many
identities you select:

```powershell
.\New-PerfTestIdentities.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -TenantId $tenantId -IdentityCount 10

.\Invoke-PerfTestMultiIdentityLoadTest.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -IdentitiesJsonPath $env:TEMP\perftest-identities.json -IdentityCount 2  -BatchSizes 100
.\Invoke-PerfTestMultiIdentityLoadTest.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -IdentitiesJsonPath $env:TEMP\perftest-identities.json -IdentityCount 4  -BatchSizes 100
.\Invoke-PerfTestMultiIdentityLoadTest.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -IdentitiesJsonPath $env:TEMP\perftest-identities.json -IdentityCount 10 -BatchSizes 100
```

**Result: yes, decisively.** Holding total concurrency fixed at 100 calls and
only varying how many identities they're split across:

| Identities | Median (ms) | Max (ms) | `NetworkAndQueueMs` median |
|---|---|---|---|
| 1 (baseline) | 30,322 | 58,738 | +25,700ms |
| 2 | 11,532 | 14,516 | - |
| 4 | 9,068 | 13,250 | **-1,698ms** |
| 10 | 9,217 | 10,095 | - |

With just 2 identities (50 calls each), median round-trip time dropped 2.6x.
By 4 identities (25 calls each), `NetworkAndQueueMs` - the exact span that grew
to +25.7 **seconds** with a single identity at this same batch size - collapsed
back to **-1,698ms, statistically indistinguishable from the completely
unloaded baseline** (-688ms, batch size 10, single identity). 4 and 10
identities land within ~150ms of each other, confirming the improvement
plateaus once each identity's own share of the batch drops comfortably under
Dataverse's documented per-identity concurrent-request threshold - splitting
further stops helping because there's no more per-identity contention left to
relieve.

**Practical implication:** for a design that needs to sustain higher genuine
concurrency than a single caller identity comfortably supports, distributing
calls across multiple service principals (each with its own Caller role
grant) is a direct, effective mitigation - not a workaround for a flaw in this
solution's own code, but the intended way Dataverse expects high-concurrency
callers to scale, per its own documented service-protection model.
