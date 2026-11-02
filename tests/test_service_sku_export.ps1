param([Parameter(Mandatory = $true)][string]$TestDirectory)
$ErrorActionPreference = 'Stop'
$tenant = '00000000-0000-0000-0000-000000000001'
$subscription = '00000000-0000-0000-0000-000000000010'
$foreign = '00000000-0000-0000-0000-000000000020'
. (Join-Path $PSScriptRoot '..\Export-ServiceSkuInventory.ps1') -TenantId $tenant -OutputDirectory $TestDirectory

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '..\Export-ServiceSkuInventory.ps1'), [ref]$tokens, [ref]$parseErrors)
Assert-Test ($parseErrors.Count -eq 0) 'standalone script syntax'
Assert-Test ($null -ne $ast.GetHelpContent() -and $ast.GetHelpContent().Examples.Count -eq 2) 'portable usage help'

function az { throw 'Real Azure CLI must never be invoked in synthetic tests.' }
function Invoke-SkuAzureCli {
    param([string[]]$Arguments)
    switch ("$($Arguments[0]) $($Arguments[1])") {
        'cloud show' { return [pscustomobject]@{ name = 'AzureCloud' } }
        'account list' {
            return @(
                [pscustomobject]@{ id = $subscription; name = 'Synthetic'; tenantId = $tenant; state = 'Enabled' },
                [pscustomobject]@{ id = $foreign; name = 'Foreign'; tenantId = $foreign; state = 'Enabled' },
                [pscustomobject]@{ id = $tenant; name = 'Disabled'; tenantId = $tenant; state = 'Disabled' }
            )
        }
        'account get-access-token' {
            Assert-Test ($Arguments[3] -eq $subscription) 'token scope'
            return [pscustomobject]@{ tenant = $tenant; accessToken = 'SYNTHETIC_TOKEN_NOT_FOR_EXPORT' }
        }
        default { throw "Unexpected CLI operation in test: $Arguments" }
    }
}

$script:Requests = [System.Collections.Generic.List[object]]::new()
$script:Resources = @{}
$prefix = "/subscriptions/$subscription/resourceGroups/synthetic/providers"
function Add-TestResource {
    param([string]$Type, [string]$Name, $Sku, $Properties, [string]$Kind = '')
    $provider, $resourceType = $Type.Split('/', 2)
    $id = "$prefix/$provider/$resourceType/$Name"
    $resource = @{
        id = $id; name = $Name; type = $Type; location = 'switzerlandnorth'; kind = $Kind
        sku = $Sku; properties = $Properties; zones = @('1')
    } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $script:Resources[$id] = $resource
    return $id
}

$storage = Add-TestResource 'Microsoft.Storage/storageAccounts' 'syntheticstorage' `
    @{ name = 'Standard_ZRS'; tier = 'Standard'; apiKey = 'SKU_SECRET_SENTINEL' } `
    @{ accessTier = 'Cool'; isHnsEnabled = $true; isNfsV3Enabled = $false; accountKey = 'STORAGE_SECRET_SENTINEL' } 'StorageV2'
$app = Add-TestResource 'Microsoft.Web/serverfarms' 'syntheticplan' `
    @{ name = 'P0v3'; tier = 'PremiumV3'; capacity = 2 } @{ reserved = $true; zoneRedundant = $false }
$workspace = Add-TestResource 'Microsoft.OperationalInsights/workspaces' 'syntheticlogs' $null `
    @{ sku = @{ name = 'CapacityReservation'; capacityReservationLevel = 100 }; retentionInDays = 30 }
$aks = Add-TestResource 'Microsoft.ContainerService/managedClusters' 'syntheticaks' `
    @{ name = 'Base'; tier = 'Standard' } @{
        kubernetesVersion = '1.30'
        agentPoolProfiles = @(@{ name = 'pool'; vmSize = 'Standard_D4s_v5'; osSKU = 'Ubuntu'; osType = 'Linux'; count = 2; secret = 'POOL_SECRET_SENTINEL' })
        servicePrincipalProfile = @{ secret = 'AKS_SECRET_SENTINEL' }
    }
$databricks = Add-TestResource 'Microsoft.Databricks/workspaces' 'syntheticdbx' `
    @{ name = 'premium' } @{ workspaceUrl = 'synthetic.azuredatabricks.net'; parameters = @{ secret = 'DBX_SECRET_SENTINEL' } }
