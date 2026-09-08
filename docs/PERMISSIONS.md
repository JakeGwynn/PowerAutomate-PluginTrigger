# Permissions

This document is the authoritative reference for the permission model used by this
pattern. There are **two independent axes** of access, gating two different Custom
APIs, using two different mechanisms — conflating them is the most common source of
confusion, so this document treats them as fully separate topics:

| Axis | Question it answers | Custom API it gates | Mechanism | Grant/revoke script |
|---|---|---|---|---|
| **Caller** | Who may *invoke* this consumer's trigger? | `flowtrig_RunFlow[_Consumer]` (caller) **and** `flowtrig_OnFlowRequested[_Consumer]` (event) | `ExecutePrivilegeName`, a Dataverse platform check before any code runs | `deploy\Add-CallerRoleMembers.ps1` |
| **Maker** | Who may *see and build a flow* using this consumer's event as a trigger? | `flowtrig_OnFlowRequested[_Consumer]` (event, as a `customapi` table row) | Row-sharing on the event's own Custom API record | `deploy\Grant-EventVisibility.ps1` |

A user can hold either without the other. Granting Caller access lets someone invoke
`flowtrig_RunFlow_TeamC` and get a result back; it says nothing about whether they can
see `On Flow Requested (TeamC)` while building a flow in the maker portal. Granting
Maker access lets someone build a flow against that trigger; it says nothing about
whether they're allowed to invoke it themselves.

For the two-stage plug-in transaction design and exact component/field values, see
[ARCHITECTURE.md](ARCHITECTURE.md). For build, deploy, and test scripts, see the root
[README.md](../README.md).

## Caller access: who may invoke the trigger

Each consumer gets its own dedicated marker table that exists **only** to mint an
independent Dataverse privilege — it never stores data.

| Component | Notes |
|---|---|
| Marker table | `flowtrig_ep_<slug>` — one per consumer |
| Privilege | `prvReadflowtrig_ep_<slug>` — different for every consumer |
| Security role privilege | `Read` on `flowtrig_ep_<slug>`, Basic depth — no code ever queries the table's row content, but Basic is used uniformly to avoid over-granting by default |
| Access control mechanism | Purely Dataverse's own platform-level `ExecutePrivilegeName` check, before `RunFlowDispatcher.Execute` ever runs. No plug-in code is involved in authorization |
| Grant/revoke access | `deploy\Add-CallerRoleMembers.ps1 -Consumer <id> -Users <upn>[,<upn>...] [-Remove]` — adds/removes the caller's membership in `Flow Trigger Caller - <id>` |
| Scales to 50+ consumers? | Literally — 50 consumers = 50 tables = 50 privileges = 50 roles. Each table auto-generates 8 privileges (Create/Read/Write/Delete/Assign/Share/Append/AppendTo) that go unused; this is deliberate overhead in exchange for total independence between consumers |

### Why a table, not a "real" custom privilege

