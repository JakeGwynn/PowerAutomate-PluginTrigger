<#
.SYNOPSIS
    Idempotently deploys (or updates) the "Flow Trigger Action Demo" solution
    to a single Dataverse environment: publisher, solution, the flow-result
    table, the shared plug-in assembly/type, a Business Event catalog, and one
    caller/event Custom API pair + marker table + Security Role per consumer
    listed in consumers.json.

.DESCRIPTION
    Safe to re-run: every step first checks whether the component already
    exists (by unique name / logical name / typename) and only creates what's
    missing, so adding a new consumer to consumers.json and re-running this
    script will only create that consumer's new components.

    Authentication: Azure CLI. Run `az login` (and `az account set
    --subscription <sub>` if you have more than one) for the tenant that owns
    -EnvironmentUrl before running this script.

.PARAMETER PublisherPrefix
    Choose this once per environment at first deploy. Every table, column,
    and Custom API name this script creates is derived from this prefix
    (e.g. "flowtrig" -> flowtrig_flowresult, flowtrig_RunFlow). It is
    also passed to the plug-in as its Configuration string, so the same
    compiled assembly answers with the matching schema names at runtime - see
    plugin/RunFlowDispatcher.cs. Dataverse schema logical names cannot be
    renamed after creation, so changing this on a *subsequent* re-run against
    an environment that was already deployed with a different prefix is not
    supported - it would create a second, parallel set of components rather
    than renaming the first. Pick a new prefix only for a fresh environment.
    Must be 8 characters or fewer - it becomes the publisher's
    customizationprefix, which Dataverse hard-caps at 8 characters (confirmed
    live: a longer value is rejected at publisher-creation time).

.PARAMETER EnvironmentUrl
    e.g. https://yourorg.crm.dynamics.com

.EXAMPLE
    .\Deploy-FlowTriggerSolution.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,

    [string] $ConsumersPath,
    [string] $PluginAssemblyPath,

    [string] $PublisherUniqueName   = "flowtrigger",
    [string] $PublisherFriendlyName = "Flow Trigger",
    [string] $PublisherPrefix       = "flowtrig",

    [string] $SolutionUniqueName    = "FlowTriggerActionDemo",
    [string] $SolutionFriendlyName  = "Flow Trigger Action Demo",
    [string] $SolutionVersion       = "1.0.0.0"
)

$ErrorActionPreference = "Stop"
if ($PublisherPrefix.Length -gt 8) {
    throw "PublisherPrefix '$PublisherPrefix' is $($PublisherPrefix.Length) characters - Dataverse's publisher.customizationprefix field hard-caps this at 8 characters. Choose a shorter prefix."
}
if (-not $ConsumersPath) { $ConsumersPath = Join-Path $PSScriptRoot "consumers.json" }
Import-Module (Join-Path $PSScriptRoot "DvHelper.psm1") -Force

function Write-Step($message) { Write-Host ">> $message" -ForegroundColor Cyan }
function Write-Ok($message)   { Write-Host "   OK: $message" -ForegroundColor Green }

# ---------------------------------------------------------------------------
# 0. Resolve the plugin assembly + connect
# ---------------------------------------------------------------------------
if (-not $PluginAssemblyPath) {
    $candidate = Get-ChildItem (Join-Path $PSScriptRoot "..\plugin\bin") -Filter "FlowTrigger.Plugins.dll" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $candidate) {
        throw "Could not find FlowTrigger.Plugins.dll under plugin\bin. Build the plugin first: dotnet build plugin\FlowTrigger.Plugins.csproj -c Release"
    }
    $PluginAssemblyPath = $candidate.FullName
}
Write-Step "Using plugin assembly: $PluginAssemblyPath"

Write-Step "Connecting to $EnvironmentUrl"
$token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
$whoAmI = Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token
Write-Ok "Connected as user $($whoAmI.UserId)"

$dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }

