<#
.SYNOPSIS
    PERF-TESTING COPY of ../../deploy/Deploy-FlowTriggerSolution.ps1 -
    idempotently deploys the telemetry-instrumented Flow Trigger solution to
    a single Dataverse environment, fully separate from (and side-by-side
    with) the production deployment.

.DESCRIPTION
    A genuine copy was required here, not just a differently-parameterized
    invocation of the real script: the real script's plugin-assembly and
    plugin-type lookups use HARDCODED literal names ("FlowTrigger.Plugins",
    "FlowTrigger.Plugins.RunFlowDispatcher", "FlowTrigger.Plugins.RunFlowMainOperation")
    rather than deriving them from whichever assembly is actually being
    deployed. Running the real script against this repo's differently-named,
    independently-signed FlowTrigger.Plugins.PerfTest.dll would find the
    EXISTING production pluginassemblies record (same hardcoded name) and try
    to PATCH its content - which Dataverse correctly rejects, since a plug-in
    assembly's registered identity can't be silently swapped for a different
    one via a content update (confirmed live: "Plugin Assembly fully
    qualified name has changed from: [...] to: [...]").

    Every other line of logic below (publisher, solution, flow-result table,
    Business Event catalog, per-consumer marker table / Custom API pair /
    Security Role, the executeprivilegename patch pass) is UNCHANGED from the
    real script - copied verbatim. The only differences from the real script
    are marked "PERF-TESTING CHANGE" in comments below:
      1. The plugin-assembly and plugin-type search/create names use this
         copy's own actual assembly/type names instead of the production
         ones, so this deployment gets its OWN pluginassemblies/plugintypes
         records and never touches the production ones.
      2. Two extra artifacts only this copy needs are folded in right after
         the flow-result table section: an extra <prefix>_writtenutc column
         on it (a full sub-second-precision UTC timestamp the worker flow
         writes, since Dataverse's own createdon only has 1-second
         resolution), and a brand-new <prefix>_calltelemetry table that
         RunFlowDispatcherTelemetry.cs writes one row to per call. See
         perf-testing/README.md for the full column reference.
      3. Defaults point at this deployment's own publisher/prefix/solution.

.PARAMETER PublisherPrefix
    Same constraints as the real script (8 characters max - Dataverse's
    publisher.customizationprefix hard cap). Defaults to "flowperf" here.

.EXAMPLE
    .\Deploy-PerfTestEnvironment.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,

    [string] $ConsumersPath,
    [string] $PluginAssemblyPath,

    [string] $PublisherUniqueName   = "flowtriggerperftest",
    [string] $PublisherFriendlyName = "Flow Trigger Perf Test",
    [string] $PublisherPrefix       = "flowperf",

    [string] $SolutionUniqueName    = "FlowTriggerPerfTest",
    [string] $SolutionFriendlyName  = "Flow Trigger Perf Test",
    [string] $SolutionVersion       = "1.0.0.0"
)

$ErrorActionPreference = "Stop"
if ($PublisherPrefix.Length -gt 8) {
    throw "PublisherPrefix '$PublisherPrefix' is $($PublisherPrefix.Length) characters - Dataverse's publisher.customizationprefix field hard-caps this at 8 characters. Choose a shorter prefix."
}
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not $ConsumersPath) { $ConsumersPath = Join-Path $PSScriptRoot "consumers.perftest.json" }
Import-Module (Join-Path $repoRoot "deploy\DvHelper.psm1") -Force

function Write-Step($message) { Write-Host ">> $message" -ForegroundColor Cyan }
function Write-Ok($message)   { Write-Host "   OK: $message" -ForegroundColor Green }