$sql = Add-TestResource 'Microsoft.Sql/servers/databases' 'syntheticserver/syntheticdb' `
    @{ name = 'GP_Gen5'; tier = 'GeneralPurpose'; family = 'Gen5'; capacity = 2 } `
    @{ licenseType = 'BasePrice'; minCapacity = 1; autoPauseDelay = -1; zoneRedundant = $true }
$firewall = Add-TestResource 'Microsoft.Network/azureFirewalls' 'syntheticfirewall' $null `
    @{ sku = @{ name = 'AZFW_VNet'; tier = 'Standard' } }
$apim = Add-TestResource 'Microsoft.ApiManagement/service' 'syntheticapim' `
    @{ name = 'Premium'; capacity = 2 } @{
        virtualNetworkType = 'Internal'
        additionalLocations = @(@{ location = 'francecentral'; sku = @{ name = 'Premium'; capacity = 1 }; zones = @('1'); secret = 'APIM_LOCATION_SECRET_SENTINEL' })
        hostnameConfigurations = @(@{ encodedCertificate = 'APIM_CERT_SECRET_SENTINEL' })
    }
$vnet = Add-TestResource 'Microsoft.Network/virtualNetworks' 'syntheticvnet' $null @{}
$pool = Add-TestResource 'Microsoft.Sql/servers/elasticPools' 'syntheticserver/syntheticpool' `
    @{ name = 'GP_Gen5'; tier = 'GeneralPurpose'; family = 'Gen5'; capacity = 4 } `
    @{ perDatabaseSettings = @{ minCapacity = 0.5; maxCapacity = 2 }; zoneRedundant = $true }
$nat = Add-TestResource 'Microsoft.Network/natGateways' 'syntheticnat' `
    @{ name = 'Standard' } @{ idleTimeoutInMinutes = 4 }
$private = Add-TestResource 'Microsoft.Network/privateEndpoints' 'syntheticprivate' $null @{
    privateLinkServiceConnections = @(@{
        properties = @{ privateLinkServiceId = $storage; groupIds = @('blob'); secret = 'CONNECTION_SECRET_SENTINEL' }
    })
}
$cluster = Add-TestResource 'Microsoft.OperationalInsights/clusters' 'syntheticcluster' `
    @{ name = 'CapacityReservation'; capacity = 500 } @{}

