# Performance and concurrency

This document summarizes measured latency and concurrency behavior for this pattern.
For the full instrumented methodology, raw data, and reproduction steps, see
[perf-testing/README.md](../perf-testing/README.md).

## Expected latency

A single call completes in **single-digit seconds** end to end (Custom API call →
business event → worker flow run → poll-detect → response). If a call instead lands
at/near whatever `PollBudget` is configured, that indicates a configuration problem
(see [README.md — Test](../README.md#test)), not normal behavior.

## Concurrency limit: per calling identity, not per environment

Dataverse's service protection limits — including the concurrent-request limit
(default 52 per web server) — are enforced **per authenticated calling identity,
independently**, not against the environment as a whole
([Microsoft Learn: API limits](https://learn.microsoft.com/power-apps/developer/data-platform/api-limits)).
A single identity sending a large number of truly concurrent requests will queue
behind that identity's own limit; a different identity calling at the same time is
unaffected.

## Where latency growth actually happens under load

Instrumented testing (10–100 concurrent calls from a single identity, same
environment) shows every phase inside this solution's own code stays flat regardless
of concurrency:

| Phase | @ 10 concurrent | @ 100 concurrent | Verdict |
|---|---|---|---|
| Dispatcher setup (in-process) | 16 ms | 0 ms | flat |
| Raise business event | 156 ms | 31 ms | flat |
| Poll-detect latency (bounded by `PollInterval`) | 1.1 s | 1.2 s | flat |
| Dispatcher wrap-up | 0 ms | 0 ms | flat |
| Relay + response marshaling | 2.5 s | 2.5 s | flat |
| Worker flow's own execution logic | 279 ms | 227 ms | flat |
| Request sent → dispatcher plug-in starts running | ~0 s | ~26 s | **grows** |
| Event raised → worker flow's run actually starts | 3.2 s | 28.1 s | **grows** |

100% of the round-trip growth (4.4x, 6.9s → 30.2s median) is in the last two rows —
time spent before this solution's plug-in code starts, and time spent between the
event firing and the worker flow's run starting. A controlled warm-vs-cold-connection
comparison ruled out TCP/TLS negotiation as the cause. Both growing spans are
consistent with Dataverse's own per-identity request-admission queue, matching the
documented behavior above.

## Scaling beyond a single identity

Since the limit is per identity, splitting the same total concurrency across multiple
calling identities removes the queueing. Holding total concurrency fixed at 100 calls
and only varying how many identities they're split across:

| Identities | Median | Max | Queueing delay (`NetworkAndQueueMs` median) |
|---|---|---|---|
| 1 | 30.3 s | 58.7 s | +25.7 s |
| 2 | 11.5 s | 14.5 s | — |
| 4 | 9.1 s | 13.3 s | -1.7 s (baseline) |
| 10 | 9.2 s | 10.1 s | — |

With 4+ identities (25 or fewer calls per identity in this test), queueing delay drops
to the same level as a completely unloaded baseline. Improvement plateaus once each
identity's share of the batch is comfortably under the per-identity threshold — beyond
that point there is no more per-identity contention left to relieve.

**If an integration needs to sustain concurrency beyond what one calling identity
comfortably supports, distribute calls across multiple service principals, each
granted its own Caller role membership** (see
[PERMISSIONS.md — Caller access](PERMISSIONS.md#caller-access-who-may-invoke-the-trigger)).
This is the scaling model Dataverse's service protection limits are designed around,
not a workaround for a limitation in this solution.
