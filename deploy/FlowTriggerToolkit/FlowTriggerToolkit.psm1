#Requires -Version 5.1
<#
    FlowTriggerToolkit.psm1

    Tenant-agnostic PowerShell module for provisioning, operating, and governing the
    synchronous flow-trigger pattern documented in this repository's README.md and
    docs/ARCHITECTURE.md. Every function here wraps the same Dataverse Web API calls
    used by the individual deploy\*.ps1 scripts, as a single, discoverable,
    Get-Help-able surface.

    COMPATIBILITY: every function runs unchanged on both Windows PowerShell 5.1
    (.NET Framework) and PowerShell 7+ (.NET/.NET Core) - no version-specific
    cmdlets, operators (?? , ?:, &&/||), or BCL types (e.g. SocketsHttpHandler,
    .NET Core only) are used anywhere in this file.

    Requires: DvHelper.psm1 (one folder up) for the underlying Dataverse Web API
    plumbing, and Azure CLI signed in to the target tenant (`az login`;
    `New-FlowTriggerEnvironment` additionally needs `pac auth create`).

    See deploy/FlowTriggerToolkit/README.md for the full quick-start walkthrough and
    function reference table.
#>

$script:ModuleRoot = $PSScriptRoot
Import-Module (Join-Path $script:ModuleRoot "..\DvHelper.psm1") -Force -Global

function Write-FlowTriggerStep { param([string] $Message) Write-Host ">> $Message" -ForegroundColor Cyan }
function Write-FlowTriggerOk   { param([string] $Message) Write-Host "   OK: $Message" -ForegroundColor Green }
function Write-FlowTriggerSkip { param([string] $Message) Write-Host "   SKIP: $Message" -ForegroundColor DarkYellow }
function Write-FlowTriggerWarn { param([string] $Message) Write-Host "   WARN: $Message" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Internal helpers shared across public functions
# ---------------------------------------------------------------------------

function Get-FlowTriggerCallerMessageName {
    param([Parameter(Mandatory)] [string] $Consumer, [string] $PublisherPrefix = "flowtrig")
    if ($Consumer -eq "Default") { return "$($PublisherPrefix)_RunFlow" }
    return "$($PublisherPrefix)_RunFlow_$Consumer"
}

function Get-FlowTriggerEventMessageName {
    param([Parameter(Mandatory)] [string] $Consumer, [string] $PublisherPrefix = "flowtrig")
    if ($Consumer -eq "Default") { return "$($PublisherPrefix)_OnFlowRequested" }
    return "$($PublisherPrefix)_OnFlowRequested_$Consumer"
}

# ---------------------------------------------------------------------------
# Environment provisioning
# ---------------------------------------------------------------------------

function New-FlowTriggerEnvironment {
    <#
    .SYNOPSIS
        Provisions a brand-new Power Platform environment (with a Dataverse database)
        sized and located appropriately for hosting this solution.
    .DESCRIPTION
        Thin wrapper over the PAC CLI's `pac admin create`. Requires PAC CLI to be
        installed and signed in for the target tenant (`pac auth create`, or `pac auth
        list` shows an active profile for it). Returns the new environment's Dataverse
        URL on success, ready to pass straight into Install-FlowTriggerSolution.
    .PARAMETER Name
        Display name for the new environment.
    .PARAMETER Type
        Production, Sandbox, Trial, or Developer. Defaults to Sandbox (the safest
        choice for a first trial of this solution) - pass Production explicitly once
        ready to commit to it.
    .PARAMETER Region
        Defaults to unitedstates. Run `pac admin create help` for the full valid list.
    .PARAMETER Domain
        Subdomain portion of the resulting *.crm.dynamics.com URL. Defaults to a
        lowercased, punctuation-stripped version of -Name.
    .EXAMPLE
        $envUrl = New-FlowTriggerEnvironment -Name "Contoso Flow Trigger" -Type Production
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [ValidateSet("Production", "Sandbox", "Trial", "Developer")] [string] $Type = "Sandbox",
        [string] $Region = "unitedstates",
        [string] $Currency = "USD",
        [string] $Language = "English",
        [string] $Domain = ($Name.ToLowerInvariant() -replace '[^a-z0-9]', '')
    )

    Write-FlowTriggerStep "Creating $Type environment '$Name' (region: $Region, domain: $Domain)"
    $output = & pac admin create --name $Name --type $Type --region $Region --currency $Currency --language $Language --domain $Domain 2>&1
    $output | ForEach-Object { Write-Host "   $_" }

    $urlMatch = ($output | Out-String) | Select-String -Pattern "https://\S+\.crm\.dynamics\.com" | Select-Object -Last 1
    if (-not $urlMatch) {
        throw "Could not parse the new environment's URL from 'pac admin create' output - see output above for the actual failure (common causes: not signed in via 'pac auth create', insufficient tenant capacity/licensing, or a domain name collision)."
    }
    $envUrl = [regex]::Match($urlMatch.Line, "https://\S+\.crm\.dynamics\.com").Value.TrimEnd('/')
    Write-FlowTriggerOk "Environment ready: $envUrl"
    return $envUrl
}

