<#
.SYNOPSIS
    Shared Dataverse Web API helper functions used by the deployment scripts
    in this folder.

.DESCRIPTION
    Authentication is via Azure CLI (`az account get-access-token`), matching
    the pattern already used for this project (see docs/ARCHITECTURE.md).
    Before running any deploy script, sign in with:

        az login
        az account set --subscription "<the subscription tied to your Dataverse tenant>"

    All functions are intentionally raw-REST (Invoke-WebRequest) rather than a
    Dataverse SDK/CLI wrapper module, so this folder has zero extra module
    dependencies beyond Azure CLI itself. Invoke-WebRequest (not
    Invoke-RestMethod) is used deliberately: response headers and status code
    are plain properties on its return object, avoiding version-sensitive
    parameters like -StatusCodeVariable (PowerShell 7.4+ only).
#>

function Get-DataverseToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl
    )

    $resource = $EnvironmentUrl.TrimEnd('/')
    $token = az account get-access-token --resource $resource --query accessToken -o tsv 2>$null
    if (-not $token) {
        throw "Could not obtain an access token for $resource. Run 'az login' and 'az account set --subscription <sub>' for the tenant that owns this environment, then retry."
    }
    return $token
}

function Test-DataverseConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $Token
    )

    try {
        $whoAmIResponse = Invoke-WebRequest -Method Get -UseBasicParsing `
            -Uri "$($EnvironmentUrl.TrimEnd('/'))/api/data/v9.2/WhoAmI" `
            -Headers (Get-DataverseHeaders -Token $Token)
        return $whoAmIResponse.Content | ConvertFrom-Json
    }
    catch {
        $publicIp = $null
        try { $publicIp = (Invoke-WebRequest -Uri "https://api.ipify.org?format=json" -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json | Select-Object -ExpandProperty ip } catch { }

        $detail = Get-DataverseErrorDetail $_
        if ($detail -match "IP address is blocked" -or $detail -match "Forbidden") {
            throw "Blocked by $EnvironmentUrl's IP firewall$(if ($publicIp) { " (this machine's current public IP is $publicIp)" }). Add this IP to the environment's allow list, or temporarily switch its IP firewall to Audit mode, in Power Platform Admin Center > Environments > <env> > Settings > Privacy + Security > IP firewall, then retry. Original error: $detail"
        }
        throw "Could not connect to $EnvironmentUrl. $detail"
    }
}

function Get-DataverseHeaders {
    param(
        [Parameter(Mandatory)] [string] $Token,
        [string] $SolutionUniqueName,
        [switch] $NoContent
    )

    $headers = @{
        Authorization    = "Bearer $Token"
        Accept           = "application/json"
        "OData-MaxVersion" = "4.0"
        "OData-Version"  = "4.0"
    }
    if (-not $NoContent) {
        $headers["Content-Type"] = "application/json; charset=utf-8"
    }
    if ($SolutionUniqueName) {
        # Auto-adds any record created/updated by this request to the given
        # unmanaged solution - avoids a separate AddSolutionComponent call.
        $headers["MSCRM.SolutionUniqueName"] = $SolutionUniqueName
    }
    return $headers
}

function Get-DataverseErrorDetail {
    param($ErrorRecord)

    try {
        $body = $ErrorRecord.ErrorDetails.Message
        if ($body) {
            $parsed = $body | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.error.message) { return $parsed.error.message }
        }
    } catch { }
    return $ErrorRecord.Exception.Message
}

<#
.SYNOPSIS
    Generic Dataverse Web API call with consistent error surfacing.
.OUTPUTS
    For Create (POST returning 204 with OData-EntityId): the new record's [Guid].
    For GET: the parsed JSON response.
    For PATCH/DELETE: $null.
