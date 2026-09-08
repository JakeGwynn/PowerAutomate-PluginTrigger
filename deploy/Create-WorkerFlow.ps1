<#
.SYNOPSIS
    Creates (and activates) a REAL Power Automate cloud flow for one
    consumer: trigger = Dataverse "When an action is performed" bound to
    <prefix>_OnFlowRequested[_Consumer], action = "Add a new row" writing the
    result to <prefix>_flowresult - completing the actual architecture (not
    a plugin stand-in).

.DESCRIPTION
    Written directly to Dataverse's workflow table via the Web API
    (see https://learn.microsoft.com/power-automate/manage-flows-with-code),
    since this environment's real Power Automate connection (created
    interactively via the portal - see docs/ARCHITECTURE.md for why that one
    step can't be automated) is what the connectionReferences binding needs.

    Requires a connected shared_commondataserviceforapps connection to
    already exist in the target environment - use -ConnectionName to pass
    its name (from `Get-DataverseConnections` in DvHelper.psm1, or
    api.powerapps.com's connections list).

.PARAMETER EventConsumer
    Which consumer's event to bind the trigger to, if different from
    -Consumer. Defaults to -Consumer, which is what every normal
    one-flow-per-consumer deployment wants. Set this only to create a
    second flow that subscribes to an existing consumer's event (e.g. for
    dispatch-latency testing).

.EXAMPLE
    .\Create-WorkerFlow.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com -Consumer Default -ConnectionName shared-commondataser-6c039e04-e309-4700-a8fe-d603aef5290e
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [Parameter(Mandatory)] [string] $Consumer,          # e.g. "TeamC" - "Default" means the unsuffixed event. Also names the flow ("Worker Flow - <Consumer>").
    [Parameter(Mandatory)] [string] $ConnectionName,    # e.g. shared-commondataser-6c039e04-...
    [string] $EventConsumer,                            # optional: which consumer's EVENT to actually bind the trigger to, if different from -Consumer (e.g. to create a SECOND flow subscribed to an EXISTING consumer's event, for fan-out or diagnostic purposes - defaults to $Consumer, preserving normal one-flow-per-consumer behavior)
    [string] $PublisherPrefix     = "flowtrig",      # must match the prefix this environment was deployed with
    [string] $SolutionUniqueName  = "FlowTriggerActionDemo",
    [string] $CatalogUniqueName,                        # defaults to "$($PublisherPrefix)_$SolutionUniqueName" if omitted
    [string] $CategoryUniqueName,                        # defaults to "$($PublisherPrefix)_FlowEvents" if omitted
    [string] $ResultEntitySetName,                       # defaults to "$($PublisherPrefix)_flowresults" if omitted
    [switch] $Activate,
    [switch] $Force   # delete + recreate if a flow with this name already exists
)

$ErrorActionPreference = "Stop"
if (-not $CatalogUniqueName)   { $CatalogUniqueName   = "$($PublisherPrefix)_$SolutionUniqueName" }
if (-not $CategoryUniqueName)  { $CategoryUniqueName  = "$($PublisherPrefix)_FlowEvents" }
if (-not $ResultEntitySetName) { $ResultEntitySetName = "$($PublisherPrefix)_flowresults" }
Import-Module (Join-Path $PSScriptRoot "DvHelper.psm1") -Force

function Write-Step($message) { Write-Host ">> $message" -ForegroundColor Cyan }
function Write-Ok($message)   { Write-Host "   OK: $message" -ForegroundColor Green }

$token = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl
Test-DataverseConnection -EnvironmentUrl $EnvironmentUrl -Token $token | Out-Null
$dv = @{ EnvironmentUrl = $EnvironmentUrl; Token = $token }

if (-not $EventConsumer) { $EventConsumer = $Consumer }
$eventName = if ($EventConsumer -eq "Default") { "$($PublisherPrefix)_OnFlowRequested" } else { "$($PublisherPrefix)_OnFlowRequested_$EventConsumer" }
$flowName  = "Worker Flow - $Consumer"

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
                    "item/$($PublisherPrefix)_message"                = "Real Power Automate flow '$flowName' handled correlation @{triggerBody()?['InputParameters']?['CorrelationId']} with input: @{triggerBody()?['InputParameters']?['InputJson']}"
                    "item/$($PublisherPrefix)_messagename"             = $eventName
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
    description   = "Real Power Automate flow for consumer '$Consumer' - writes its result to $ResultEntitySetName."
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