# ---------------------------------------------------------------------------
# Solution deployment
# ---------------------------------------------------------------------------

function Install-FlowTriggerSolution {
    <#
    .SYNOPSIS
        Deploys (or idempotently updates) the full Flow Trigger solution to one
        environment: publisher, solution, flowtrig_flowresult table, the two-stage
        plug-in (RunFlowDispatcher at PreValidation + RunFlowMainOperation as Main
        Operation), the business-event catalog, and every consumer listed in
        -ConsumersPath.
    .DESCRIPTION
        This is the single entry point that replaces hand-running
        deploy\Deploy-FlowTriggerSolution.ps1 directly - same underlying logic,
        packaged as a discoverable cmdlet. Safe to re-run: every component is checked
        for existence first. Automatically repairs the one known immutable-field trap
        (a caller Custom API created with allowedcustomprocessingsteptype=0 by an older
        deploy is deleted and recreated with 2, since that field cannot be PATCHed - see
        docs/ARCHITECTURE.md).
    .PARAMETER EnvironmentUrl
        e.g. https://yourorg.crm.dynamics.com
    .PARAMETER PluginAssemblyPath
        Path to the built FlowTrigger.Plugins.dll. If omitted, searches
        plugin\bin under the repo root relative to this module for the newest one.
    .PARAMETER PublisherPrefix
        Choose this once per environment at first deploy - see
        Deploy-FlowTriggerSolution.ps1's own help for why changing it on a later
        re-run against an already-deployed environment is not supported.
    .PARAMETER ConsumersPath
        Path to a consumers.json-shaped file (an object with a "consumers" array,
        each entry { "id": "..." }). Defaults to deploy\consumers.json next to
        this module. See deploy\consumers.json for examples.
    .EXAMPLE
        Install-FlowTriggerSolution -EnvironmentUrl https://yourorg.crm.dynamics.com
    .EXAMPLE
        Install-FlowTriggerSolution -EnvironmentUrl https://yourorg.crm.dynamics.com -ConsumersPath .\my-consumers.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [string] $PluginAssemblyPath,
        [string] $ConsumersPath,
        [string] $PublisherUniqueName   = "flowtrigger",
        [string] $PublisherFriendlyName = "Flow Trigger",
        [string] $PublisherPrefix       = "flowtrig",
        [string] $SolutionUniqueName    = "FlowTriggerActionDemo",
        [string] $SolutionFriendlyName  = "Flow Trigger Action Demo",
        [string] $SolutionVersion       = "1.0.0.0"
    )

    $scriptArgs = @{
        EnvironmentUrl         = $EnvironmentUrl
        PublisherUniqueName    = $PublisherUniqueName
        PublisherFriendlyName  = $PublisherFriendlyName
        PublisherPrefix        = $PublisherPrefix
        SolutionUniqueName     = $SolutionUniqueName
        SolutionFriendlyName   = $SolutionFriendlyName
        SolutionVersion        = $SolutionVersion
    }
    if ($PluginAssemblyPath) { $scriptArgs["PluginAssemblyPath"] = $PluginAssemblyPath }
    if ($ConsumersPath)      { $scriptArgs["ConsumersPath"] = $ConsumersPath }

    & (Join-Path $script:ModuleRoot "..\Deploy-FlowTriggerSolution.ps1") @scriptArgs
}

function Get-FlowTriggerConsumer {
    <#
    .SYNOPSIS
        Lists every consumer currently deployed in an environment (by convention:
        every <prefix>_RunFlow[_*] Custom API).
    .EXAMPLE
        Get-FlowTriggerConsumer -EnvironmentUrl https://yourorg.crm.dynamics.com
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $EnvironmentUrl, [string] $PublisherPrefix = "flowtrig")

    $token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
    Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null
    $dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }

    $callerPrefix = "$($PublisherPrefix)_RunFlow"
    $callers = (Invoke-Dataverse @dv -Method GET -Path "customapis?`$select=uniquename,customapiid,executeprivilegename&`$filter=startswith(uniquename,'$callerPrefix')").value

    foreach ($c in $callers) {
        $consumerId = if ($c.uniquename -eq $callerPrefix) { "Default" } else { $c.uniquename.Substring(($callerPrefix + "_").Length) }
        [pscustomobject]@{
            Consumer             = $consumerId
            CallerMessage        = $c.uniquename
            EventMessage         = Get-FlowTriggerEventMessageName -Consumer $consumerId -PublisherPrefix $PublisherPrefix
            CallerCustomApiId    = $c.customapiid
            ExecutePrivilegeName = $c.executeprivilegename
        }
    }
}

