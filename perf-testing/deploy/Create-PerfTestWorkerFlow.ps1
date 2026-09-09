<#
.SYNOPSIS
    PERF-TESTING COPY of ../../deploy/Create-WorkerFlow.ps1 - creates (and
    activates) a real Power Automate cloud flow for the perf-testing
    deployment's consumer, with ONE addition: it also writes a full
    sub-second-precision UTC timestamp (<prefix>_writtenutc, via the
    workflow-definition-language utcNow() function) alongside the normal
    result row fields, so deploy/Get-PerfTestBreakdown.ps1 can measure poll-
    detect latency precisely instead of being limited by Dataverse's
    1-second createdon resolution.

.DESCRIPTION
    Everything else is identical to the original script - same "When an
    action is performed" trigger, same "Add a new row" action, same
    Dataverse workflow-table-via-Web-API approach. See
    ../../deploy/Create-WorkerFlow.ps1's own remarks for why this has to be
    done this way (the interactive connection-consent step can't be
    automated) and requires a connected shared_commondataserviceforapps
    connection to already exist in the target environment.

.PARAMETER EventConsumer
    Which consumer's event to bind the trigger to, if different from
    -Consumer. Defaults to -Consumer.

.EXAMPLE
    .\Create-PerfTestWorkerFlow.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer Default -ConnectionName shared-commondataser-6c039e04-e309-4700-a8fe-d603aef5290e -Activate
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [Parameter(Mandatory)] [string] $Consumer,
    [Parameter(Mandatory)] [string] $ConnectionName,
    [string] $EventConsumer,
    [string] $PublisherPrefix     = "flowperf",
    [string] $SolutionUniqueName  = "FlowTriggerPerfTest",
    [string] $CatalogUniqueName,
    [string] $CategoryUniqueName,
    [string] $ResultEntitySetName,
    [switch] $Activate,
    [switch] $Force
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not $CatalogUniqueName)   { $CatalogUniqueName   = "$($PublisherPrefix)_$SolutionUniqueName" }
if (-not $CategoryUniqueName)  { $CategoryUniqueName  = "$($PublisherPrefix)_FlowEvents" }
if (-not $ResultEntitySetName) { $ResultEntitySetName = "$($PublisherPrefix)_flowresults" }
Import-Module (Join-Path $repoRoot "deploy\DvHelper.psm1") -Force

function Write-Step($message) { Write-Host ">> $message" -ForegroundColor Cyan }
function Write-Ok($message)   { Write-Host "   OK: $message" -ForegroundColor Green }

$token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null
$dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }

if (-not $EventConsumer) { $EventConsumer = $Consumer }
$eventName = if ($EventConsumer -eq "Default") { "$($PublisherPrefix)_OnFlowRequested" } else { "$($PublisherPrefix)_OnFlowRequested_$EventConsumer" }
$flowName  = "Perf Test Worker Flow - $Consumer"

Write-Step "Checking for an existing flow named '$flowName'"
$existingId = Find-DataverseRecordId @dv -EntitySetName "workflows" -IdField "workflowid" -Filter "name eq '$flowName' and category eq 5"
if ($existingId) {
    if (-not $Force) {
        Write-Ok "Already exists ($existingId) - delete it first if you want to recreate, or pass -Force"
        return
    }
    Invoke-Dataverse @dv -Method DELETE -Path "workflows($existingId)" | Out-Null
    Write-Ok "Deleted existing flow ($existingId) - recreating"
}

$triggerKey = "On_Flow_Requested"
$actionKey  = "Add_a_new_row"

$definition = @{
    '$schema'       = "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#"
    contentVersion  = "1.0.0.0"
    parameters      = @{
        '$connections'    = @{ defaultValue = @{}; type = "Object" }
        '$authentication' = @{ defaultValue = @{}; type = "SecureObject" }
    }
    triggers = @{
        $triggerKey = @{
            type   = "OpenApiConnectionWebhook"
            inputs = @{
                host = @{
                    connectionName = "shared_commondataserviceforapps"
                    operationId    = "BusinessEventsTrigger"
                    apiId          = "/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps"
                }
                parameters = @{
                    catalog                             = $CatalogUniqueName
                    category                             = $CategoryUniqueName
                    "subscriptionRequest/entityname"     = "none"
                    "subscriptionRequest/sdkmessagename" = $eventName
                }
                authentication = "@parameters('`$authentication')"
            }
        }
    }
    actions = @{
        $actionKey = @{
            runAfter = @{}
            type     = "OpenApiConnection"
            inputs   = @{
                host = @{
                    connectionName = "shared_commondataserviceforapps"
                    operationId    = "CreateRecord"
                    apiId          = "/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps"
                }
                parameters = @{
                    entityName                        = $ResultEntitySetName
                    "item/$($PublisherPrefix)_correlationid"          = "@triggerBody()?['InputParameters']?['CorrelationId']"
                    "item/$($PublisherPrefix)_status"                 = "Succeeded"
                    "item/$($PublisherPrefix)_message"                = "Perf-test flow '$flowName' handled correlation @{triggerBody()?['InputParameters']?['CorrelationId']} with input: @{triggerBody()?['InputParameters']?['InputJson']}"
                    "item/$($PublisherPrefix)_messagename"             = $eventName
                    # PERF-TESTING ADDITION vs the original script: a full
                    # sub-second-precision UTC "written at" timestamp, so
                    # Get-PerfTestBreakdown.ps1 can measure true poll-detect
                    # latency instead of being limited by createdon's 1-second
                    # resolution.
                    "item/$($PublisherPrefix)_writtenutc"             = "@utcNow()"
                }
                authentication = "@parameters('`$authentication')"
            }
        }
    }
} | ConvertTo-Json -Depth 20 -Compress

$clientData = @{
    properties = @{
        connectionReferences = @{
            shared_commondataserviceforapps = @{
                runtimeSource = "embedded"
                connection    = @{ name = $ConnectionName }
                api           = @{ name = "shared_commondataserviceforapps" }
            }
        }
        definition    = ($definition | ConvertFrom-Json)
    }
    schemaVersion = "1.0.0.0"
} | ConvertTo-Json -Depth 20 -Compress

Write-Step "Creating flow '$flowName' (trigger: $eventName, connection: $ConnectionName)"
$workflowId = Invoke-Dataverse @dv -Method POST -Path "workflows" -Body @{
    category      = 5
    name          = $flowName
    type          = 1
    description   = "Perf-testing flow for consumer '$Consumer' - writes its result to $ResultEntitySetName, including a precise write timestamp."
    primaryentity = "none"
    clientdata    = $clientData
}
Write-Ok "Created ($workflowId)"

Write-Step "Adding to solution '$SolutionUniqueName'"
Invoke-Dataverse @dv -Method POST -Path "AddSolutionComponent" -Body @{
    ComponentId               = $workflowId
    ComponentType             = 29   # Workflow
    SolutionUniqueName        = $SolutionUniqueName
    AddRequiredComponents     = $false
    DoNotIncludeSubcomponents = $false
} | Out-Null
Write-Ok "Added"

if ($Activate) {
    Write-Step "Activating"
    Invoke-Dataverse @dv -Method PATCH -Path "workflows($workflowId)" -Body @{ statecode = 1; statuscode = 2 } | Out-Null
    Write-Ok "Activated"
}

Write-Host ""
Write-Host "Flow '$flowName' ready ($workflowId)$(if (-not $Activate) { ' - NOT activated, pass -Activate' })." -ForegroundColor Green
