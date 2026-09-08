# Architecture

This document is the authoritative reference for the synchronous Dataverse → business
event → Power Automate worker-flow pattern implemented in this repo: the components it
creates, the exact Custom API and plug-in-step field values it depends on, and the
transaction model that makes synchronous request/response possible.

For caller-access models, trigger-picker visibility controls, and security notes, see
[PERMISSIONS.md](PERMISSIONS.md). For build, deploy, and test steps, see the root
[README.md](../README.md).

## Components created per environment

| Component | Logical/Unique name | Notes |
|---|---|---|
| Publisher | `flowtrigger` (prefix `flowtrig`) | Reused if it already exists |
| Solution | `FlowTriggerActionDemo` | Unmanaged. Every component below is added to it via the `MSCRM.SolutionUniqueName` request header at create time |
| Table | `flowtrig_flowresult` | Columns: `flowtrig_correlationid`, `flowtrig_status`, `flowtrig_message`, `flowtrig_messagename` (+ default primary `flowtrig_flowresult_name`). Worker flows write a row here; the plug-in polls for a matching `flowtrig_correlationid` using an elevated/system service context, so no caller privilege on this table is required or granted |
| Plug-in assembly | `FlowTrigger.Plugins` | Sandbox isolation, Database source type (assembly content stored in Dataverse, not disk). One assembly serves every consumer in every environment |
| Plug-in type | `FlowTrigger.Plugins.RunFlowDispatcher` | Does all the real work (auth checks, raise event, poll `flowtrig_flowresult`). Registered as an explicit `sdkmessageprocessingstep` at **Stage 10 (PreValidation)**, **Mode 0 (Synchronous)**, on each consumer's caller message — not bound via `CustomAPI.PluginTypeId`. See [Two-stage plug-in design](#two-stage-plug-in-design) for why this stage is load-bearing |
| Plug-in type | `FlowTrigger.Plugins.RunFlowMainOperation` | Trivial relay: copies `context.SharedVariables["FlowTrigger_OutputJson"]` (written by `RunFlowDispatcher`) into `context.OutputParameters["OutputJson"]`. This is the type bound via `CustomAPI.PluginTypeId` (Main Operation, stage 30) |
| Catalog (root) | `flowtrig_FlowTriggerActionDemo` | Represents the solution, per the [Business Events](https://learn.microsoft.com/power-apps/developer/data-platform/business-events) model |
| Catalog (category) | `flowtrig_FlowEvents` | Child of the root (`parentcatalogid`); every consumer's event Custom API is assigned here (except a hidden consumer — see [PERMISSIONS.md](PERMISSIONS.md#mitigation-c-hidden-uncataloged-consumer)) |
| Per consumer: marker table | `flowtrig_ep_<slug>` | Exists purely to mint an independent Dataverse privilege for this consumer — never stores data. See [PERMISSIONS.md](PERMISSIONS.md) |
| Per consumer: caller Custom API | `flowtrig_RunFlow[_Consumer]` | Global action. Input: `InputJson` (string). Output: `OutputJson` (string). `PluginTypeId` bound to `RunFlowMainOperation` (Main Operation). `AllowedCustomProcessingStepType = 2` (Sync and Async) — required so `RunFlowDispatcher`'s separate PreValidation step can be registered on this same message at all; see [The `AllowedCustomProcessingStepType` immutability constraint](#the-allowedcustomprocessingsteptype-immutability-constraint). `ExecutePrivilegeName` is the consumer's marker-table privilege — see [PERMISSIONS.md](PERMISSIONS.md) |
| Per consumer: event Custom API | `flowtrig_OnFlowRequested[_Consumer]` | Global action, no plug-in. Input: `InputJson`, `CorrelationId` (both optional strings). `AllowedCustomProcessingStepType = AsyncOnly`, per Microsoft's guidance for the business-events pattern. `ExecutePrivilegeName` is set to the **same** marker-table privilege as the caller Custom API — see [PERMISSIONS.md](PERMISSIONS.md) for why |
| Per consumer: catalog assignment | `flowtrig_OnFlowRequested[_Consumer]_Assignment` | Links the event Custom API into the `Flow Events` category so it's selectable in Power Automate's "When an action is performed" trigger. Omitted entirely for a hidden consumer |
| Per consumer: security role | `Flow Trigger Caller - <Consumer>` | Grants `Read` on this consumer's marker table — see [PERMISSIONS.md](PERMISSIONS.md) |

## Two-stage plug-in design

`RunFlowDispatcher` must be registered as an explicit `sdkmessageprocessingstep` at the
**PreValidation** stage, not bound as the caller Custom API's Main Operation
implementation. Binding it as Main Operation reintroduces a transaction deadlock,
described below.

### Symptom if misconfigured

If `RunFlowDispatcher` is registered as the caller Custom API's Main Operation instead
of at PreValidation, every real end-to-end call reaches the configured
`RunFlowDispatcher.PollBudget` exactly (85s budget → ~91s; 100s → ~101–105s; 110s →
~112s) and returns a `Timeout` response. The worker flow itself completes correctly
(right correlation id, right echoed input) a few seconds after the caller has already
received the timeout — the delay tracks the configured poll budget precisely because
that is what gates when the underlying deadlock resolves.

### Root cause

Per Microsoft's documented pipeline/transaction model
([Event framework](https://learn.microsoft.com/power-apps/developer/data-platform/event-framework),
[Scalable Customization Design: Database transactions](https://learn.microsoft.com/power-apps/developer/data-platform/scalable-customization-design/database-transactions)):

- A synchronous step registered at **PreValidation** does **not** participate in the
  core platform transaction for a top-level request with no parent transaction (the
  caller Custom API's own scenario, since it's always called directly, never nested
  inside another message) — each request it issues is committed independently.
- Steps at **PreOperation**, **Main Operation**, and synchronous **PostOperation** do
  participate in (and extend the lifetime of) that core transaction.

Binding `RunFlowDispatcher` as the caller Custom API's Main Operation implementation
(`CustomAPI.PluginTypeId`) creates a deadlock:

1. Raising `flowtrig_OnFlowRequested[_Consumer]` happens inside the same transaction as
   the whole `flowtrig_RunFlow[_Consumer]` call.
2. The async job that would deliver that event to the worker flow's trigger cannot be
   picked up by the platform until that transaction commits.
3. The transaction cannot commit until `RunFlowDispatcher.Execute()` returns.
4. `Execute()` will not return until its poll loop finds a `flowtrig_flowresult` row.
5. The poll loop can never find that row, because the flow that would write it cannot
   even start until the poll gives up and `Execute()` finally returns. At that point
   the transaction commits, the event dispatches, and the flow runs — but the result
   appears too late for the already-returned caller to see.

### Fix: two plug-in types

- **`RunFlowDispatcher`** keeps 100% of the real logic (authorization checks, raising
  the event, polling). It is registered as an explicit `sdkmessageprocessingstep`:

  | Field | Value |
  |---|---|
  | `sdkmessageid` | the caller Custom API's own auto-created message (same `name` as its `uniquename`) |
  | `plugintypeid` | `RunFlowDispatcher` |
  | `stage` | `10` (Pre-validation) |
  | `mode` | `0` (Synchronous) |
  | `sdkmessagefilterid` | *(omitted — Global-bound Custom APIs have no primary entity)* |

  It hands its computed result off via `context.SharedVariables["FlowTrigger_OutputJson"]` —
  not `context.OutputParameters` directly, since a PreValidation step's own
  `OutputParameters` writes are not reliably reflected in the eventual message response.

- **`RunFlowMainOperation`** is deliberately trivial: it does zero database I/O. It
  reads `SharedVariables["FlowTrigger_OutputJson"]` (checking `context`, then falling
  back to `context.ParentContext`, to be robust to cases where PreValidation and Main
  Operation steps do not share the exact same context instance) and copies it into
  `context.OutputParameters["OutputJson"]`. It is bound as the Custom API's
  `PluginTypeId` (Main Operation). Because it does no real work, its participation in
  the core transaction is harmless — there is nothing for that transaction to hold
  open, so it commits immediately after this trivial copy.

This drops real end-to-end round trips from ~112s (Main-Operation binding) to **~5-9s**
(PreValidation binding).

## The `AllowedCustomProcessingStepType` immutability constraint

Registering `RunFlowDispatcher`'s PreValidation step against a caller Custom API fails
outright unless that Custom API's `AllowedCustomProcessingStepType` is already `2`:

```
Custom Sdkmessageprocessingsteps are not allowed for this message.
```

`CustomAPI.AllowedCustomProcessingStepType` must be `2` ("Sync and Async") for **any**
additional plug-in step — even one from the same publisher/solution as the Custom API's
own author — to be registered on that Custom API's message at all. The default value is
`0` ("None"). This field **cannot be changed after the record is saved**.

The only fix for an already-deployed environment is to **delete and recreate** the
caller Custom API record with `allowedcustomprocessingsteptype = 2`.
`Deploy-FlowTriggerSolution.ps1` does this automatically and idempotently: it reads the
live value first, and only deletes+recreates when it isn't already `2` (a fresh
environment is created with `2` directly, no delete needed). This is safe because
nothing durable references the caller Custom API record by its GUID — security roles and
`ExecutePrivilegeName` both reference it by name, re-resolved fresh on every deploy
pass, and its request/response parameter definitions are recreated identically as part
of the same create call.

## Security implication

Splitting the plug-in this way does **not** create a window where an unauthorized caller
can trigger side effects before being denied. `ExecutePrivilegeName` enforcement is a
platform-level gate that runs **before any plug-in stage at all** — a zero-security-role
caller is denied instantly (~0.4s, the expected `prvRead<table>`-missing error), not
after a multi-second delay that would indicate PreValidation logic ran first and only
failed later at Main Operation.

## Required Dataverse configuration (exact values)

For **each** consumer's caller Custom API (`flowtrig_RunFlow[_Consumer]`):

| Field | Value | Why |
|---|---|---|
| `bindingtype` | `0` (Global) | Not bound to a specific table |
| `allowedcustomprocessingsteptype` | `2` (Sync and Async) | Required so `RunFlowDispatcher`'s PreValidation step can be registered at all (immutable after save — see above) |
| `PluginTypeId` | `RunFlowMainOperation` | Binds it as Main Operation (stage 30) |
| `executeprivilegename` | `prvRead<marker table>` | The consumer's access gate — see [PERMISSIONS.md](PERMISSIONS.md) |

For **each** consumer's `RunFlowDispatcher` registration (a real `sdkmessageprocessingstep`,
**not** the Custom API's `PluginTypeId`):

| Field | Value |
|---|---|
| `sdkmessageid` | The caller Custom API's own auto-created message (same `name` as its `uniquename`, e.g. `flowtrig_RunFlow_TeamA`) |
| `plugintypeid` | `RunFlowDispatcher` |
| `stage` | `10` (Pre-validation) |
| `mode` | `0` (Synchronous) |
| `sdkmessagefilterid` | *(omitted)* — Global-bound Custom APIs have no primary entity to filter on |

For **each** consumer's event Custom API (`flowtrig_OnFlowRequested[_Consumer]`):

| Field | Value | Why |
|---|---|---|
| `allowedcustomprocessingsteptype` | `1` (Async Only) | Recommended for the business-events pattern — subscribers (flows) only ever need to react, never block/cancel |
| `PluginTypeId` | *(none)* | Pure business event — no plug-in logic of its own |
| `executeprivilegename` | `prvRead<marker table>` — the **same** value as the caller Custom API | Prevents an unauthorized identity from bypassing the caller Custom API and invoking the event directly — see [PERMISSIONS.md](PERMISSIONS.md) |
| Catalog assignment | `catalogassignment` row pointing at this Custom API | Makes it selectable in a flow's "When an action is performed" trigger picker |

`RunFlowDispatcher.PollBudget` (110s by default) must stay comfortably under Dataverse's
~2-minute synchronous message execution cap, with headroom for request/response overhead.

## Triggering the flow and getting a synchronous response back

1. Caller does a plain Web API action call: `POST flowtrig_RunFlow[_Consumer]` with
   `{ "InputJson": "<any string>" }`.
2. Dataverse checks `ExecutePrivilegeName` before running anything — an unauthorized
   caller is rejected immediately.
3. `RunFlowDispatcher` (PreValidation) generates a `CorrelationId` (GUID), then calls
   `IOrganizationService.Execute` against the *event* Custom API
   (`flowtrig_OnFlowRequested[_Consumer]`) with `{ InputJson, CorrelationId }` — as the real
   calling user, not elevated, so they remain the actor of record.
4. That raise commits independently (no enclosing transaction at PreValidation), so the
   worker flow's trigger fires right away.
5. `RunFlowDispatcher` polls `flowtrig_flowresult` every 2s (as an elevated service)
   filtering on `flowtrig_correlationid eq '<the GUID>'`, until it finds a row or
   `PollBudget` elapses.
6. The worker flow does whatever real work it needs, then writes one row to
   `flowtrig_flowresult`: `flowtrig_correlationid` (must echo the trigger's
   `CorrelationId` exactly), `flowtrig_status`, `flowtrig_message`.
7. `RunFlowDispatcher` finds that row, builds a small JSON envelope
   (`{"status":...,"message":...}`), and stores it in `context.SharedVariables["FlowTrigger_OutputJson"]`.
8. `RunFlowMainOperation` (Main Operation, runs next in the same pipeline) reads that
   SharedVariable and sets `context.OutputParameters["OutputJson"]`.
9. The caller's original HTTP request returns `200 OK` with `{ "OutputJson": "..." }`.

If no row appears within `PollBudget`, the caller instead gets
`{"status":"Timeout","message":"The flow did not write a result within the allotted time..."}`
— still a normal `200 OK` (the mechanism did not fail; the worker flow has not
answered yet). Check the flow's run history in that case.

## Setting up a worker flow (the "consumer")

A worker flow is an ordinary Power Automate cloud flow:

- **Trigger**: Dataverse **"When an action is performed"**, bound to this consumer's
  event message (`flowtrig_OnFlowRequested[_Consumer]`). This appears in the flow
  designer once the event's `catalogassignment` exists (created automatically by
  `Deploy-FlowTriggerSolution.ps1`) — see [PERMISSIONS.md](PERMISSIONS.md) for who can
  see it in the picker.
- Read the request via `triggerBody()?['InputParameters']?['InputJson']` and
  `triggerBody()?['InputParameters']?['CorrelationId']` — the trigger's raw payload,
  not a top-level or `'schema'`-wrapped property.
- Do whatever real work the flow needs to do.
- Finish by writing exactly one row to `flowtrig_flowresult` with:
  - `flowtrig_correlationid` = the same `CorrelationId` string from the trigger, verbatim
  - `flowtrig_status` = e.g. `"Succeeded"`
  - `flowtrig_message` = whatever the caller should see back

`deploy\Create-WorkerFlow.ps1` builds this flow directly via the Dataverse `workflow`
Web API (no manual designer steps) — trigger `type: OpenApiConnectionWebhook` /
`operationId: BusinessEventsTrigger` against `shared_commondataserviceforapps`, action
`operationId: CreateRecord` into `flowtrig_flowresults`. It requires a
`shared_commondataserviceforapps` connection, already interactively consented to in the
portal by whichever identity should own the flow (`-ConnectionName` takes that
connection's name — this one consent step cannot be automated). Once that connection
exists:

```powershell
.\deploy\Create-WorkerFlow.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer Default -ConnectionName <shared-commondataser-...> -Activate
```

`-Force` deletes and recreates an existing same-named flow. The script also adds the new
flow to the `FlowTriggerActionDemo` solution automatically.

The flow's own connection identity needs `Create` privilege on `flowtrig_flowresult`
(and whatever else the flow's real work touches) — ordinary Dataverse security role
assignment for that identity; no dedicated script exists for it in this repo.

## Example: working IP firewall configuration

Example configuration under which the full mechanism (caller → plug-in → business event
→ worker flow → result poll) works with the IP firewall **enabled** (not disabled, not
audit-only):

| Field | Value |
|---|---|
| `enableipbasedfirewallrule` | `true` (enabled) |
| `enableipbasedfirewallruleinauditmode` | `false` (real enforcement, not audit-only) |
| `allowediprangeforfirewall` | `203.0.113.0/24` |
| `allowmicrosofttrustedservicetags` | `true` |
| `allowedservicetagsforfirewall` | `AzureConnectors,PowerPlatformPlex` |

Two things both matter, not just the IP allow-list: **`allowmicrosofttrustedservicetags`
+ `allowedservicetagsforfirewall` = `AzureConnectors,PowerPlatformPlex`** is what lets
Power Automate's own connector/trigger-dispatch infrastructure keep reaching this
environment's Dataverse API with the firewall on — omitting these tags while the
firewall is enabled can cause Power-Automate-service-level requests to be blocked (a
different block than a caller's own IP being rejected). When enabling the IP firewall
on a new environment for this pattern, set **both**: your callers' IPs in
`allowediprangeforfirewall`, and these two service tags enabled.

## Why polling, not a purely async design

The caller needs a synchronous response in the same request — it cannot be changed to
accept a webhook callback or poll a status endpoint itself. A Dataverse synchronous
plug-in call has a hard ~2-minute execution cap; `RunFlowDispatcher` polls every 2
seconds for up to the configured `PollBudget` (110s by default, leaving headroom for
request/response overhead) before returning a `Timeout` status. This ties up one
Dataverse sandbox worker execution slot for the duration of each call — a deliberate
trade-off for the synchronous-response requirement.

## Why a Dataverse trigger, not an HTTP trigger

A flow's HTTP trigger has its own endpoint, entirely separate from the Dataverse Web API
surface — so Dataverse's IP firewall has no effect on it. Routing the trigger through a
Custom API + plug-in keeps the entire call inside the Dataverse Web API surface, where
the IP firewall (and normal Dataverse security roles) actually apply.