function Add-FlowTriggerConsumer {
    <#
    .SYNOPSIS
        Onboards exactly ONE new consumer (caller + event Custom API, marker
        table, security role) into an already-installed environment, without
        needing to hand-edit a consumers.json file first.
    .DESCRIPTION
        Intended for a governed, one-change-at-a-time onboarding workflow - each call
        is a single, independently reviewable/auditable action (e.g. logged in a
        change ticket), rather than a bulk redeploy from a config file. Internally
        writes a single-entry temporary consumers.json and delegates to
        Install-FlowTriggerSolution, so the exact same idempotent deploy logic
        (including the allowedcustomprocessingsteptype auto-repair) applies.
    .PARAMETER Consumer
        New consumer id - letters/digits only (used verbatim in message names and
        in the marker table's logical name).
    .EXAMPLE
        Add-FlowTriggerConsumer -EnvironmentUrl https://contoso.crm.dynamics.com -Consumer Finance
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $Consumer,
        [string] $Description = "Added via Add-FlowTriggerConsumer",
        [string] $PluginAssemblyPath
    )

    if ($Consumer -notmatch '^[A-Za-z0-9]+$') {
        throw "Consumer id must be letters/digits only (got '$Consumer')."
    }

    $tempConfig = [System.IO.Path]::GetTempFileName()
    try {
        @{ consumers = @(@{ id = $Consumer; description = $Description }) } |
            ConvertTo-Json -Depth 5 | Set-Content -Path $tempConfig -Encoding utf8

        Write-FlowTriggerStep "Onboarding consumer '$Consumer' into $EnvironmentUrl"
        Install-FlowTriggerSolution -EnvironmentUrl $EnvironmentUrl -ConsumersPath $tempConfig -PluginAssemblyPath $PluginAssemblyPath
    }
    finally {
        Remove-Item $tempConfig -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Worker flow creation
# ---------------------------------------------------------------------------

function New-FlowTriggerWorkerFlow {
    <#
    .SYNOPSIS
        Creates (and optionally activates) a real Power Automate worker flow for one
        consumer: trigger = "When an action is performed" on that consumer's business
        event, action = writes the result to the flow-result table.
    .DESCRIPTION
        Requires a Dataverse connection (shared_commondataserviceforapps) that has
        ALREADY been interactively consented to in the Power Apps/Automate portal by
        whichever identity should own the flow - this one step cannot be automated
        (no tool can complete an OAuth consent prompt on a user's behalf). Once that
        connection exists, everything else is scripted.
    .PARAMETER ConnectionName
        The connection's internal name (the GUID-suffixed identifier, e.g.
        shared-commondataser-xxxxx, or a bare GUID as used in this repo's testing) -
        find it via the Power Automate/Apps portal's Connections page, or the
        Power Platform admin API.
    .PARAMETER EventConsumer
        Which consumer's event to bind the trigger to, if different from
        -Consumer. Defaults to -Consumer. Set this only to create a second flow
        that subscribes to an existing consumer's event (e.g. for
        dispatch-latency testing).
    .EXAMPLE
        New-FlowTriggerWorkerFlow -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer Default -ConnectionName <connection-name> -Activate
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $Consumer,
        [Parameter(Mandatory)] [string] $ConnectionName,
        [string] $EventConsumer,
        [string] $PublisherPrefix = "flowtrig",
        [string] $SolutionUniqueName = "FlowTriggerActionDemo",
        [switch] $Activate,
        [switch] $Force
    )

    & (Join-Path $script:ModuleRoot "..\Create-WorkerFlow.ps1") `
        -EnvironmentUrl $EnvironmentUrl -Consumer $Consumer -ConnectionName $ConnectionName -EventConsumer $EventConsumer `
        -PublisherPrefix $PublisherPrefix -SolutionUniqueName $SolutionUniqueName -Activate:$Activate -Force:$Force
}

# ---------------------------------------------------------------------------
# Permissions: caller side (who may invoke a trigger) - unified entry point
# ---------------------------------------------------------------------------

function Grant-FlowTriggerCallerAccess {
    <#
    .SYNOPSIS
        Grants one or more users the per-consumer Caller privilege used by both the
        caller and event Custom APIs (<prefix>_RunFlow[_Consumer] and
        <prefix>_OnFlowRequested[_Consumer]) - a thin wrapper over
        Add-CallerRoleMembers.ps1 for discoverability from within this module.
    .PARAMETER Users
        UPNs/email addresses (systemuser.domainname).
    .EXAMPLE
        Grant-FlowTriggerCallerAccess -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer TeamA -Users alice@contoso.com,bob@contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $Consumer,
        [Parameter(Mandatory)] [string[]] $Users
    )

    & (Join-Path $script:ModuleRoot "..\Add-CallerRoleMembers.ps1") -EnvironmentUrl $EnvironmentUrl -Consumer $Consumer -Users $Users
}