#>
function Invoke-Dataverse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [ValidateSet("GET", "POST", "PATCH", "PUT", "DELETE")] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,           # e.g. "publishers" or "customapis(...)"
        $Body,
        [string] $SolutionUniqueName,
        [hashtable] $ExtraHeaders
    )

    $uri = "$($EnvironmentUrl.TrimEnd('/'))/api/data/v9.2/$Path"
    $headers = Get-DataverseHeaders -Token $Token -SolutionUniqueName $SolutionUniqueName -NoContent:($Method -eq "GET" -or $Method -eq "DELETE")
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] } }

    # Invoke-WebRequest (not Invoke-RestMethod): response headers and status
    # are plain properties on the returned object (.Headers / .StatusCode),
    # so no -ResponseHeadersVariable/-StatusCodeVariable is needed at all -
    # those are version-sensitive (7.4+ for the latter) and were the source
    # of a "parameter cannot be found" failure on older PowerShell Core
    # builds. .Content is parsed as JSON below to keep this function's
    # return shape identical to before. -UseBasicParsing is required on
    # Windows PowerShell 5.1 - without it, Invoke-WebRequest tries to parse
    # the response through Internet Explorer's DOM engine, which throws
    # "Object reference not set to an instance of an object" on modern
    # Windows builds where IE isn't initialized. It's a harmless no-op on
    # PowerShell 6+ (basic parsing is the only mode there).
    $invokeArgs = @{
        Method         = $Method
        Uri            = $uri
        Headers        = $headers
        UseBasicParsing = $true
    }
    if ($null -ne $Body -and $Method -in @("POST", "PATCH", "PUT")) {
        $invokeArgs["Body"] = ($Body | ConvertTo-Json -Depth 12 -Compress)
    }

    try {
        $response = Invoke-WebRequest @invokeArgs
    }
    catch {
        $detail = Get-DataverseErrorDetail $_
        throw "Dataverse $Method $Path failed: $detail"
    }

    $entityIdHeader = $response.Headers["OData-EntityId"]
    if ($Method -eq "POST" -and $entityIdHeader) {
        $location = $entityIdHeader | Select-Object -First 1
        if ($location -match "\(([0-9a-fA-F\-]{36})\)") {
            return [Guid]$Matches[1]
        }
    }

    if ($response.Content) {
        return $response.Content | ConvertFrom-Json
    }
    return $null
}

<#
.SYNOPSIS
    Finds a single record's id by an OData filter, or $null if none exists.
    Used throughout the deploy script to make every step idempotent.
#>
function Find-DataverseRecordId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [string] $EntitySetName,   # e.g. "publishers"
        [Parameter(Mandatory)] [string] $IdField,         # e.g. "publisherid"
        [Parameter(Mandatory)] [string] $Filter           # OData $filter expression
    )

    $encodedFilter = [Uri]::EscapeDataString($Filter)
    $result = Invoke-Dataverse -EnvironmentUrl $EnvironmentUrl -Token $Token -Method GET `
        -Path "$EntitySetName`?`$select=$IdField&`$filter=$encodedFilter&`$top=1"

    if ($result.value -and $result.value.Count -gt 0) {
        return [Guid]$result.value[0].$IdField
    }
    return $null
}

<#
.SYNOPSIS
    Returns the PrivilegeId for a given AccessRight (e.g. "Read") on a table,
    by reading the table's metadata-expanded Privileges collection - avoids
    guessing the "prv<Right><table>" name string/casing convention by hand.
#>
function Get-EntityPrivilegeId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [string] $EntityLogicalName,
        [string] $AccessRight = "Read"
    )

    $result = Invoke-Dataverse -EnvironmentUrl $EnvironmentUrl -Token $Token -Method GET `
        -Path "EntityDefinitions(LogicalName='$EntityLogicalName')?`$select=LogicalName,Privileges"

    $match = $result.Privileges | Where-Object { $_.PrivilegeType -eq $AccessRight } | Select-Object -First 1
    if (-not $match) {
        throw "Could not find a '$AccessRight' privilege for table '$EntityLogicalName'. It may not have finished provisioning yet - re-run the deploy script."
    }
    return [Guid]$match.PrivilegeId
}

Export-ModuleMember -Function `
    Get-DataverseToken, Test-DataverseConnection, Get-DataverseHeaders, Get-DataverseErrorDetail, `
    Invoke-Dataverse, Find-DataverseRecordId, Get-EntityPrivilegeId
