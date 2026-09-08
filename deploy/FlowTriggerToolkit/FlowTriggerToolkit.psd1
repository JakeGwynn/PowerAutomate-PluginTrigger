@{
    RootModule        = 'FlowTriggerToolkit.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b6e2f2a0-6c2b-4a9a-9c1a-3f2e7d9a4c11'
    Author            = 'Flow Trigger Toolkit contributors'
    Description       = 'Provision, operate, and govern the synchronous Dataverse flow-trigger pattern (Custom API + business event + polling plug-in) in any Power Platform tenant. See README.md in this folder for the full quick-start workflow.'
    # Windows PowerShell 5.1 is the floor - every function in this module is written to
    # run unchanged on both Windows PowerShell 5.1 (.NET Framework) and PowerShell 7+
    # (.NET / .NET Core) - no version-specific cmdlets/operators/types are used.
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'New-FlowTriggerEnvironment',
        'Install-FlowTriggerSolution',
        'Get-FlowTriggerConsumer',
        'Add-FlowTriggerConsumer',
        'New-FlowTriggerWorkerFlow',
        'Grant-FlowTriggerCallerAccess',
        'Revoke-FlowTriggerCallerAccess',
        'New-FlowTriggerRestrictedMakerRole',
        'Grant-FlowTriggerMakerVisibility',
        'Revoke-FlowTriggerMakerVisibility',
        'Test-FlowTriggerConsumer',
        'Get-FlowTriggerLoadTestPhaseBreakdown',
        'Enable-FlowTriggerAuditing',
        'Get-FlowTriggerAuditLog',
        'Get-FlowTriggerAccessReport',
        'Get-FlowTriggerDeploymentStatus'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Dataverse', 'PowerAutomate', 'PowerPlatform', 'Governance')
            ProjectUri = 'https://github.com/JakeGwynn/PowerAutomate-PluginTrigger'
        }
    }
}