function Revoke-FlowTriggerCallerAccess {
    <#
    .SYNOPSIS
        Revokes one or more users' ability to INVOKE a consumer's caller Custom API -
        the inverse of Grant-FlowTriggerCallerAccess.
    .EXAMPLE
        Revoke-FlowTriggerCallerAccess -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer TeamA -Users alice@contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $Consumer,
        [Parameter(Mandatory)] [string[]] $Users
    )

    & (Join-Path $script:ModuleRoot "..\Add-CallerRoleMembers.ps1") -EnvironmentUrl $EnvironmentUrl -Consumer $Consumer -Users $Users -Remove
}

# ---------------------------------------------------------------------------
# Permissions: maker side (who may see/build a flow against an event)
# ---------------------------------------------------------------------------

function New-FlowTriggerRestrictedMakerRole {
    <#
    .SYNOPSIS
        Creates (or refreshes) a maker role identical to the built-in Environment
        Maker role except Read-on-customapi is Basic depth instead of Global - the
        prerequisite for restricting which event(s) a maker can see in the Power
        Automate trigger picker. Assign INSTEAD OF Environment Maker (privilege
        grants are cumulative - holding both still resolves to Global).
    .EXAMPLE
        New-FlowTriggerRestrictedMakerRole -EnvironmentUrl https://contoso.crm.dynamics.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [string] $RoleName = "Restricted Maker (Basic CustomAPI Read)",
        [string] $SourceRoleName = "Environment Maker"
    )

    & (Join-Path $script:ModuleRoot "..\New-RestrictedMakerRole.ps1") -EnvironmentUrl $EnvironmentUrl -RoleName $RoleName -SourceRoleName $SourceRoleName
}

function Grant-FlowTriggerMakerVisibility {
    <#
    .SYNOPSIS
        Grants one or more makers visibility into a consumer's EVENT Custom API (so
        they can see and select it while building a flow in the trigger picker) - only
        meaningful for users holding the restricted maker role (see
        New-FlowTriggerRestrictedMakerRole), not the standard Environment Maker role.
    .DESCRIPTION
        This is independent from Grant-FlowTriggerCallerAccess: invoking a trigger and
        building-a-flow-against its event are deliberately separate axes - see
        docs/PERMISSIONS.md.
    .EXAMPLE
        Grant-FlowTriggerMakerVisibility -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer TeamC -Users alice@contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $Consumer,
        [Parameter(Mandatory)] [string[]] $Users,
        [string] $PublisherPrefix = "flowtrig"
    )

    & (Join-Path $script:ModuleRoot "..\Grant-EventVisibility.ps1") -EnvironmentUrl $EnvironmentUrl -Consumer $Consumer -Users $Users -PublisherPrefix $PublisherPrefix
}

function Revoke-FlowTriggerMakerVisibility {
    <#
    .SYNOPSIS
        Revokes a maker's visibility into a consumer's event Custom API - the inverse
        of Grant-FlowTriggerMakerVisibility.
    .EXAMPLE
        Revoke-FlowTriggerMakerVisibility -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer TeamC -Users alice@contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $Consumer,
        [Parameter(Mandatory)] [string[]] $Users,
        [string] $PublisherPrefix = "flowtrig"
    )

    & (Join-Path $script:ModuleRoot "..\Grant-EventVisibility.ps1") -EnvironmentUrl $EnvironmentUrl -Consumer $Consumer -Users $Users -PublisherPrefix $PublisherPrefix -Remove
}

# ---------------------------------------------------------------------------
# Testing
# ---------------------------------------------------------------------------