Per Microsoft's own docs
([Create and use custom APIs § Secure your custom API](https://learn.microsoft.com/power-apps/developer/data-platform/custom-api#secure-your-custom-api-by-requiring-a-privilege)),
a Custom API's `ExecutePrivilegeName` **must reference an existing privilege** — there is
no supported way to mint a brand-new privilege directly. Microsoft's documented
workaround is:

> Create a custom entity and use one of the privileges created for that entity.

The marker table exists for exactly this purpose.

### Both Custom APIs share the same privilege

`ExecutePrivilegeName` is set to the **same** marker-table privilege on both the caller
Custom API (`flowtrig_RunFlow[_Consumer]`) and the event Custom API
(`flowtrig_OnFlowRequested[_Consumer]`). Without the event API's own
`ExecutePrivilegeName` set, anyone authenticated in the environment could bypass the
caller API entirely and `POST` directly to the event API — firing the worker flow with
attacker-controlled input, without ever holding the caller privilege. Requiring the same
privilege on both closes that bypass at no cost to a legitimate caller:
`RunFlowDispatcher` raises the event **as the real calling user**
(`factory.CreateOrganizationService(context.UserId)`, not elevated — see
`plugin/RunFlowDispatcher.cs`), who already holds this privilege by virtue of having
passed the caller API's own check to get that far. `Deploy-FlowTriggerSolution.ps1`
sets this on both APIs automatically; there is nothing to configure separately.

## Maker access: who may see/build a flow using this trigger

Two Dataverse tables are involved in populating Power Automate's "When an action is
performed" trigger picker, and they behave very differently:

| Table | OwnershipType | Privilege depths supported | Result |
|---|---|---|---|
| `catalog` | OrganizationOwned | Global only (no Basic/Local/Deep) | No record-level concept exists |
| `catalogassignment` | OrganizationOwned | Global only (no Basic/Local/Deep) | Same. The out-of-box `Environment Maker` role holds zero privilege on this table at all — the picker's backend resolves catalog membership some other way (likely an elevated/service identity), not via the calling maker's own Dataverse privileges on this table |
| `customapi` | UserOwned | Basic / Local / Deep / Global — full range | Verified end-to-end via `New-RestrictedMakerRole.ps1` + `Grant-EventVisibility.ps1`: a test identity holding only a custom role with Basic-depth `customapi` Read (instead of the default `Environment Maker` role's Global depth) saw zero `flowtrig_OnFlowRequested*` records with nothing shared, then, after sharing exactly one event's Custom API record with it, saw exactly and only that one |

`catalog`/`catalogassignment` are a hard, un-scopable ceiling — but the event's own
`customapi` record is not; it supports real per-record ownership and sharing, like any
other `UserOwned` table:

- **`deploy\New-RestrictedMakerRole.ps1`** — creates/refreshes "Flow Trigger Restricted
  Maker (Basic CustomAPI Read)": a clone of every privilege the built-in `Environment
  Maker` role grants, except `Read` on `customapi` is forced to **Basic** depth instead
  of `Environment Maker`'s **Global**. Assign this role **instead of** (never in
  addition to — Dataverse privilege grants are cumulative, so holding both would still
  resolve to Global) `Environment Maker` to any maker whose event visibility should be
  restricted.
- **`deploy\Grant-EventVisibility.ps1`** — shares/unshares one consumer's event Custom API
  (`flowtrig_OnFlowRequested[_Consumer]`) with specific users. This is the entire Maker
  grant/revoke mechanism.

**Remaining caveat:** the underlying Dataverse table read is genuinely restricted
per-record, but this does not by itself prove the Power Automate trigger picker UI
reflects that restriction, versus resolving its dropdown via an elevated/service
identity the way `catalogassignment` resolution apparently does. This can only be
settled by a hands-on test with two real signed-in identities in the picker UI itself —
see the procedure below.

**Picker visibility is not the primary security boundary regardless.** Business events
are pub/sub — *every* flow subscribed to an event receives its live payload when it
fires, not just the intended one. Any maker who can see and select "On Flow Requested
(TeamC)" as a trigger can build a flow that receives TeamC's payloads whenever an
authorized TeamC caller invokes `flowtrig_RunFlow_TeamC`. What **does** stay fully
gated is *invocation*: an unauthorized caller cannot themselves cause that event to fire
— that is enforced by Dataverse's `ExecutePrivilegeName` check on the event API itself
(see Caller access above) before any subscriber sees anything. Even fully working
`customapi` sharing only restricts *discoverability of the trigger name in the picker*
— it does not stop a maker who already knows the event's exact name from subscribing to
it directly if they still hold whatever base privilege lets them read/execute business
events at all.

### Manual verification procedure

Table-level privilege checks are strong supporting evidence but cannot prove what the
connector's backend enforces at picker-population time. The only fully conclusive test
is in the real trigger picker UI, with two genuinely different signed-in identities. A
test environment with several separately named consumers makes visibility mistakes easy
to spot (e.g. a user who holds none of the consumer-specific caller roles but still sees
every event).

1. Sign in to [make.powerautomate.com](https://make.powerautomate.com) as a System
   Administrator account, switch to the test environment, create a new flow, and add
   trigger **Microsoft Dataverse → When an action is performed**. Set Catalog =
   `FlowTriggerActionDemo`, Category = `Flow Events`, and open the **Action name**
   dropdown — all deployed consumer events should appear (e.g. `On Flow Requested`,
   `On Flow Requested (TeamA)` .. `(TeamE)`).
2. Have a genuinely different, real user sign in with the standard `Environment Maker`
   role (no `Flow Trigger Caller - <Consumer>` role at all). Repeat the same steps; if
   they see the same events, that is today's default-role behavior — visibility is not
   gated by the Caller-side invocation role.
3. To test whether `customapi` sharing changes the *picker*: assign that same colleague
   **"Flow Trigger Restricted Maker (Basic CustomAPI Read)" instead of Environment
   Maker**, run `.\deploy\Grant-EventVisibility.ps1 -EnvironmentUrl <environment url>
   -Consumer TeamC -Users <their upn>`, and have them reopen the trigger dropdown. If
   the picker now shows only `On Flow Requested (TeamC)` (or that plus whatever else
   they've been separately granted), the picker respects the restriction. Both scripts
   are idempotent and the role assignment is a one-line revert (swap back to
   `Environment Maker`).

Impersonation (`MSCRMCallerID`) works for Dataverse Web API testing (as used throughout
this doc and in `Invoke-FlowTrigger.ps1 -ImpersonateUpn`), but the trigger picker is a
maker-portal UI experience with no equivalent non-interactive entry point — this
procedure requires a second real signed-in user.

### Mitigations for the visibility/eavesdropping concern

- **Separate Dataverse environments** per sensitive consumer group — maker populations
  are provisioned per-environment, so this is the only true hard boundary.
- Tightly restrict who holds *any* flow-authoring/maker rights in the environment at all
  — reduces the exposed population, does not eliminate it.
- **Mitigation C** (below): skip cataloging for a specific sensitive consumer, and
  hand-author that one flow's trigger directly instead of using the maker-portal picker.
  Security-through-obscurity, not a real ACL — removes casual discovery, not determined
  access by someone who already has broad maker/admin rights in the environment.

## Mitigation C: hidden (uncataloged) consumer

For a consumer sensitive enough that even picker-based discoverability is a concern:
skip creating a `CatalogAssignment` for its event Custom API. The event is still a
completely real, functioning business event — it is just never linked into the
`Flow Events` category, so it never appears in `GetActionsForActionTrigger`'s results
(the API the picker calls to populate its dropdown), and never shows up in anyone's
trigger list.

Because the maker-portal picker is also how a flow's trigger gets built in the first
place, the worker flow's trigger must be hand-authored and written directly to
Dataverse's `workflow` table via the Web API (`category = 5` for a Modern/cloud flow;
`clientdata` holds the flow definition JSON, Azure Logic Apps schema). The trigger node
shape (from the `BusinessEventsTrigger` connector spec):

```json
"On_Flow_Requested_SecretTeam": {
  "type": "OpenApiConnectionWebhook",
  "inputs": {
    "host": {
      "connectionName": "shared_commondataserviceforapps",
      "operationId": "BusinessEventsTrigger",
      "apiId": "/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps"
    },
    "parameters": {
      "catalog": "flowtrig_FlowTriggerActionDemo",
      "category": "flowtrig_FlowEvents",
      "subscriptionRequest/entityname": "none",
      "subscriptionRequest/sdkmessagename": "flowtrig_OnFlowRequested_SecretTeam"
    },
    "authentication": "@parameters('$authentication')"
  }
}
```

`catalog`/`category` here still reference the existing root catalog/category — they are
required by the subscription request shape, but per the connector spec they are wired to
`x-ms-dynamic-list` purely to populate **design-time** dropdowns, not to re-validate
cataloging at registration time. The record that actually controls picker enumerability
is the `CatalogAssignment`, which this flow intentionally never gets.

## Security notes

- **Both Custom APIs share the same `ExecutePrivilegeName`.** See "Both Custom APIs
  share the same privilege" above — this is what prevents an unauthorized identity from
  bypassing the caller API and invoking the event API directly.
- **The plug-in polls `flowtrig_flowresult` using an elevated/system service context,
  not the calling caller's own identity.** Result rows are written by the worker flow (a
  different identity entirely) and keyed by a correlation GUID the plug-in itself
  generated, so reading them back is system plumbing rather than a new authorization
  decision. This also avoids an information leak: a role-based `Read` grant on
  `flowtrig_flowresult` at Global depth would let any caller directly query every
  consumer's results/messages via the raw Web API, not just their own — no consumer
  role grants any privilege on this table.

The permission model — `ExecutePrivilegeName` enforcement on both Custom APIs — has been
validated end-to-end against a real, zero-privilege Dataverse security principal: zero
roles → platform-level deny; role granted → passes through to the poll phase; a
different, still-ungranted consumer remains denied throughout; access revoked → denied
again.