$rootBusinessUnitId = (Invoke-Dataverse @dv -Method GET -Path "businessunits?`$select=businessunitid&`$filter=_parentbusinessunitid_value eq null&`$top=1").value[0].businessunitid
Write-Ok "Root business unit: $rootBusinessUnitId"

# ---------------------------------------------------------------------------
# 1. Publisher
# ---------------------------------------------------------------------------
Write-Step "Publisher '$PublisherUniqueName'"
$publisherId = Find-DataverseRecordId @dv -EntitySetName "publishers" -IdField "publisherid" -Filter "uniquename eq '$PublisherUniqueName'"
if (-not $publisherId) {
    $publisherId = Invoke-Dataverse @dv -Method POST -Path "publishers" -Body @{
        uniquename                  = $PublisherUniqueName
        friendlyname                = $PublisherFriendlyName
        customizationprefix         = $PublisherPrefix
        customizationoptionvalueprefix = 10000
    }
    Write-Ok "Created publisher ($publisherId)"
} else {
    Write-Ok "Already exists ($publisherId)"
}

# ---------------------------------------------------------------------------
# 2. Solution
# ---------------------------------------------------------------------------
Write-Step "Solution '$SolutionUniqueName'"
$solutionId = Find-DataverseRecordId @dv -EntitySetName "solutions" -IdField "solutionid" -Filter "uniquename eq '$SolutionUniqueName'"
if (-not $solutionId) {
    $solutionId = Invoke-Dataverse @dv -Method POST -Path "solutions" -Body @{
        uniquename    = $SolutionUniqueName
        friendlyname  = $SolutionFriendlyName
        version       = $SolutionVersion
        "publisherid@odata.bind" = "/publishers($publisherId)"
    }
    Write-Ok "Created solution ($solutionId)"
} else {
    Write-Ok "Already exists ($solutionId)"
}

# ---------------------------------------------------------------------------
# Helper: create a minimal custom table if it doesn't exist yet.
# Every table gets a default primary "name" text column for free - that's
# all the marker tables (used purely to mint a scoped privilege) need.
# ---------------------------------------------------------------------------
function Ensure-Table {
    param(
        [string] $LogicalName,      # e.g. "$($PublisherPrefix)_flowresult" - must already include the publisher prefix
        [string] $DisplayName,
        [string] $DisplayCollectionName,
        [string] $PrimaryFieldDisplayName = "Name"
    )

    $existing = $null
    try {
        $existing = Invoke-Dataverse @script:dv -Method GET -Path "EntityDefinitions(LogicalName='$LogicalName')?`$select=LogicalName"
    } catch { }

    if ($existing) {
        Write-Ok "Table '$LogicalName' already exists"
        return
    }

    Invoke-Dataverse @script:dv -Method POST -Path "EntityDefinitions" -SolutionUniqueName $SolutionUniqueName -Body @{
        "@odata.type"          = "Microsoft.Dynamics.CRM.EntityMetadata"
        SchemaName             = $LogicalName
        DisplayName            = @{ "@odata.type" = "Microsoft.Dynamics.CRM.Label"; LocalizedLabels = @(@{ "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"; Label = $DisplayName; LanguageCode = 1033 }) }
        DisplayCollectionName  = @{ "@odata.type" = "Microsoft.Dynamics.CRM.Label"; LocalizedLabels = @(@{ "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"; Label = $DisplayCollectionName; LanguageCode = 1033 }) }
        OwnershipType          = "UserOwned"
        IsActivity             = $false
        HasActivities          = $false
        HasNotes               = $false
        Attributes             = @(
            @{
                "@odata.type" = "Microsoft.Dynamics.CRM.StringAttributeMetadata"
                SchemaName    = "$($LogicalName)_name"
                DisplayName   = @{ "@odata.type" = "Microsoft.Dynamics.CRM.Label"; LocalizedLabels = @(@{ "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"; Label = $PrimaryFieldDisplayName; LanguageCode = 1033 }) }
                RequiredLevel = @{ Value = "None" }
                MaxLength     = 100
                FormatName    = @{ Value = "Text" }
                IsPrimaryName = $true
            }
        )
    } | Out-Null

    Write-Ok "Created table '$LogicalName'"
    Start-Sleep -Seconds 3   # table provisioning is async server-side; brief settle before adding columns
}