function Test-FlowTriggerConsumer {
    <#
    .SYNOPSIS
        Calls a consumer's caller Custom API and prints/returns the synchronous
        result - the same mechanism a real caller would use. Supports impersonating a
        different real user (Dataverse's documented MSCRMCallerID header) to prove
        access-isolation without needing that user's own credentials.
    .EXAMPLE
        Test-FlowTriggerConsumer -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer Default -InputJson '{"hello":"world"}'
    .EXAMPLE
        Test-FlowTriggerConsumer -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer TeamC -ImpersonateUpn alice@contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [string] $Consumer = "Default",
        [string] $InputJson = '{"message":"triggered from Test-FlowTriggerConsumer"}',
        [string] $PublisherPrefix = "flowtrig",
        [string] $ImpersonateUpn
    )

    $scriptArgs = @{ EnvironmentUrl = $EnvironmentUrl; Consumer = $Consumer; InputJson = $InputJson; PublisherPrefix = $PublisherPrefix }
    if ($ImpersonateUpn) { $scriptArgs["ImpersonateUpn"] = $ImpersonateUpn }
    & (Join-Path $script:ModuleRoot "..\Invoke-FlowTrigger.ps1") @scriptArgs
}

function Get-FlowTriggerLoadTestPhaseBreakdown {
    <#
    .SYNOPSIS
        After running deploy\Invoke-LoadTest.ps1, breaks the results down into three
        phases to isolate where time actually goes under concurrency: dispatch (event
        raised -> worker flow starts), the flow's own execution, and poll-detect +
        respond (result written -> RunFlowDispatcher notices -> caller gets a response).
    .DESCRIPTION
        See deploy\Get-LoadTestPhaseBreakdown.ps1's own help for the full methodology
        and the measurement-bug history this replaced (an earlier load-test harness
        version silently made every call in a batch report ~the same duration,
        regardless of that call's own true completion time - fixed by polling each
        call's own Task.IsCompleted rather than a single Task.WaitAll() over the whole
        batch).
    .PARAMETER FlowRunHistoryJsonPath
        Optional. Raw JSON array from the flowagent MCP tool's get_run_history for the
        worker flow (save its output to a file first). Without this, only the combined
        dispatch+execution+write breakdown is computed - not the further split between
        dispatch latency and the flow's own execution time.
    .EXAMPLE
        Get-FlowTriggerLoadTestPhaseBreakdown -EnvironmentUrl https://yourorg.crm.dynamics.com -ResultsCsvPath .\load-test-results.csv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $ResultsCsvPath,
        [string] $Consumer = "Default",
        [string] $PublisherPrefix = "flowtrig",
        [string] $FlowRunHistoryJsonPath
    )

    $scriptArgs = @{ EnvironmentUrl = $EnvironmentUrl; ResultsCsvPath = $ResultsCsvPath; Consumer = $Consumer; PublisherPrefix = $PublisherPrefix }
    if ($FlowRunHistoryJsonPath) { $scriptArgs["FlowRunHistoryJsonPath"] = $FlowRunHistoryJsonPath }
    & (Join-Path $script:ModuleRoot "..\Get-LoadTestPhaseBreakdown.ps1") @scriptArgs
}

# ---------------------------------------------------------------------------
# Governance / auditability
# ---------------------------------------------------------------------------

