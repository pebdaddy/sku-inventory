#Requires -Version 5.1

<#
.SYNOPSIS
Exports read-only non-VM service SKU/configuration metadata from a specified Azure tenant.
.DESCRIPTION
Run in Windows PowerShell 5.1 after az login --tenant <tenant GUID>.
Reader access on the selected subscriptions is recommended. Uses Azure CLI authentication,
read-only Resource Graph queries and ARM GET requests; no deployments or provider registration.
Exports allowlisted fields to service-sku-inventory.json and service-sku-inventory.csv.
Optional RankingCsv adds top-20 non-VM billing entries and candidate resource IDs for review.
This is current configuration, not historical billing attribution or regional SKU verification.
Databricks compute and GitHub billing require separate evidence. Tokens and keys are not exported.
.EXAMPLE
.\Export-ServiceSkuInventory.ps1 -TenantId '<tenant GUID>' -OutputDirectory '.\sku-inventory'
.EXAMPLE
.\Export-ServiceSkuInventory.ps1 -TenantId '<tenant GUID>' -SubscriptionId @('<subscription GUID>') -OutputDirectory '.\sku-inventory' -RankingCsv '.\sku-ranking.csv'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [guid]$TenantId,
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,
    [guid[]]$SubscriptionId,
    [string]$RankingCsv
)

$ErrorActionPreference = 'Stop'

function Get-SkuField {
    param($Object, [string]$Path)
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $Object) { return $null }
        $property = $Object.PSObject.Properties[$part]
        if ($null -eq $property) { return $null }
        $Object = $property.Value
    }
    return ,$Object
}

function Select-SkuFields {
    param($Object, [string[]]$Fields)
    $result = [ordered]@{}
    foreach ($field in $Fields) {
        $result[$field] = Get-SkuField $Object $field
    }
    return [pscustomobject]$result
}

function Invoke-SkuAzureCli {
    param([string[]]$Arguments)
    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed for '$($Arguments[0]) $($Arguments[1])'. Sign in to the intended tenant first."
    }
    return ($result -join "`n" | ConvertFrom-Json)
}

function Assert-SkuArmUri {
    param([uri]$Uri, [string]$Subscription, [string]$Method)
    if ($Uri.Scheme -ne 'https' -or $Uri.Host -ne 'management.azure.com' -or
        $Uri.Port -ne 443 -or $Uri.UserInfo -or $Uri.Fragment) {
        throw "Refusing a request outside the public Azure ARM endpoint."
    }
    if ($Method -eq 'POST') {
        if ($Uri.AbsolutePath -ne '/providers/Microsoft.ResourceGraph/resources') {
            throw "POST is allowed only for read-only Resource Graph queries."
        }
    }
    elseif ($Method -ne 'GET' -or
        -not $Uri.AbsolutePath.StartsWith("/subscriptions/$Subscription/resourceGroups/", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing a request outside the selected subscription resource scope."
    }
}

function Invoke-SkuArmRequest {
    param([uri]$Uri, [string]$Subscription, [ValidateSet('GET', 'POST')][string]$Method = 'GET', $Body)
    Assert-SkuArmUri $Uri $Subscription $Method
    $cached = $script:SkuTokenCache[$Subscription]
    if ($null -eq $cached -or $cached.RefreshAt -le [datetime]::UtcNow) {
        $token = Invoke-SkuAzureCli @('account', 'get-access-token', '--subscription', $Subscription,
            '--resource', 'https://management.azure.com/')
        if ([string]$token.tenant -ne $script:SkuTenant -or -not $token.accessToken) {
            throw "Azure CLI returned a token outside the requested tenant or without an access token."
        }
        $cached = @{ AccessToken = $token.accessToken; RefreshAt = [datetime]::UtcNow.AddMinutes(20) }
        $script:SkuTokenCache[$Subscription] = $cached
    }
    $parameters = @{
        Uri = $Uri
        Method = $Method
        Headers = @{ Authorization = "Bearer $($cached.AccessToken)" }
        ContentType = 'application/json'
        TimeoutSec = 120
        MaximumRedirection = 0
        ErrorAction = 'Stop'
    }
    if ($Method -eq 'POST') { $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $data = Invoke-RestMethod @parameters
            return [pscustomobject]@{ Success = $true; Data = $data; Error = $null }
        }
        catch [System.Net.WebException] {
            $status = 0
            if ($null -ne $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -in @(429, 503) -and $attempt -lt 2) {
                Write-Warning "ARM returned HTTP $status; retrying the metadata request."
                Start-Sleep -Seconds (5 * ($attempt + 1))
                continue
            }
            return [pscustomobject]@{
                Success = $false
                Data = $null
                Error = "ARM metadata request failed (HTTP $status; 0 means connection/timeout failure)."
            }
        }
    }
}