# ---------------------------------------------------------------------------
# 0. Resolve the plugin assembly + connect
# ---------------------------------------------------------------------------
if (-not $PluginAssemblyPath) {
    # PERF-TESTING CHANGE: looks for THIS copy's own build output
    # (FlowTrigger.Plugins.PerfTest.dll under perf-testing\plugin\bin), not
    # the production FlowTrigger.Plugins.dll.
    $candidate = Get-ChildItem (Join-Path $PSScriptRoot "..\plugin\bin") -Filter "FlowTrigger.Plugins.PerfTest.dll" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $candidate) {
        throw "Could not find FlowTrigger.Plugins.PerfTest.dll under perf-testing\plugin\bin. Build it first: dotnet build perf-testing\plugin\FlowTrigger.Plugins.PerfTest.csproj -c Release"
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

# PERF-TESTING ADDITION: not present in the real script - needed for the
# calltelemetry table's numeric columns (batchsize, pollattempts).
function Ensure-IntColumn {
    param([string] $EntityLogicalName, [string] $ColumnLogicalName, [string] $DisplayLabel)

    $existing = $null
    try {
        $existing = Invoke-Dataverse @script:dv -Method GET -Path "EntityDefinitions(LogicalName='$EntityLogicalName')/Attributes(LogicalName='$ColumnLogicalName')?`$select=LogicalName"
    } catch { }
    if ($existing) { return }

    Invoke-Dataverse @script:dv -Method POST -Path "EntityDefinitions(LogicalName='$EntityLogicalName')/Attributes" -SolutionUniqueName $SolutionUniqueName -Body @{
        "@odata.type" = "Microsoft.Dynamics.CRM.IntegerAttributeMetadata"
        SchemaName    = $ColumnLogicalName
        DisplayName   = @{ "@odata.type" = "Microsoft.Dynamics.CRM.Label"; LocalizedLabels = @(@{ "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"; Label = $DisplayLabel; LanguageCode = 1033 }) }
        RequiredLevel = @{ Value = "None" }
        MinValue      = 0
        MaxValue      = 2147483647
        Format        = "None"
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
# PERF-TESTING ADDITION: full sub-second-precision UTC write timestamp - see
# perf-testing/README.md for why createdon's 1-second resolution isn't
# enough to measure poll-detect latency precisely.
Ensure-StringColumn -EntityLogicalName $resultTable -ColumnLogicalName "$($PublisherPrefix)_writtenutc"      -DisplayLabel "Written Utc (precise)" -MaxLength 100
Write-Ok "$resultTable ready"

# PERF-TESTING ADDITION: brand-new table, not present in the real script.
# RunFlowDispatcherTelemetry.cs writes one row here per call - see
# perf-testing/README.md for the full column reference.
$telemetryTable = "$($PublisherPrefix)_calltelemetry"
Write-Step "Table '$telemetryTable'"
Ensure-Table -LogicalName $telemetryTable -DisplayName "Call Telemetry" -DisplayCollectionName "Call Telemetry"
Ensure-StringColumn -EntityLogicalName $telemetryTable -ColumnLogicalName "$($PublisherPrefix)_correlationid"       -DisplayLabel "Correlation Id"        -MaxLength 100
Ensure-StringColumn -EntityLogicalName $telemetryTable -ColumnLogicalName "$($PublisherPrefix)_consumer"            -DisplayLabel "Consumer"              -MaxLength 100
Ensure-IntColumn    -EntityLogicalName $telemetryTable -ColumnLogicalName "$($PublisherPrefix)_batchsize"           -DisplayLabel "Batch Size"
Ensure-StringColumn -EntityLogicalName $telemetryTable -ColumnLogicalName "$($PublisherPrefix)_t1dispatcherentry"   -DisplayLabel "T1 Dispatcher Entry"   -MaxLength 100
Ensure-StringColumn -EntityLogicalName $telemetryTable -ColumnLogicalName "$($PublisherPrefix)_t2beforeraise"       -DisplayLabel "T2 Before Raise"       -MaxLength 100
Ensure-StringColumn -EntityLogicalName $telemetryTable -ColumnLogicalName "$($PublisherPrefix)_t3afterraise"        -DisplayLabel "T3 After Raise"        -MaxLength 100
Ensure-StringColumn -EntityLogicalName $telemetryTable -ColumnLogicalName "$($PublisherPrefix)_t4pollloopentry"     -DisplayLabel "T4 Poll Loop Entry"    -MaxLength 100
Ensure-IntColumn    -EntityLogicalName $telemetryTable -ColumnLogicalName "$($PublisherPrefix)_pollattempts"        -DisplayLabel "Poll Attempts"
Ensure-StringColumn -EntityLogicalName $telemetryTable -ColumnLogicalName "$($PublisherPrefix)_t5resultdetected"    -DisplayLabel "T5 Result Detected"    -MaxLength 100
Ensure-StringColumn -EntityLogicalName $telemetryTable -ColumnLogicalName "$($PublisherPrefix)_resultrowcreatedon"  -DisplayLabel "Result Row CreatedOn"  -MaxLength 100
Ensure-StringColumn -EntityLogicalName $telemetryTable -ColumnLogicalName "$($PublisherPrefix)_resultrowwrittenutc" -DisplayLabel "Result Row WrittenUtc" -MaxLength 100
Ensure-StringColumn -EntityLogicalName $telemetryTable -ColumnLogicalName "$($PublisherPrefix)_t6dispatcherexit"    -DisplayLabel "T6 Dispatcher Exit"    -MaxLength 100
Ensure-StringColumn -EntityLogicalName $telemetryTable -ColumnLogicalName "$($PublisherPrefix)_outcome"             -DisplayLabel "Outcome"               -MaxLength 50
Write-Ok "$telemetryTable ready"

# ---------------------------------------------------------------------------
# 4. Plug-in assembly + plug-in type
# ---------------------------------------------------------------------------
Write-Step "Plug-in assembly 'FlowTrigger.Plugins.PerfTest'"
$assemblyBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($PluginAssemblyPath))
# PERF-TESTING CHANGE: searches/creates by THIS copy's own assembly name
# ("FlowTrigger.Plugins.PerfTest"), not the production "FlowTrigger.Plugins" -
# see this file's own top-of-file remarks for why reusing the production
# name here would fail.
$assemblyId = Find-DataverseRecordId @dv -EntitySetName "pluginassemblies" -IdField "pluginassemblyid" -Filter "name eq 'FlowTrigger.Plugins.PerfTest'"
if (-not $assemblyId) {
    $assemblyId = Invoke-Dataverse @dv -Method POST -Path "pluginassemblies" -SolutionUniqueName $SolutionUniqueName -Body @{
        name          = "FlowTrigger.Plugins.PerfTest"
        content       = $assemblyBytes
        sourcetype    = 0   # Database
        isolationmode = 2   # Sandbox
    }
    Write-Ok "Registered plug-in assembly ($assemblyId)"
} else {
    Invoke-Dataverse @dv -Method PATCH -Path "pluginassemblies($assemblyId)" -Body @{ content = $assemblyBytes } | Out-Null
    Write-Ok "Updated existing plug-in assembly content ($assemblyId)"
}

# PERF-TESTING CHANGE: this copy's own type names
# (FlowTrigger.Plugins.PerfTest.RunFlowDispatcherTelemetry /
# ...RunFlowMainOperationTelemetry), not the production ones.
$pluginTypeName = "FlowTrigger.Plugins.PerfTest.RunFlowDispatcherTelemetry"
$pluginTypeId = Find-DataverseRecordId @dv -EntitySetName "plugintypes" -IdField "plugintypeid" -Filter "typename eq '$pluginTypeName'"
if (-not $pluginTypeId) {
    $pluginTypeId = Invoke-Dataverse @dv -Method POST -Path "plugintypes" -Body @{
        name          = $pluginTypeName
        friendlyname  = "RunFlowDispatcherTelemetry ($PublisherPrefix)"
        typename      = $pluginTypeName
        "pluginassemblyid@odata.bind" = "/pluginassemblies($assemblyId)"
    }
    Write-Ok "Registered plug-in type ($pluginTypeId)"
} else {
    Write-Ok "Plug-in type already registered ($pluginTypeId)"
}

$mainOpTypeName = "FlowTrigger.Plugins.PerfTest.RunFlowMainOperationTelemetry"
$mainOpTypeId = Find-DataverseRecordId @dv -EntitySetName "plugintypes" -IdField "plugintypeid" -Filter "typename eq '$mainOpTypeName'"
if (-not $mainOpTypeId) {
    $mainOpTypeId = Invoke-Dataverse @dv -Method POST -Path "plugintypes" -Body @{
        name          = $mainOpTypeName
        friendlyname  = "RunFlowMainOperationTelemetry ($PublisherPrefix)"
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
# Unchanged from the real script - see deploy/Deploy-FlowTriggerSolution.ps1
# section 6's own comments for the full rationale (marker-table-per-consumer
# model, why both Custom APIs share the same ExecutePrivilegeName). Nothing
# here needed to change for the perf-testing copy - $pluginTypeId and
# $mainOpTypeId above already point at this copy's own plug-in types.
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

    $slug = ($id.ToLowerInvariant() -replace '[^a-z0-9]', '')
    $markerTable = "$($PublisherPrefix)_ep_$slug"
    Ensure-Table -LogicalName $markerTable -DisplayName "Caller Privilege Marker - $id" -DisplayCollectionName "Caller Privilege Markers - $id" -PrimaryFieldDisplayName "Name"
    $privilegeId = Get-EntityPrivilegeId @dv -EntityLogicalName $markerTable -AccessRight "Read"

    $callerId = Find-DataverseRecordId @dv -EntitySetName "customapis" -IdField "customapiid" -Filter "uniquename eq '$callerName'"
    if ($callerId) {
        $existingStepType = (Invoke-Dataverse @dv -Method GET -Path "customapis($callerId)?`$select=allowedcustomprocessingsteptype").allowedcustomprocessingsteptype
        if ($existingStepType -ne 2) {
            Write-Ok "Caller Custom API exists but allowedcustomprocessingsteptype=$existingStepType (immutable) - deleting and recreating with 2 (Sync and Async)"
            Invoke-Dataverse @dv -Method DELETE -Path "customapis($callerId)" | Out-Null
            $callerId = $null
        } else {
            Write-Ok "Caller Custom API already exists ($callerId)"
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

    $callerSdkMessageId = Find-DataverseRecordId @dv -EntitySetName "sdkmessages" -IdField "sdkmessageid" -Filter "name eq '$callerName'"
    if (-not $callerSdkMessageId) {
        throw "Could not resolve the sdkmessage record for '$callerName' - the caller Custom API may not have finished provisioning yet. Re-run this script."
    }
    $dispatcherStepName = "RunFlowDispatcherTelemetry: $callerName (PreValidation)"
    $dispatcherStepId = Find-DataverseRecordId @dv -EntitySetName "sdkmessageprocessingsteps" -IdField "sdkmessageprocessingstepid" `
        -Filter "_plugintypeid_value eq $pluginTypeId and _sdkmessageid_value eq $callerSdkMessageId"
    if (-not $dispatcherStepId) {
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
        Write-Ok "Registered RunFlowDispatcherTelemetry at PreValidation for '$callerName' ($dispatcherStepId), configuration='$PublisherPrefix'"
    } else {
        Invoke-Dataverse @dv -Method PATCH -Path "sdkmessageprocessingsteps($dispatcherStepId)" -Body @{ configuration = $PublisherPrefix } | Out-Null
        Write-Ok "RunFlowDispatcherTelemetry PreValidation step already registered for '$callerName' ($dispatcherStepId)"
    }

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

    $assignmentName = "$($eventName)_Assignment"
    $assignmentId = Find-DataverseRecordId @dv -EntitySetName "catalogassignments" -IdField "catalogassignmentid" -Filter "name eq '$assignmentName'"
    if (-not $assignmentId) {
        $assignmentId = Invoke-Dataverse @dv -Method POST -Path "catalogassignments" -SolutionUniqueName $SolutionUniqueName -Body @{
            name        = $assignmentName
            "CatalogId@odata.bind"   = "/catalogs($categoryCatalogId)"
            "CustomAPIId@odata.bind" = "/customapis($eventId)"
        }
        Write-Ok "Cataloged '$eventName' as a business event ($assignmentId)"
    } else {
        Write-Ok "Catalog assignment already exists ($assignmentId)"
    }

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
# table's privilege name. Both Custom APIs get the SAME privilege.
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
Write-Host "=== Perf-testing deployment ready on $EnvironmentUrl ===" -ForegroundColor Yellow
$summary | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Telemetry table: $telemetryTable   Precise write timestamp column: $($PublisherPrefix)_writtenutc on $resultTable" -ForegroundColor Yellow
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. .\Create-PerfTestWorkerFlow.ps1 -EnvironmentUrl $EnvironmentUrl -Consumer Default -ConnectionName <connection> -Activate"
Write-Host "  2. ..\..\deploy\Invoke-LoadTest.ps1 -EnvironmentUrl $EnvironmentUrl -Consumer Default -PublisherPrefix $PublisherPrefix -ResultsCsvPath .\perftest-load-results.csv"
Write-Host "  3. .\Get-PerfTestBreakdown.ps1 -EnvironmentUrl $EnvironmentUrl -ResultsCsvPath .\perftest-load-results.csv -PublisherPrefix $PublisherPrefix"