function Enable-FlowTriggerAuditing {
    <#
    .SYNOPSIS
        Turns on Dataverse's native, built-in change-auditing (who created/updated/
        deleted what, and when - queryable forever after via the audit history, or
        Get-FlowTriggerAuditLog below) for every table/record type that matters for
        governing this solution.
    .DESCRIPTION
        Enables org-wide auditing if it isn't already on, then enables entity-level
        auditing (IsAuditEnabled) specifically on:
          - <prefix>_flowresult (every result a worker flow ever wrote back)
          - customapi         (every caller/event Custom API create/update/delete -
                                covers consumer onboarding/offboarding)
          - role               (security role changes - covers caller-access grants)
          - workflow           (worker flow create/update/activate/deactivate/delete)
        This is complementary to, not a replacement for, this module's own
        Get-FlowTriggerAccessReport (a live snapshot) - auditing gives you the
        *history* of how that snapshot came to be.

        Each entity is attempted independently - one entity's platform-specific
        quirk is reported as a warning and does not stop the others from being
        processed. Two known, environment-dependent limitations:
          - 'customapi' commonly reports IsAuditEnabled.CanBeChanged = false (a
            platform-side restriction, not something this module can override) -
            reported as a WARN and skipped.
          - 'role' and 'workflow' can fail the required full-definition PUT with a
            "ClusterMode" validation error in non-clustered organizations
            (error text: "Cannot create/update ClusterMode of entity role to Local
            when organization is not part of a cluster" - yet omitting the field
            instead fails with "ClusterMode must be set..."). This is a known
            Dataverse Web API metadata round-trip inconsistency for these two
            specific system entities, not a bug in this function; if you need
            auditing on them despite this, the classic SDK's UpdateEntityRequest
            (which this module deliberately does not depend on) has been reported
            to handle this case more leniently.

        Note: Dataverse does not audit systemuserroles_association (role membership)
        or shared-record access grants (GrantAccess/RevokeAccess) at the row level by
        default - Get-FlowTriggerAccessReport is the authoritative way to see current
        caller-access grants; for a durable change history of *those* specific grants,
        pair this with your own change-ticket/pipeline process, since this is a
        platform limitation this module cannot work around.
    .EXAMPLE
        Enable-FlowTriggerAuditing -EnvironmentUrl https://yourorg.crm.dynamics.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [string] $PublisherPrefix = "flowtrig",
        [string[]] $EntityLogicalNames
    )
    if (-not $EntityLogicalNames -or $EntityLogicalNames.Count -eq 0) {
        $EntityLogicalNames = @("$($PublisherPrefix)_flowresult", "customapi", "role", "workflow")
    }

    $token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
    Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null
    $dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }

    Write-FlowTriggerStep "Checking org-wide auditing"
    $org = Invoke-Dataverse @dv -Method GET -Path "organizations?`$select=organizationid,isauditenabled"
    $orgRow = $org.value[0]
    if (-not $orgRow.isauditenabled) {
        Invoke-Dataverse @dv -Method PATCH -Path "organizations($($orgRow.organizationid))" -Body @{ isauditenabled = $true } | Out-Null
        Write-FlowTriggerOk "Enabled org-wide auditing"
    } else {
        Write-FlowTriggerOk "Org-wide auditing already enabled"
    }

    foreach ($entity in $EntityLogicalNames) {
        Write-FlowTriggerStep "Entity-level auditing: '$entity'"
        try {
            # Table (entity) metadata does NOT support PATCH for individual
            # properties - Dataverse's Web API requires a full PUT of the
            # complete definition (SDK parity with UpdateEntityRequest, which
            # replaces the whole definition), confirmed via
            # https://learn.microsoft.com/power-apps/developer/data-platform/webapi/create-update-entity-definitions-using-web-api#update-table-definitions
            # - so fetch the FULL definition (no $select) rather than just
            # the couple of fields we care about.
            $fullDef = Invoke-Dataverse @dv -Method GET -Path "EntityDefinitions(LogicalName='$entity')"
        } catch {
            Write-FlowTriggerWarn "Table '$entity' not found in this environment - skipping (deploy the solution first if this is $($PublisherPrefix)_flowresult)"
            continue
        }
        if ($fullDef.IsAuditEnabled.Value) {
            Write-FlowTriggerOk "'$entity' already has auditing enabled"
            continue
        }
        if ($fullDef.IsAuditEnabled.CanBeChanged -eq $false) {
            Write-FlowTriggerWarn "'$entity' does not allow IsAuditEnabled to be changed (CanBeChanged=false) - skipping"
            continue
        }

        try {
            $fullDef.IsAuditEnabled.Value = $true
            # Add-Member -Force (not direct property assignment) - the GET
            # response doesn't always include '@odata.type' as a real
            # property on the deserialized object, and PSCustomObject
            # rejects assigning to a property that doesn't already exist.
            $fullDef | Add-Member -NotePropertyName '@odata.type' -NotePropertyValue "Microsoft.Dynamics.CRM.EntityMetadata" -Force

            Invoke-Dataverse @dv -Method PUT -Path "EntityDefinitions($($fullDef.MetadataId))" -Body $fullDef -ExtraHeaders @{ "MSCRM.MergeLabels" = "true" } | Out-Null

            # Metadata changes don't take effect until published.
            Invoke-Dataverse @dv -Method POST -Path "PublishXml" -Body @{
                ParameterXml = "<importexportxml><entities><entity>$entity</entity></entities></importexportxml>"
            } | Out-Null
            Write-FlowTriggerOk "Enabled and published auditing on '$entity'"
        } catch {
            # Isolate one entity's platform-specific metadata quirk from the
            # rest of the list - don't let 'role' failing stop 'workflow'
            # from being processed.
            Write-FlowTriggerWarn "Could not enable auditing on '$entity': $($_.Exception.Message)"
        }
    }

    Write-Host ""
    Write-Host "Auditing enabled. View history: Power Platform Admin Center > Environments > <env> > Settings > Audit and logs > Audit summary view, or Get-FlowTriggerAuditLog." -ForegroundColor Yellow
}