function Get-ServiceSkuDefinitions {
    return @{
        'microsoft.storage/storageaccounts' = @{
            Api = '2023-05-01'; Services = @('Storage')
            Fields = @('accessTier', 'isHnsEnabled', 'isNfsV3Enabled', 'largeFileSharesState')
        }
        'microsoft.web/serverfarms' = @{
            Api = '2023-12-01'; Services = @('Azure App Service')
            Fields = @('reserved', 'hyperV', 'zoneRedundant', 'hostingEnvironmentProfile.id', 'isXenon')
        }
        'microsoft.sql/servers/databases' = @{
            Api = '2023-08-01'; Services = @('SQL Database')
            Fields = @('currentServiceObjectiveName', 'requestedServiceObjectiveName', 'elasticPoolId',
                'licenseType', 'computeModel', 'minCapacity', 'autoPauseDelay', 'maxSizeBytes',
                'zoneRedundant', 'readScale', 'currentBackupStorageRedundancy', 'availabilityZone')
        }
        'microsoft.sql/servers/elasticpools' = @{
            Api = '2023-08-01'; Services = @('SQL Database')
            Fields = @('perDatabaseSettings.minCapacity', 'perDatabaseSettings.maxCapacity',
                'licenseType', 'zoneRedundant', 'maxSizeBytes')
        }
        'microsoft.operationalinsights/workspaces' = @{
            Api = '2023-09-01'; Services = @('Azure Monitor', 'Log Analytics')
            Fields = @('retentionInDays', 'features.enableDataExport', 'defaultDataCollectionRuleResourceId')
            PropertySku = $true; Child = 'tables'; ChildApi = '2022-10-01'
        }
        'microsoft.operationalinsights/clusters' = @{
            Api = '2022-10-01'; Services = @('Azure Monitor', 'Log Analytics'); Fields = @()
        }
        'microsoft.databricks/workspaces' = @{
            Api = '2024-05-01'; Services = @('Azure Databricks')
            Fields = @('workspaceUrl', 'isUcEnabled')
        }
        'microsoft.containerservice/managedclusters' = @{
            Api = '2024-05-01'; Services = @('Azure Kubernetes Service')
            Fields = @('kubernetesVersion', 'networkProfile.networkPlugin', 'networkProfile.networkPluginMode',
                'networkProfile.networkPolicy', 'networkProfile.loadBalancerSku')
        }
        'microsoft.network/azurefirewalls' = @{
            Api = '2024-05-01'; Services = @('Azure Firewall'); Fields = @('firewallPolicy.id'); PropertySku = $true
        }
        'microsoft.network/natgateways' = @{
            Api = '2024-05-01'; Services = @('NAT Gateway'); Fields = @('idleTimeoutInMinutes')
        }
        'microsoft.network/privateendpoints' = @{
            Api = '2024-05-01'; Services = @('Virtual Network'); Fields = @()
        }
        'microsoft.network/virtualnetworks' = @{
            Api = '2024-05-01'; Services = @('Virtual Network'); Fields = @()
            Child = 'virtualNetworkPeerings'; ChildApi = '2024-05-01'
        }
        'microsoft.apimanagement/service' = @{
            Api = '2024-05-01'; Services = @('API Management')
            Fields = @('platformVersion', 'virtualNetworkType', 'natGatewayState')
        }
    }
}