function Invoke-RestMethod {
    param([uri]$Uri, [string]$Method, $Headers, $ContentType, $TimeoutSec, $MaximumRedirection, $ErrorAction, $Body)
    Assert-Test ($MaximumRedirection -eq 0) 'HTTP redirects disabled'
    Assert-Test ($Headers.Authorization -eq 'Bearer SYNTHETIC_TOKEN_NOT_FOR_EXPORT') 'token used only in request'
    $script:Requests.Add([pscustomobject]@{ uri = $Uri.AbsoluteUri; method = $Method })
    if ($Method -eq 'POST') {
        Assert-Test ($Uri.AbsolutePath -eq '/providers/Microsoft.ResourceGraph/resources') 'POST limited to Resource Graph'
        $request = $Body | ConvertFrom-Json
        Assert-Test (@($request.subscriptions).Count -eq 1 -and $request.subscriptions[0] -eq $subscription) 'tenant discovery scope'
        Assert-Test ($request.query -notmatch 'project.*properties') 'discovery does not request broad properties'
        if ($script:FailureMode -eq 'Discovery') { throw [System.Net.WebException]::new('Synthetic discovery failure') }
        if ($request.options.'$skipToken') {
            return [pscustomobject]@{
                data = @([pscustomobject]@{ id = $storage; type = 'Microsoft.Storage/storageAccounts' })
                resultTruncated = 'false'
            }
        }
        return [pscustomobject]@{
            data = @($script:Resources.Values | Select-Object id, type)
            '$skipToken' = 'page-two'; resultTruncated = 'true'
        }
    }
    Assert-Test ($Method -eq 'GET') 'all non-Graph requests are GET'
    $path = $Uri.AbsolutePath
    if ($script:FailureMode -eq 'Storage' -and $path -eq $storage) {
        throw [System.Net.WebException]::new('Synthetic resource failure')
    }
    if ($path -eq "$workspace/tables") {
        $tableName = 'SyntheticAnalytics'
        $plan = 'Analytics'
        $next = "https://management.azure.com$workspace/tables?api-version=2022-10-01&skip=second"
        if ($Uri.Query -match 'skip=second') { $tableName = 'SyntheticBasic'; $plan = 'Basic'; $next = $null }
        return [pscustomobject]@{
            value = @([pscustomobject]@{
                id = "$workspace/tables/$tableName"; name = $tableName
                type = 'Microsoft.OperationalInsights/workspaces/tables'
                properties = [pscustomobject]@{ plan = $plan; retentionInDays = 30; schema = 'TABLE_SCHEMA_SENTINEL' }
            })
            nextLink = $next
        }
    }
    if ($path -eq "$vnet/virtualNetworkPeerings") {
        return [pscustomobject]@{ value = @([pscustomobject]@{
            id = "$vnet/virtualNetworkPeerings/syntheticpeer"; name = 'syntheticpeer'
            type = 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings'
            properties = [pscustomobject]@{
                remoteVirtualNetwork = [pscustomobject]@{ id = "$prefix/Microsoft.Network/virtualNetworks/remote" }
                peeringState = 'Connected'
            }
        }) }
    }
    if ($script:Resources.ContainsKey($path)) { return $script:Resources[$path] }
    throw "Unexpected synthetic HTTP request: $Uri"
}

foreach ($invalid in @(
    @{ Uri = 'https://untrusted.invalid/resources'; Method = 'GET' },
    @{ Uri = "https://management.azure.com/subscriptions/$foreign/resourceGroups/test/resources"; Method = 'GET' },
    @{ Uri = "https://management.azure.com$storage"; Method = 'POST' },
    @{ Uri = "https://management.azure.com$storage"; Method = 'DELETE' }
)) {
    $rejected = $false
    try { Assert-SkuArmUri ([uri]$invalid.Uri) $subscription $invalid.Method }
    catch [System.Management.Automation.RuntimeException] { $rejected = $true }
    Assert-Test $rejected 'unsafe request rejected'
}

$ranking = Join-Path $TestDirectory 'synthetic-ranking.csv'
@'
category,rank,serviceLevel2,serviceLevel4,sku
Non-VM,1,Storage,Blob,Cool
Non-VM,2,GitHub,Copilot,Business
Non-VM,3,Synthetic unmapped,Product,Tier
Non-VM,21,Storage,Blob,Hot
VM,1,Virtual Machines,Family,D4s v5
'@ | Set-Content -LiteralPath $ranking -Encoding UTF8

