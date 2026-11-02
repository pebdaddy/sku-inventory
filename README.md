# Azure service SKU inventory

Standalone, read-only extraction of current non-VM Azure service SKUs and
configuration for migration planning and subsequent regional capability checks.

## Requirements

- Windows PowerShell 5.1.
- Azure CLI installed and authenticated to the intended customer tenant.
- Reader access on each subscription to include is recommended.
- Public Azure (`AzureCloud`); sovereign cloud endpoints are not supported.

No Python, extra PowerShell modules, Azure CLI extensions, database connectors,
or ACR reporting application are required to run the exporter.

## Quick start

In PowerShell, navigate to the folder where you cloned or extracted this project.
Replace the placeholder below with that folder's actual path:

```powershell
Set-Location '<path-to-project-folder>'
$tenant = '<customer-tenant-GUID>'
az login --tenant $tenant
az account list --all --output table

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Export-ServiceSkuInventory.ps1 `
  -TenantId $tenant `
  -OutputDirectory .\output\inventory
```

The script collects all enabled subscriptions visible to the signed-in identity
**in the specified tenant only**. Confirm that list with the customer: tenant-wide
completeness cannot be inferred from what one identity can access.

The execution-policy bypass applies only to the child process. The script does
not sign in, switch the active subscription, register providers, deploy resources,
or modify Azure configuration.

### Select subscriptions explicitly

```powershell
.\Export-ServiceSkuInventory.ps1 `
  -TenantId $tenant `
  -SubscriptionId @('<subscription-GUID-1>', '<subscription-GUID-2>') `
  -OutputDirectory .\output\inventory
```

Every requested subscription must be enabled and visible in the specified tenant;
otherwise the script fails before discovery.

## Collected configuration

| Service | Fields collected |
| --- | --- |
| Storage | Deployment SKU/redundancy, kind, default access tier, hierarchical namespace and NFS flags |
| App Service | Plan SKU/tier/capacity, Linux (`reserved`) flag, hosting environment and zone redundancy |
| SQL Database / elastic pools | SKU, tier, hardware family, capacity, service objective, pool link, licensing, serverless settings and zone redundancy |
| Azure Monitor / Log Analytics | Workspace SKU/commitment tier, retention and dedicated-cluster capacity |
| Databricks | Workspace SKU and workspace hostname |
| AKS | Cluster tier, Kubernetes/network settings and node-pool VM sizes, OS, scaling and zones |
| Firewall / NAT Gateway | Exact resource SKU and configured zones |
| API Management | SKU/capacity, platform/network mode and secondary-location SKUs/zones |
| Private Link / VNet peering | Private endpoint target group/resource IDs and peering remote VNet IDs |

Discovery uses read-only Resource Graph POST queries, followed by ARM GET requests
for allowlisted resource details. Discovery and child-resource pagination are
handled, and duplicate resource IDs are collected only once.

## Outputs

Two files are written to `-OutputDirectory`. **Reruns overwrite these files**;
use a different directory to preserve previous snapshots.

- `service-sku-inventory.json`: scope, timestamps, collection status, resource
  configurations, request failures, and limitations.
- `service-sku-inventory.csv`: one row per collected resource, with common SKU
  columns and a `configurationJson` column for service-specific details.

Keep exports in a approved location. They contain resource
names, IDs, workspace hostnames, and configuration. Do not commit exports
to source control.

Only allowlisted metadata fields are exported. No access tokens, keys,
certificates, application settings, log records, blob contents, or table schemas
are written. Missing properties remain null rather than being guessed.
Tokens stay in memory; requests are restricted to the public Azure ARM endpoint
and selected subscription scope, without following HTTP redirects.

## Failures and completeness

- HTTP failures are warned and persisted in `failures`. The export is marked
  `Partial`, and the script exits unsuccessfully after saving collected results.
- Authentication failures, invalid scope, malformed responses, and invalid
  pagination stop execution rather than producing successful-looking results.
- Child responses that omit `type` use the known parent type and child endpoint
  (for example, virtual network peerings). IDs are still required, and
  conflicting types are rejected.
- A `Collected` status means the requests completed, **not** that the inventory
  covers every resource in the tenant.
- Resource-scoped permissions may silently limit Resource Graph discovery.
  Reader access on all intended subscriptions is recommended.
- Do not interpret an empty or partial inventory as proof that a service is absent.

## Tests

With Python installed, run from the project folder on Windows:

```powershell
python -m unittest discover -s tests -v
```

Tests use synthetic responses, never connect to Azure, and clean up their
temporary files automatically.

## Project files

- [Export-ServiceSkuInventory.ps1](Export-ServiceSkuInventory.ps1): standalone exporter.
- [tests/test_service_sku_export.ps1](tests/test_service_sku_export.ps1): synthetic PowerShell tests.
- [tests/test_service_sku_export.py](tests/test_service_sku_export.py): optional Python unittest wrapper.

Script help:

```powershell
Get-Help .\Export-ServiceSkuInventory.ps1 -Examples
```
