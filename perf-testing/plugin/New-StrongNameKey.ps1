<#
.SYNOPSIS
    Generates perf-testing/plugin/FlowTrigger.Plugins.snk if it doesn't already exist.

.DESCRIPTION
    Verbatim copy of ../../plugin/New-StrongNameKey.ps1 - Dataverse requires plug-in
    assemblies to be strong-name signed, and the key itself isn't security-sensitive
    for this purpose (Dataverse doesn't verify *who* signed it, only that it *is*
    signed), so a separate, independent key for this separate assembly is generated
    the same way. Gitignored, same as the original.
#>
[CmdletBinding()]
param(
    [string] $Path
)

if (-not $Path) {
    # $PSScriptRoot is unreliable inside a param() default for the entry
    # script under Windows PowerShell - resolve it in the body instead.
    $Path = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "FlowTrigger.Plugins.snk"
}

if (Test-Path $Path) {
    Write-Host "Strong name key already exists at $Path"
    return
}

Add-Type -AssemblyName System.Security
$rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new(2048)
try {
    [IO.File]::WriteAllBytes($Path, $rsa.ExportCspBlob($true))
    Write-Host "Generated strong name key at $Path"
}
finally {
    $rsa.Dispose()
}