function ConvertTo-ServiceSkuRecord {
    param($Resource, $Definition, [string]$SubscriptionName, [string]$ParentId = '')
    $sku = Get-SkuField $Resource 'sku'
    if ($Definition.PropertySku) { $sku = Get-SkuField $Resource 'properties.sku' }
    $configuration = Select-SkuFields (Get-SkuField $Resource 'properties') $Definition.Fields
    $type = ([string]$Resource.type).ToLowerInvariant()
    if ($type -eq 'microsoft.containerservice/managedclusters') {
        $pools = @(foreach ($pool in (Get-SkuField $Resource 'properties.agentPoolProfiles')) {
            if ($null -ne $pool) {
                Select-SkuFields $pool @('name', 'vmSize', 'osType', 'osSKU', 'mode', 'count',
                    'enableAutoScaling', 'minCount', 'maxCount', 'availabilityZones', 'type')
            }
        })
        $configuration | Add-Member -NotePropertyName nodePools -NotePropertyValue $pools
    }
    if ($type -eq 'microsoft.apimanagement/service') {
        $locations = @(foreach ($location in (Get-SkuField $Resource 'properties.additionalLocations')) {
            if ($null -ne $location) {
                [pscustomobject]@{
                    location = Get-SkuField $location 'location'
                    zones = Get-SkuField $location 'zones'
                    sku = Select-SkuFields (Get-SkuField $location 'sku') @('name', 'tier', 'capacity', 'family', 'size')
                }
            }
        })
        $configuration | Add-Member -NotePropertyName additionalLocations -NotePropertyValue $locations
    }
    if ($type -eq 'microsoft.network/privateendpoints') {
        $connections = @(foreach ($field in @('privateLinkServiceConnections', 'manualPrivateLinkServiceConnections')) {
            foreach ($connection in (Get-SkuField $Resource "properties.$field")) {
                if ($null -ne $connection) {
                    Select-SkuFields (Get-SkuField $connection 'properties') @('privateLinkServiceId', 'groupIds')
                }
            }
        })
        $configuration | Add-Member -NotePropertyName connections -NotePropertyValue $connections
    }
    $id = [string]$Resource.id
    if (-not $id -or -not $Resource.type) { throw "ARM returned resource metadata without an ID or type." }
    return [pscustomobject]@{
        id = $id
        name = $Resource.name
        type = $Resource.type
        subscriptionId = $id.Split('/')[2]
        subscriptionName = $SubscriptionName
        resourceGroup = $id.Split('/')[4]
        location = Get-SkuField $Resource 'location'
        kind = Get-SkuField $Resource 'kind'
        zones = Get-SkuField $Resource 'zones'
        sku = Select-SkuFields $sku @('name', 'tier', 'family', 'capacity', 'size', 'capacityReservationLevel')
        configuration = $configuration
        parentResourceId = $ParentId
        collectedAt = [datetime]::UtcNow.ToString('o')
    }
}