function Get-FlowTriggerAuditLog {
    <#
    .SYNOPSIS
        Retrieves Dataverse's native audit history for the tables
        Enable-FlowTriggerAuditing turns auditing on for, in one combined,
        chronological view - who did what, to which record, and when.
    .DESCRIPTION
        Requires Enable-FlowTriggerAuditing to have been run first (and some time to
        have passed for actions to accumulate). Reads the `audit` table directly via
        the Web API's audit endpoint.
    .PARAMETER Top
        Max rows to return (most recent first). Default 200.
    .EXAMPLE
        Get-FlowTriggerAuditLog -EnvironmentUrl https://yourorg.crm.dynamics.com -Top 50 | Format-Table
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [string] $PublisherPrefix = "flowtrig",
        [string[]] $EntityLogicalNames,
        [int] $Top = 200
    )
    if (-not $EntityLogicalNames -or $EntityLogicalNames.Count -eq 0) {
        $EntityLogicalNames = @("$($PublisherPrefix)_flowresult", "customapi", "role", "workflow")
    }

    $token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
    Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null
    $dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }

    $clauses = @()
    foreach ($name in $EntityLogicalNames) { $clauses += "objecttypecode eq '$name'" }
    $filterClauses = $clauses -join " or "
    $result = Invoke-Dataverse @dv -Method GET -Path "audits?`$select=createdon,operation,action,objecttypecode,useridname&`$filter=$filterClauses&`$orderby=createdon desc&`$top=$Top"

    foreach ($row in $result.value) {
        [pscustomobject]@{
            When      = $row.createdon
            Table     = $row.objecttypecode
            Operation = $row.'operation@OData.Community.Display.V1.FormattedValue'
            Action    = $row.'action@OData.Community.Display.V1.FormattedValue'
            User      = $row.useridname
        }
    }
}

function Get-FlowTriggerAccessReport {
    <#
    .SYNOPSIS
        Produces a full, exportable access report for every deployed consumer:
        exactly who currently has Caller (invoke) access and Maker (picker
        visibility) access. This is the authoritative "who can do what, right
        now" governance artifact for this solution - see docs/PERMISSIONS.md
        for what each access type actually protects.
    .EXAMPLE
        Get-FlowTriggerAccessReport -EnvironmentUrl https://yourorg.crm.dynamics.com | Format-Table -AutoSize
    .EXAMPLE
        Get-FlowTriggerAccessReport -EnvironmentUrl https://yourorg.crm.dynamics.com | Export-Csv .\access-report.csv -NoTypeInformation
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $EnvironmentUrl, [string] $PublisherPrefix = "flowtrig")

    $token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
    Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null
    $dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }

    $consumers = Get-FlowTriggerConsumer -EnvironmentUrl $EnvironmentUrl -PublisherPrefix $PublisherPrefix
    $rows = @()

    foreach ($c in $consumers) {
        $roleName = "Flow Trigger Caller - $($c.Consumer)"
        $roleId = Find-DataverseRecordId @dv -EntitySetName "roles" -IdField "roleid" -Filter "name eq '$roleName'"
        $members = @()
        if ($roleId) {
            $members = (Invoke-Dataverse @dv -Method GET -Path "roles($roleId)/systemuserroles_association?`$select=domainname,fullname").value
        }
        if ($members -and $members.Count -gt 0) {
            foreach ($m in $members) {
                $rows += [pscustomobject]@{
                    Consumer      = $c.Consumer
                    AccessType    = "Caller (invoke)"; Mechanism = "Security role: $roleName"
                    Principal     = $m.domainname; PrincipalName = $m.fullname
                }
            }
        } else {
            $rows += [pscustomobject]@{ Consumer = $c.Consumer; AccessType = "Caller (invoke)"; Mechanism = "Security role: $roleName"; Principal = "<none>"; PrincipalName = $null }
        }

        # Maker/picker visibility (event Custom API sharing) - independent axis
        $eventName = Get-FlowTriggerEventMessageName -Consumer $c.Consumer -PublisherPrefix $PublisherPrefix
        $eventId = Find-DataverseRecordId @dv -EntitySetName "customapis" -IdField "customapiid" -Filter "uniquename eq '$eventName'"
        if ($eventId) {
            $visShared = (Invoke-Dataverse @dv -Method GET -Path "RetrieveSharedPrincipalsAndAccess(Target=@p1)?@p1={'@odata.id':'customapis($eventId)'}").PrincipalAccesses
            foreach ($v in $visShared) {
                $rows += [pscustomobject]@{
                    Consumer      = $c.Consumer
                    AccessType    = "Maker (picker visibility)"; Mechanism = "Row share on $eventName"
                    Principal     = $v.Principal.ownerid; PrincipalName = $null
                }
            }
        }
    }

    return $rows
}