function Ensure-StringColumn {
    param([string] $EntityLogicalName, [string] $ColumnLogicalName, [string] $DisplayLabel, [int] $MaxLength = 1000)

    $existing = $null
    try {
        $existing = Invoke-Dataverse @script:dv -Method GET -Path "EntityDefinitions(LogicalName='$EntityLogicalName')/Attributes(LogicalName='$ColumnLogicalName')?`$select=LogicalName"
    } catch { }
    if ($existing) { return }

    Invoke-Dataverse @script:dv -Method POST -Path "EntityDefinitions(LogicalName='$EntityLogicalName')/Attributes" -SolutionUniqueName $SolutionUniqueName -Body @{
        "@odata.type" = "Microsoft.Dynamics.CRM.StringAttributeMetadata"
        SchemaName    = $ColumnLogicalName
        DisplayName   = @{ "@odata.type" = "Microsoft.Dynamics.CRM.Label"; LocalizedLabels = @(@{ "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"; Label = $DisplayLabel; LanguageCode = 1033 }) }
        RequiredLevel = @{ Value = "None" }
        MaxLength     = $MaxLength
        FormatName    = @{ Value = "Text" }
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 3. Flow-result table (worker flows write their result here; the plug-in polls it)
# ---------------------------------------------------------------------------
$resultTable = "$($PublisherPrefix)_flowresult"
Write-Step "Table '$resultTable'"
Ensure-Table -LogicalName $resultTable -DisplayName "Flow Result" -DisplayCollectionName "Flow Results"
Ensure-StringColumn -EntityLogicalName $resultTable -ColumnLogicalName "$($PublisherPrefix)_correlationid" -DisplayLabel "Correlation Id" -MaxLength 100
Ensure-StringColumn -EntityLogicalName $resultTable -ColumnLogicalName "$($PublisherPrefix)_status"        -DisplayLabel "Status"         -MaxLength 100
Ensure-StringColumn -EntityLogicalName $resultTable -ColumnLogicalName "$($PublisherPrefix)_message"        -DisplayLabel "Message"        -MaxLength 4000
Ensure-StringColumn -EntityLogicalName $resultTable -ColumnLogicalName "$($PublisherPrefix)_messagename"     -DisplayLabel "Message Name"   -MaxLength 200
Write-Ok "$resultTable ready"

# ---------------------------------------------------------------------------
# 4. Plug-in assembly + plug-in type
# ---------------------------------------------------------------------------
Write-Step "Plug-in assembly 'FlowTrigger.Plugins'"
$assemblyBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($PluginAssemblyPath))
$assemblyId = Find-DataverseRecordId @dv -EntitySetName "pluginassemblies" -IdField "pluginassemblyid" -Filter "name eq 'FlowTrigger.Plugins'"
if (-not $assemblyId) {
    $assemblyId = Invoke-Dataverse @dv -Method POST -Path "pluginassemblies" -SolutionUniqueName $SolutionUniqueName -Body @{
        name          = "FlowTrigger.Plugins"
        content       = $assemblyBytes
        sourcetype    = 0   # Database
        isolationmode = 2   # Sandbox
    }
    Write-Ok "Registered plug-in assembly ($assemblyId)"
} else {
    Invoke-Dataverse @dv -Method PATCH -Path "pluginassemblies($assemblyId)" -Body @{ content = $assemblyBytes } | Out-Null
    Write-Ok "Updated existing plug-in assembly content ($assemblyId)"
}

$pluginTypeName = "FlowTrigger.Plugins.RunFlowDispatcher"
$pluginTypeId = Find-DataverseRecordId @dv -EntitySetName "plugintypes" -IdField "plugintypeid" -Filter "typename eq '$pluginTypeName'"
if (-not $pluginTypeId) {
    # friendlyname must be unique across every plugintype in the environment -
    # colliding with another prefix's plugintype record fails with "A record
    # with matching key values already exists.", even though the two live
    # under different typename/assembly. Qualifying it with $PublisherPrefix
    # keeps two different prefixes deployable side-by-side in the same
    # environment.
    $pluginTypeId = Invoke-Dataverse @dv -Method POST -Path "plugintypes" -Body @{
        name          = $pluginTypeName
        friendlyname  = "RunFlowDispatcher ($PublisherPrefix)"
        typename      = $pluginTypeName
        "pluginassemblyid@odata.bind" = "/pluginassemblies($assemblyId)"
    }
    Write-Ok "Registered plug-in type ($pluginTypeId)"
} else {
    Write-Ok "Plug-in type already registered ($pluginTypeId)"
}

# RunFlowMainOperation is the trivial "other half" - see plugin/RunFlowMainOperation.cs
# for why this split exists (PreValidation-vs-transaction self-deadlock). This
# is the type bound as each caller Custom API's Main Operation implementation
# (CustomAPI.PluginTypeId); RunFlowDispatcher itself is instead registered
# below as an explicit PreValidation-stage SdkMessageProcessingStep.
$mainOpTypeName = "FlowTrigger.Plugins.RunFlowMainOperation"
$mainOpTypeId = Find-DataverseRecordId @dv -EntitySetName "plugintypes" -IdField "plugintypeid" -Filter "typename eq '$mainOpTypeName'"
if (-not $mainOpTypeId) {
    $mainOpTypeId = Invoke-Dataverse @dv -Method POST -Path "plugintypes" -Body @{
        name          = $mainOpTypeName
        friendlyname  = "RunFlowMainOperation ($PublisherPrefix)"
        typename      = $mainOpTypeName
        "pluginassemblyid@odata.bind" = "/pluginassemblies($assemblyId)"
    }
    Write-Ok "Registered plug-in type ($mainOpTypeId)"
} else {
    Write-Ok "Plug-in type already registered ($mainOpTypeId)"
}

# ---------------------------------------------------------------------------
# 5. Business Event catalog: root (solution) -> category ("Flow Events")
# ---------------------------------------------------------------------------
Write-Step "Business Event catalog"
$rootCatalogId = Find-DataverseRecordId @dv -EntitySetName "catalogs" -IdField "catalogid" -Filter "uniquename eq '$($PublisherPrefix)_$SolutionUniqueName'"
if (-not $rootCatalogId) {
    $rootCatalogId = Invoke-Dataverse @dv -Method POST -Path "catalogs" -SolutionUniqueName $SolutionUniqueName -Body @{
        uniquename  = "$($PublisherPrefix)_$SolutionUniqueName"
        name        = $SolutionFriendlyName
        displayname = $SolutionFriendlyName
        description = "Root catalog for the $SolutionFriendlyName solution."
    }
    Write-Ok "Created root catalog ($rootCatalogId)"
} else {
    Write-Ok "Root catalog already exists ($rootCatalogId)"
}

$categoryCatalogId = Find-DataverseRecordId @dv -EntitySetName "catalogs" -IdField "catalogid" -Filter "uniquename eq '$($PublisherPrefix)_FlowEvents'"
if (-not $categoryCatalogId) {
    $categoryCatalogId = Invoke-Dataverse @dv -Method POST -Path "catalogs" -SolutionUniqueName $SolutionUniqueName -Body @{
        uniquename  = "$($PublisherPrefix)_FlowEvents"
        name        = "Flow Events"
        displayname = "Flow Events"
        description = "Category grouping business events for the Power Automate trigger."
        "ParentCatalogId@odata.bind" = "/catalogs($rootCatalogId)"
    }
    Write-Ok "Created 'Flow Events' category ($categoryCatalogId)"
} else {
    Write-Ok "'Flow Events' category already exists ($categoryCatalogId)"
}

# ---------------------------------------------------------------------------
# 6. Per-consumer: marker table -> privilege -> caller/event Custom APIs -> catalog assignment -> security role
# ---------------------------------------------------------------------------
# Each consumer gets a dedicated marker table ($($PublisherPrefix)_ep_<slug>)
# that exists purely to mint an independent Dataverse privilege for that one
# consumer. Dataverse enforces ExecutePrivilegeName before the plugin ever
# runs - zero plugin code is involved in authorization. This is deliberately
# simple and fully declarative rather than clever: one table per consumer is
# real schema sprawl at 50+ consumers, but every consumer's access is
# completely independent of every other consumer's, which is the property
# that matters most for a governed, auditable process.
#
# The SAME privilege gates BOTH Custom APIs for a consumer:
#   - the CALLER Custom API ($($PublisherPrefix)_RunFlow[_Consumer]) - the
#     endpoint an external caller invokes.
#   - the EVENT Custom API ($($PublisherPrefix)_OnFlowRequested[_Consumer]) -
#     the business event RunFlowDispatcher raises, and what a Power Automate
#     flow subscribes to as its trigger.
# Without the event API's own ExecutePrivilegeName set, anyone authenticated
# in the environment could bypass the caller API entirely and invoke the
# event API directly, firing the worker flow with attacker-controlled input.
# Requiring the SAME privilege on both closes that bypass at no cost to a
# legitimate caller: RunFlowDispatcher raises the event as the real calling
# user (see plugin/RunFlowDispatcher.cs), who already holds this privilege by
# virtue of having passed the caller API's own check to get this far.
#
# See docs/PERMISSIONS.md for the full caller-vs-maker permission model.
$consumersConfig = Get-Content $ConsumersPath -Raw | ConvertFrom-Json

$summary = @()

foreach ($consumer in $consumersConfig.consumers) {
    $id       = $consumer.id
    $isDefault = ($id -eq "Default")
    $suffix     = if ($isDefault) { "" } else { "_$id" }
    $callerName = "$($PublisherPrefix)_RunFlow$suffix"
    $eventName  = "$($PublisherPrefix)_OnFlowRequested$suffix"
    $roleName   = "Flow Trigger Caller - $id"

    Write-Step "Consumer '$id' ($callerName / $eventName)"

    # -- dedicated marker table (exists purely to mint an independent privilege) --
    $slug = ($id.ToLowerInvariant() -replace '[^a-z0-9]', '')
    $markerTable = "$($PublisherPrefix)_ep_$slug"
    Ensure-Table -LogicalName $markerTable -DisplayName "Caller Privilege Marker - $id" -DisplayCollectionName "Caller Privilege Markers - $id" -PrimaryFieldDisplayName "Name"
    $privilegeId = Get-EntityPrivilegeId @dv -EntityLogicalName $markerTable -AccessRight "Read"

    # -- caller Custom API (Main Operation bound to the trivial "relay" plug-in
    #    type - RunFlowMainOperation; the real work happens in a SEPARATE
    #    PreValidation-stage step for RunFlowDispatcher, registered below,
    #    outside the Main Operation's transaction - see plugin/RunFlowMainOperation.cs) --
    #
    # allowedcustomprocessingsteptype MUST be 2 (Sync and Async) for the
    # PreValidation step below to be accepted at all - Dataverse rejects
    # "Custom Sdkmessageprocessingsteps are not allowed for this message" if
    # it's 0 (None), which is what earlier deploys (before this split
    # existed) used. This field is documented as immutable after create, so
    # an environment deployed under the old value must have its caller
    # Custom API deleted and recreated - not merely patched - to pick up 2.
    $callerId = Find-DataverseRecordId @dv -EntitySetName "customapis" -IdField "customapiid" -Filter "uniquename eq '$callerName'"
    if ($callerId) {
        $existingStepType = (Invoke-Dataverse @dv -Method GET -Path "customapis($callerId)?`$select=allowedcustomprocessingsteptype").allowedcustomprocessingsteptype
        if ($existingStepType -ne 2) {
            Write-Ok "Caller Custom API exists but allowedcustomprocessingsteptype=$existingStepType (immutable) - deleting and recreating with 2 (Sync and Async)"
            Invoke-Dataverse @dv -Method DELETE -Path "customapis($callerId)" | Out-Null
            $callerId = $null
        } else {
            Write-Ok "Caller Custom API already exists ($callerId)"
            # Defensive retrofit in case PluginTypeId was ever pointed at the
            # dispatcher directly - no-op once already correct.
            Invoke-Dataverse @dv -Method PATCH -Path "customapis($callerId)" -Body @{
                "PluginTypeId@odata.bind" = "/plugintypes($mainOpTypeId)"
            } | Out-Null
        }
    }
    if (-not $callerId) {
        $callerId = Invoke-Dataverse @dv -Method POST -Path "customapis" -SolutionUniqueName $SolutionUniqueName -Body @{
            uniquename                     = $callerName
            name                            = $callerName
            displayname                     = "Run Flow ($id)"
            description                     = "Synchronously triggers the '$id' worker flow via a Dataverse business event and returns its result. Requires the '$roleName' security role."
            bindingtype                     = 0   # Global
            isfunction                      = $false
            isprivate                       = $false
            allowedcustomprocessingsteptype = 2   # Sync and Async - required so our own PreValidation step (below) can be registered
            # executeprivilegename is set in the patch pass below, once we can
            # resolve the marker table's actual privilege *name* string (this
            # field takes a name, not a GUID, and Dataverse validates it against
            # an existing privilege at write time).
            "PluginTypeId@odata.bind"       = "/plugintypes($mainOpTypeId)"
            CustomAPIRequestParameters      = @(
                @{ uniquename = "InputJson"; name = "$callerName.InputJson"; displayname = "Input Json"; type = 10; isoptional = $false }
            )
            CustomAPIResponseProperties     = @(
                @{ uniquename = "OutputJson"; name = "$callerName.OutputJson"; displayname = "Output Json"; type = 10 }
            )
        }
        Write-Ok "Created caller Custom API ($callerId)"
    }

    # -- RunFlowDispatcher: explicit PreValidation-stage step on the caller
    #    message (see plugin/RunFlowDispatcher.cs remarks for why this MUST
    #    be PreValidation and MUST NOT be the Main Operation binding above) --
    $callerSdkMessageId = Find-DataverseRecordId @dv -EntitySetName "sdkmessages" -IdField "sdkmessageid" -Filter "name eq '$callerName'"
    if (-not $callerSdkMessageId) {
        throw "Could not resolve the sdkmessage record for '$callerName' - the caller Custom API may not have finished provisioning yet. Re-run this script."
    }
    $dispatcherStepName = "RunFlowDispatcher: $callerName (PreValidation)"
    $dispatcherStepId = Find-DataverseRecordId @dv -EntitySetName "sdkmessageprocessingsteps" -IdField "sdkmessageprocessingstepid" `
        -Filter "_plugintypeid_value eq $pluginTypeId and _sdkmessageid_value eq $callerSdkMessageId"
    if (-not $dispatcherStepId) {
        # 'configuration' is passed verbatim to RunFlowDispatcher's two-arg
        # IPlugin constructor at run time (unsecureConfig) - this is what
        # makes the plugin compute this environment's actual schema names
        # (e.g. "$($PublisherPrefix)_flowresult") from $PublisherPrefix
        # without needing a per-tenant rebuild. See plugin/RunFlowDispatcher.cs.
        $dispatcherStepId = Invoke-Dataverse @dv -Method POST -Path "sdkmessageprocessingsteps" -SolutionUniqueName $SolutionUniqueName -Body @{
            name                 = $dispatcherStepName
            "plugintypeid@odata.bind" = "/plugintypes($pluginTypeId)"
            "sdkmessageid@odata.bind" = "/sdkmessages($callerSdkMessageId)"
            stage                = 10   # Pre-validation - runs with NO enclosing transaction
            mode                 = 0    # Synchronous
            rank                 = 1
            supporteddeployment  = 0    # Server only
            configuration        = $PublisherPrefix
        }
        Write-Ok "Registered RunFlowDispatcher at PreValidation for '$callerName' ($dispatcherStepId), configuration='$PublisherPrefix'"
    } else {
        # Defensive: keep the step's Configuration in sync with this run's
        # -PublisherPrefix. Only meaningful if you're re-running with the
        # SAME prefix an environment was originally deployed with - changing
        # the prefix on a subsequent run does NOT rename the already-created
        # schema (Dataverse logical names are immutable), it would just point
        # the plugin at names that don't exist. See -PublisherPrefix's help.
        Invoke-Dataverse @dv -Method PATCH -Path "sdkmessageprocessingsteps($dispatcherStepId)" -Body @{ configuration = $PublisherPrefix } | Out-Null
        Write-Ok "RunFlowDispatcher PreValidation step already registered for '$callerName' ($dispatcherStepId)"
    }


    # -- event Custom API (business event; no plug-in - async subscribers only) --
    $eventId = Find-DataverseRecordId @dv -EntitySetName "customapis" -IdField "customapiid" -Filter "uniquename eq '$eventName'"
    if (-not $eventId) {
        $eventId = Invoke-Dataverse @dv -Method POST -Path "customapis" -SolutionUniqueName $SolutionUniqueName -Body @{
            uniquename                     = $eventName
            name                            = $eventName
            displayname                     = "On Flow Requested ($id)"
            description                     = "Business event raised by $callerName. Bind the '$id' worker flow's 'When an action is performed' trigger to this event."
            bindingtype                     = 0   # Global
            isfunction                      = $false
            isprivate                       = $false
            allowedcustomprocessingsteptype = 1   # Async Only - recommended for the business-events pattern
            CustomAPIRequestParameters      = @(
                @{ uniquename = "InputJson";     name = "$eventName.InputJson";     displayname = "Input Json";     type = 10; isoptional = $true }
                @{ uniquename = "CorrelationId"; name = "$eventName.CorrelationId"; displayname = "Correlation Id"; type = 10; isoptional = $true }
            )
        }
        Write-Ok "Created event Custom API ($eventId)"
    } else {
        Write-Ok "Event Custom API already exists ($eventId)"
    }

    # -- catalog assignment: makes $eventName selectable in the flow trigger picker --
    $assignmentName = "$($eventName)_Assignment"   # $eventName already carries the publisher prefix
    $assignmentId = Find-DataverseRecordId @dv -EntitySetName "catalogassignments" -IdField "catalogassignmentid" -Filter "name eq '$assignmentName'"
    if (-not $assignmentId) {
        $assignmentId = Invoke-Dataverse @dv -Method POST -Path "catalogassignments" -SolutionUniqueName $SolutionUniqueName -Body @{
            name        = $assignmentName
            "CatalogId@odata.bind"   = "/catalogs($categoryCatalogId)"
            # The 'object' lookup on catalogassignment is polymorphic; bind via
            # the type-specific navigation property (CustomAPIId here) rather
            # than a generic 'object' key - this also sets objectidtype implicitly.
            "CustomAPIId@odata.bind" = "/customapis($eventId)"
        }
        Write-Ok "Cataloged '$eventName' as a business event ($assignmentId)"
    } else {
        Write-Ok "Catalog assignment already exists ($assignmentId)"
    }

    # -- security role granting exactly this consumer's privilege --
    # Depth is "Basic" (User level) uniformly, for consistency and to avoid
    # over-granting by default - no code queries a marker table's row
    # content, so depth has no functional effect here, only the possession
    # of the privilege itself matters.
    $roleId = Find-DataverseRecordId @dv -EntitySetName "roles" -IdField "roleid" -Filter "name eq '$roleName'"
    if (-not $roleId) {
        $roleId = Invoke-Dataverse @dv -Method POST -Path "roles" -SolutionUniqueName $SolutionUniqueName -Body @{
            name = $roleName
            "businessunitid@odata.bind" = "/businessunits($rootBusinessUnitId)"
        }
        Write-Ok "Created security role '$roleName' ($roleId)"
    } else {
        Write-Ok "Security role '$roleName' already exists ($roleId)"
    }
    Invoke-Dataverse @dv -Method POST -Path "roles($roleId)/Microsoft.Dynamics.CRM.AddPrivilegesRole" -Body @{
        Privileges = @(
            @{ PrivilegeId = $privilegeId; Depth = "Basic" }
        )
    } | Out-Null

    $summary += [pscustomobject]@{
        Consumer          = $id
        "Caller message"  = $callerName
        "Event message"   = $eventName
        "Security role"   = $roleName
        "Marker table"    = $markerTable
    }
}

# executeprivilegename must be the *name* string, not the id - patch each
# consumer's caller AND event Custom API now that we can resolve its marker
# table's privilege name. Both Custom APIs get the SAME privilege - see the
# comment at the top of this section for why the event API needs it too.
$privNameCache = @{}
foreach ($consumer in $consumersConfig.consumers) {
    $id = $consumer.id
    $suffix = if ($id -eq "Default") { "" } else { "_$id" }
    $callerName = "$($PublisherPrefix)_RunFlow$suffix"
    $eventName = "$($PublisherPrefix)_OnFlowRequested$suffix"
    $markerTable = "$($PublisherPrefix)_ep_$(($id.ToLowerInvariant() -replace '[^a-z0-9]', ''))"

    if (-not $privNameCache.ContainsKey($markerTable)) {
        $privNameCache[$markerTable] = (Invoke-Dataverse @dv -Method GET -Path "EntityDefinitions(LogicalName='$markerTable')?`$select=LogicalName,Privileges").Privileges
    }

    $privName = $privNameCache[$markerTable] |
        Where-Object { $_.PrivilegeType -eq "Read" } | Select-Object -First 1 -ExpandProperty Name
    $callerId = Find-DataverseRecordId @dv -EntitySetName "customapis" -IdField "customapiid" -Filter "uniquename eq '$callerName'"
    Invoke-Dataverse @dv -Method PATCH -Path "customapis($callerId)" -Body @{ executeprivilegename = $privName } | Out-Null

    $eventId = Find-DataverseRecordId @dv -EntitySetName "customapis" -IdField "customapiid" -Filter "uniquename eq '$eventName'"
    Invoke-Dataverse @dv -Method PATCH -Path "customapis($eventId)" -Body @{ executeprivilegename = $privName } | Out-Null
}

Write-Host ""
Write-Host "=== Deployed to $EnvironmentUrl ===" -ForegroundColor Yellow
$summary | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Assign callers to their Security Role (deploy\Add-CallerRoleMembers.ps1) - see docs/PERMISSIONS.md."
Write-Host "  2. Build a Power Automate flow per consumer, triggered by Dataverse 'When an action is performed' > <event message>, that writes its result to $resultTable ($($PublisherPrefix)_correlationid, $($PublisherPrefix)_status, $($PublisherPrefix)_message)."
Write-Host "  3. Test with deploy\Invoke-FlowTrigger.ps1 -EnvironmentUrl $EnvironmentUrl -Consumer <id>"