$script:FailureMode = ''
$output = Join-Path $TestDirectory 'complete'
Export-ServiceSkuInventory -Tenant $tenant -Output $output -Ranking $ranking
$jsonText = Get-Content -LiteralPath (Join-Path $output 'service-sku-inventory.json') -Raw
$result = $jsonText | ConvertFrom-Json
Assert-Test ($result.status -eq 'Collected') 'successful collection status'
Assert-Test (@($result.subscriptions).Count -eq 1) 'foreign and disabled subscriptions excluded'
Assert-Test (@($result.resources).Count -eq 16) 'parent and paginated child inventory'
Assert-Test (@($result.requirements).Count -eq 3) 'only top-20 non-VM requirements retained'
Assert-Test (@($result.requirements[0].candidateResourceIds).Count -eq 1) 'deduplicated resource candidates'
Assert-Test ($result.requirements[1].status -like 'Not regional*') 'non-regional billing identified'
Assert-Test ($result.requirements[2].status -like 'No extractor mapping*') 'unmapped product explicit'
Assert-Test ($result.failures.Count -eq 0) 'no hidden failures'
Assert-Test ($jsonText -notmatch 'SENTINEL|SYNTHETIC_TOKEN|TABLE_SCHEMA') 'secrets and non-allowlisted fields excluded'
$records = @{}
foreach ($resource in $result.resources) { $records[$resource.id] = $resource }
Assert-Test ($records[$storage].sku.name -eq 'Standard_ZRS') 'storage deployment SKU'
Assert-Test ($records[$storage].configuration.accessTier -eq 'Cool') 'storage access tier'
Assert-Test ($records[$storage].configuration.isHnsEnabled -eq $true) 'hierarchical namespace'
Assert-Test ($records[$app].configuration.reserved -eq $true) 'Linux App Service plan'
Assert-Test ($records[$workspace].sku.capacityReservationLevel -eq 100) 'workspace commitment tier'
Assert-Test ($records[$aks].configuration.nodePools[0].vmSize -eq 'Standard_D4s_v5') 'AKS node size'
Assert-Test ($records[$databricks].sku.name -eq 'premium') 'Databricks workspace tier'
Assert-Test ($records[$sql].sku.family -eq 'Gen5') 'SQL hardware family'
Assert-Test ($records[$firewall].sku.tier -eq 'Standard') 'Firewall nested SKU'
Assert-Test ($records[$apim].configuration.additionalLocations[0].sku.name -eq 'Premium') 'APIM secondary location SKU'
Assert-Test ($records[$pool].configuration.'perDatabaseSettings.maxCapacity' -eq 2) 'SQL elastic pool per-database capacity'
Assert-Test ($records[$nat].sku.name -eq 'Standard') 'NAT Gateway SKU'
Assert-Test ($records[$private].configuration.connections[0].groupIds[0] -eq 'blob') 'Private Link target group'
Assert-Test ($records[$cluster].sku.capacity -eq 500) 'dedicated log cluster commitment'
Assert-Test (@($result.resources | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/tables' }).Count -eq 2) 'Log Analytics table plans paginated'
Assert-Test (@(Import-Csv -LiteralPath (Join-Path $output 'service-sku-inventory.csv')).Count -eq 16) 'CSV inventory complete'
Assert-Test (@($script:Requests | Where-Object { $_.method -eq 'GET' -and ([uri]$_.uri).AbsolutePath -eq $storage }).Count -eq 1) 'duplicate discovery row not queried twice'
Assert-Test ($script:SkuTokenCache.Count -eq 0) 'token cache cleared after export'

$scopeRejected = $false
try { Export-ServiceSkuInventory -Tenant $tenant -Output (Join-Path $TestDirectory 'wrong') -Subscriptions @([guid]$foreign) }
catch [System.Management.Automation.RuntimeException] { $scopeRejected = $true }
Assert-Test $scopeRejected 'foreign subscription selection fails before discovery'
Assert-Test (-not (Test-Path (Join-Path $TestDirectory 'wrong'))) 'no output on invalid tenant scope'

foreach ($mode in @('Storage', 'Discovery')) {
    $script:FailureMode = $mode
    $partial = Join-Path $TestDirectory $mode
    $failed = $false
    try { Export-ServiceSkuInventory -Tenant $tenant -Output $partial -Subscriptions @([guid]$subscription) }
    catch [System.Management.Automation.RuntimeException] { $failed = $true }
    Assert-Test $failed 'partial collection returns a failure'
    $document = Get-Content -LiteralPath (Join-Path $partial 'service-sku-inventory.json') -Raw | ConvertFrom-Json
    Assert-Test ($document.status -eq 'Partial') 'failure persisted as partial'
    Assert-Test ($document.failures.Count -eq 1) 'failed request recorded once'
    Assert-Test (Test-Path (Join-Path $partial 'service-sku-inventory.csv')) 'CSV exists for partial/empty collection'
}
Write-Output 'Synthetic service SKU exporter checks passed.'