function Get-FlowTriggerDeploymentStatus {
    <#
    .SYNOPSIS
        Health/drift check: for every deployed consumer, confirms the exact
        configuration this pattern depends on is actually in place - the
        RunFlowDispatcher PreValidation step (stage 10, mode 0), the caller Custom
        API's AllowedCustomProcessingStepType (must be 2) and its PluginTypeId binding
        (must be RunFlowMainOperation), and whether an active worker flow exists for
        that consumer's event. Flags anything unexpected instead of assuming success.
    .EXAMPLE
        Get-FlowTriggerDeploymentStatus -EnvironmentUrl https://yourorg.crm.dynamics.com | Format-Table -AutoSize
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $EnvironmentUrl, [string] $PublisherPrefix = "flowtrig")

    $token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
    Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null
    $dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }

    $dispatcherTypeId = Find-DataverseRecordId @dv -EntitySetName "plugintypes" -IdField "plugintypeid" -Filter "typename eq 'FlowTrigger.Plugins.RunFlowDispatcher'"
    $mainOpTypeId     = Find-DataverseRecordId @dv -EntitySetName "plugintypes" -IdField "plugintypeid" -Filter "typename eq 'FlowTrigger.Plugins.RunFlowMainOperation'"

    $consumers = Get-FlowTriggerConsumer -EnvironmentUrl $EnvironmentUrl -PublisherPrefix $PublisherPrefix
    $rows = @()

    foreach ($c in $consumers) {
        # _plugintypeid_value is the standard OData convention for a lookup's raw
        # target GUID without needing $expand at all - avoids relying on the exact
        # (case-sensitive, easy to get wrong) navigation property name $expand needs.
        $callerDetail = Invoke-Dataverse @dv -Method GET -Path "customapis($($c.CallerCustomApiId))?`$select=allowedcustomprocessingsteptype,_plugintypeid_value"
        $stepTypeOk = $callerDetail.allowedcustomprocessingsteptype -eq 2
        $mainOpBoundCorrectly = $false
        if ($mainOpTypeId -and $callerDetail.'_plugintypeid_value' -and ([Guid]$callerDetail.'_plugintypeid_value') -eq $mainOpTypeId) {
            $mainOpBoundCorrectly = $true
        }

        $sdkMessageId = Find-DataverseRecordId @dv -EntitySetName "sdkmessages" -IdField "sdkmessageid" -Filter "name eq '$($c.CallerMessage)'"
        $dispatcherStepId = $null
        if ($sdkMessageId -and $dispatcherTypeId) {
            $dispatcherStepId = Find-DataverseRecordId @dv -EntitySetName "sdkmessageprocessingsteps" -IdField "sdkmessageprocessingstepid" `
                -Filter "_plugintypeid_value eq $dispatcherTypeId and _sdkmessageid_value eq $sdkMessageId and stage eq 10"
        }

        $workflowName = "Worker Flow - $($c.Consumer)"
        $workflowId = Find-DataverseRecordId @dv -EntitySetName "workflows" -IdField "workflowid" -Filter "name eq '$workflowName' and category eq 5"
        $workflowActive = $false
        if ($workflowId) {
            $state = (Invoke-Dataverse @dv -Method GET -Path "workflows($workflowId)?`$select=statecode").statecode
            $workflowActive = ($state -eq 1)
        }

        $healthy = ([bool]$dispatcherStepId) -and $mainOpBoundCorrectly -and $stepTypeOk

        $rows += [pscustomobject]@{
            Consumer                          = $c.Consumer
            PreValidationStepRegistered       = [bool]$dispatcherStepId
            MainOperationBoundCorrectly       = $mainOpBoundCorrectly
            AllowedCustomProcessingStepTypeOk = $stepTypeOk
            WorkerFlowExists                  = [bool]$workflowId
            WorkerFlowActive                  = $workflowActive
            Healthy                            = $healthy
        }
    }

    return $rows
}

Export-ModuleMember -Function `
    New-FlowTriggerEnvironment, `
    Install-FlowTriggerSolution, Get-FlowTriggerConsumer, Add-FlowTriggerConsumer, `
    New-FlowTriggerWorkerFlow, `
    Grant-FlowTriggerCallerAccess, Revoke-FlowTriggerCallerAccess, `
    New-FlowTriggerRestrictedMakerRole, Grant-FlowTriggerMakerVisibility, Revoke-FlowTriggerMakerVisibility, `
    Test-FlowTriggerConsumer, Get-FlowTriggerLoadTestPhaseBreakdown, `
    Enable-FlowTriggerAuditing, Get-FlowTriggerAuditLog, Get-FlowTriggerAccessReport, Get-FlowTriggerDeploymentStatus