function Export-ServiceSkuInventory {
    param([guid]$Tenant, [string]$Output, [guid[]]$Subscriptions, [string]$Ranking)
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI is required. Install it and run az login first." }
    $cloud = Invoke-SkuAzureCli @('cloud', 'show')
    if ($cloud.name -ne 'AzureCloud') { throw "This exporter supports public Azure only." }
    $accounts = @(Invoke-SkuAzureCli @('account', 'list', '--all'))
    $selected = @($accounts | Where-Object { $_.tenantId -eq $Tenant.ToString() -and $_.state -eq 'Enabled' })
    if ($Subscriptions) {
        $requested = @($Subscriptions | ForEach-Object { $_.ToString() } | Sort-Object -Unique)
        foreach ($id in $requested) {
            if (-not ($selected | Where-Object { $_.id -eq $id })) {
                throw "Requested subscription '$id' is not an enabled, accessible subscription in tenant '$Tenant'."
            }
        }
        $selected = @($selected | Where-Object { $_.id -in $requested })
    }
    if (-not $selected) { throw "No enabled subscriptions for tenant '$Tenant' are visible in Azure CLI. Sign in to that tenant first." }
    $rankings = @()
    if ($Ranking) {
        $rankings = @(Import-Csv -LiteralPath $Ranking)
        $required = @('category', 'rank', 'serviceLevel2', 'serviceLevel4', 'sku')
        if (-not $rankings -or @($required | Where-Object { $_ -notin $rankings[0].PSObject.Properties.Name })) {
            throw "Ranking CSV must contain category, rank, serviceLevel2, serviceLevel4 and sku columns."
        }
        $rankings = @($rankings | Where-Object { $_.category -eq 'Non-VM' -and [int]$_.rank -ge 1 -and [int]$_.rank -le 20 })
        if (-not $rankings) { throw "Ranking CSV contains no top-20 non-VM entries." }
    }
    $script:SkuTenant = $Tenant.ToString()
    $script:SkuTokenCache = @{}
    $definitions = Get-ServiceSkuDefinitions
    $resources = [System.Collections.Generic.List[object]]::new()
    $failures = [System.Collections.Generic.List[object]]::new()
    $seenResources = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $types = ($definitions.Keys | Sort-Object | ForEach-Object { "'$_'" }) -join ','
    $query = "Resources | where type in~ ($types) | project id, type | order by id asc"
    $started = [datetime]::UtcNow.ToString('o')

    foreach ($account in $selected) {
        Write-Host "Reading service configurations in subscription '$($account.name)' ($($account.id))."
        $skip = $null
        $seenPages = [System.Collections.Generic.HashSet[string]]::new()
        do {
            $options = @{ '$top' = 1000; resultFormat = 'objectArray' }
            if ($skip) { $options['$skipToken'] = $skip }
            $body = @{ subscriptions = @($account.id); query = $query; options = $options }
            $page = Invoke-SkuArmRequest -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' `
                -Subscription $account.id -Method POST -Body $body
            if (-not $page.Success) {
                $failures.Add([pscustomobject]@{ scope = $account.id; operation = 'Resource Graph discovery'; error = $page.Error })
                Write-Warning "Resource discovery failed for '$($account.id)': $($page.Error)"
                break
            }
            if ($null -eq $page.Data.PSObject.Properties['data']) { throw "Resource Graph returned no data property." }
            foreach ($item in $page.Data.data) {
                $id = [string]$item.id
                $definition = $definitions[([string]$item.type).ToLowerInvariant()]
                if (-not $definition -or -not $id) { throw "Unexpected resource type or missing ID in Resource Graph response." }
                if (-not $seenResources.Add($id)) { continue }
                $response = Invoke-SkuArmRequest -Uri "https://management.azure.com${id}?api-version=$($definition.Api)" -Subscription $account.id
                if (-not $response.Success) {
                    $failures.Add([pscustomobject]@{ scope = $id; operation = 'Resource configuration'; error = $response.Error })
                    Write-Warning "Resource metadata failed for '${id}': $($response.Error)"
                    continue
                }
                $resource = ConvertTo-ServiceSkuRecord $response.Data $definition $account.name
                if ($resource.id -ne $id -or $resource.type -ne $item.type) { throw "ARM returned metadata for a different resource." }
                $resources.Add($resource)
                if ($definition.Child) {
                    $next = "https://management.azure.com${id}/$($definition.Child)?api-version=$($definition.ChildApi)"
                    $childPages = [System.Collections.Generic.HashSet[string]]::new()
                    do {
                        if (-not $childPages.Add($next)) { throw "Repeated child-resource pagination URL." }
                        $children = Invoke-SkuArmRequest -Uri $next -Subscription $account.id
                        if (-not $children.Success) {
                            $failures.Add([pscustomobject]@{ scope = $id; operation = $definition.Child; error = $children.Error })
                            Write-Warning "Child metadata failed for '${id}': $($children.Error)"
                            break
                        }
                        if ($null -eq $children.Data.PSObject.Properties['value']) { throw "Child-resource response has no value array." }
                        foreach ($child in $children.Data.value) {
                            $childDefinition = @{ Fields = @('plan', 'retentionInDays', 'totalRetentionInDays') }
                            if ($definition.Child -eq 'virtualNetworkPeerings') {
                                $childDefinition.Fields = @('remoteVirtualNetwork.id', 'peeringState')
                            }
                            if (-not ([string]$child.id).StartsWith("$id/", [StringComparison]::OrdinalIgnoreCase)) {
                                throw "Child-resource response points outside its parent."
                            }
                            if ($seenResources.Add([string]$child.id)) {
                                $resources.Add((ConvertTo-ServiceSkuRecord $child $childDefinition $account.name $id))
                            }
                        }
                        $next = [string]$children.Data.nextLink
                    } while ($next)
                }
            }
            $skip = [string]$page.Data.'$skipToken'
            if ($skip -and -not $seenPages.Add($skip)) { throw "Repeated Resource Graph continuation token." }
            if (-not $skip -and [string]$page.Data.resultTruncated -eq 'true') {
                throw "Resource Graph results are truncated without a continuation token."
            }
        } while ($skip)
    }

    $coverage = @(foreach ($row in $rankings) {
        $matchingTypes = @($definitions.Keys | Where-Object { $row.serviceLevel2 -in $definitions[$_].Services })
        $candidates = @($resources | Where-Object { ([string]$_.type).ToLowerInvariant() -in $matchingTypes })
        $status = 'Resource candidates; billing-to-resource match requires review'
        if ($row.serviceLevel2 -in @('GitHub', 'Bandwidth', 'Virtual Machines Licenses')) {
            $status = 'Not regional; no Azure deployment SKU to extract'
        }
        elseif (-not $matchingTypes) { $status = 'No extractor mapping; manual review required' }
        elseif (-not $candidates) { $status = 'No matching resources collected; check scope, permissions and historical usage' }
        [pscustomobject]@{
            rank = [int]$row.rank; service = $row.serviceLevel2; product = $row.serviceLevel4
            billedSku = $row.sku; status = $status
            candidateResourceIds = @($candidates | ForEach-Object { $_.id })
        }
    })
    $limitations = @(
        'Inventory is current configuration, not a reconstruction of historical ACR usage or a target-region availability check.',
        'Only enabled subscriptions visible to this Azure CLI identity in the requested tenant are included; tenant-wide completeness is not guaranteed.',
        'Reader access at each selected subscription is recommended. Resource-scoped access can produce an incomplete discovery set.',
        'Resource candidates are not automatic billing-to-resource matches. Review all configurations contributing to each billing entry.',
        'Databricks cluster/job/pool node types, SQL warehouse sizes and serverless settings require separate workspace API access; ARM exports only workspace tier.',
        'Storage accessTier is the account default. Per-blob tier overrides and object data are not read.',
        'GitHub Copilot plans/AI credits require GitHub billing/admin evidence and are not regional Azure deployment SKUs.',
        'Quota, customer eligibility, feature combinations and real-time target-region capacity still require separate validation.'
    )
    $document = [ordered]@{
        schemaVersion = 1; tenantId = $Tenant.ToString(); startedAt = $started
        collectedAt = [datetime]::UtcNow.ToString('o')
        status = $(if ($failures.Count) { 'Partial' } else { 'Collected' })
        subscriptions = @($selected | Select-Object id, name, tenantId)
        resources = @($resources.ToArray()); requirements = $coverage
        failures = @($failures.ToArray()); limitations = $limitations
    }
    $directory = New-Item -ItemType Directory -Path $Output -Force
    $jsonPath = Join-Path $directory.FullName 'service-sku-inventory.json'
    $csvPath = Join-Path $directory.FullName 'service-sku-inventory.csv'
    $document | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    $csv = @($resources | ForEach-Object {
        [pscustomobject]@{
            subscriptionId = $_.subscriptionId; subscriptionName = $_.subscriptionName
            resourceGroup = $_.resourceGroup; id = $_.id; type = $_.type; name = $_.name
            location = $_.location; kind = $_.kind; skuName = $_.sku.name; skuTier = $_.sku.tier
            skuFamily = $_.sku.family; skuCapacity = $_.sku.capacity
            capacityReservationLevel = $_.sku.capacityReservationLevel
            zones = @($_.zones) -join ';'; parentResourceId = $_.parentResourceId
            configurationJson = $_.configuration | ConvertTo-Json -Depth 20 -Compress
        }
    })
    if ($csv.Count) { $csv | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 }
    else {
        '"subscriptionId","subscriptionName","resourceGroup","id","type","name","location","kind","skuName","skuTier","skuFamily","skuCapacity","capacityReservationLevel","zones","parentResourceId","configurationJson"' |
            Set-Content -LiteralPath $csvPath -Encoding UTF8
    }
    $script:SkuTokenCache.Clear()
    Write-Host "Saved $($resources.Count) resource configurations and $($coverage.Count) ranking requirements to '$($directory.FullName)'."
    if ($failures.Count) { throw "Export is PARTIAL: $($failures.Count) requests failed. Review failures in '$jsonPath'." }
    if (-not $resources.Count) { Write-Warning "No matching resources were found. Review subscription scope and Reader permissions before interpreting this as an empty inventory." }
}

if ($MyInvocation.InvocationName -ne '.') {
    Export-ServiceSkuInventory -Tenant $TenantId -Output $OutputDirectory -Subscriptions $SubscriptionId -Ranking $RankingCsv
}
