#requires -Version 7.0
<#
.SYNOPSIS
    Moves a local (Docker/Azurite) CIPP instance into an Azure deployment created
    with CyberDrain's deployment/cipp-deploy.bicep template.

.DESCRIPTION
    Locally, CIPP stores data in Azurite and secrets in the 'DevSecrets' table
    (because NonLocalHostAzurite=true). In Azure, data lives in the Storage Account
    and secrets in Key Vault. This script:

      1. Copies every Azurite table -> Azure Storage Account tables
         (skips DevSecrets, durable-orchestrator state and regenerable caches/logs)
      2. Copies blob containers -> Azure Storage Account (download/upload; Azure
         cannot pull from your LAN)
      3. Translates DevSecrets rows -> Key Vault secrets using the same names CIPP
         reads in Azure (ApplicationID, ApplicationSecret, TenantID, RefreshToken,
         SAMCertificate, SSO*, direct-tenant tokens, extension API keys, ...)

    Run it on the Docker VM (Azurite is bound to 127.0.0.1) with the stack's
    cipp-api container STOPPED and the Azure web app STOPPED.

.PARAMETER TargetStorageConnectionString
    Connection string of the Azure Storage Account the template created
    (web app -> Environment variables -> AzureWebJobsStorage).

.PARAMETER KeyVaultName
    Key Vault created by the template (same name as the web app).

.PARAMETER SourceConnectionString
    Azurite connection string. Default = local Azurite on 127.0.0.1.

.PARAMETER IncludeLogs
    Also copy CippLogs / AuditLogs history (can be large; not needed to run).

.PARAMETER SkipSecrets
    Copy data only; re-run the Setup Wizard in Azure instead of moving secrets.

.EXAMPLE
    ./Move-CippLocalToAzure.ps1 -TargetStorageConnectionString $cs -KeyVaultName cippab12c -WhatIf

.EXAMPLE
    Connect-AzAccount -Tenant <your-tenant-id>
    ./Move-CippLocalToAzure.ps1 -TargetStorageConnectionString $cs -KeyVaultName cippab12c
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$TargetStorageConnectionString,
    [Parameter(Mandatory)][string]$KeyVaultName,
    [string]$SourceConnectionString = 'DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;',
    [switch]$IncludeLogs,
    [switch]$SkipSecrets,
    [string]$LogPath = (Join-Path $PSScriptRoot "migration-$(Get-Date -Format yyyyMMdd-HHmmss).log")
)

$ErrorActionPreference = 'Stop'
Start-Transcript -Path $LogPath | Out-Null

foreach ($m in 'AzBobbyTables', 'Az.Storage', 'Az.KeyVault', 'Az.Accounts') {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        throw "Module '$m' missing. Install-Module $m -Scope CurrentUser"
    }
}
Import-Module AzBobbyTables, Az.Storage, Az.KeyVault -ErrorAction Stop

# ── Table rules ─────────────────────────────────────────────────────────────
$SkipAlways = @(
    '^DevSecrets$'            # handled separately -> Key Vault
    '^CippOrchestrator'       # in-flight durable/orchestrator state
    '^cache'                  # Graph/report caches, regenerate
    '^CacheWebhooks'
    '^CalendarFolderCache$'
    '^CippTestResults$'
    '^AlertLastRun$'
    '^FailedAuditLogDownloads$'
    '^AuditLogCoverage$'
)
$LogTables = @('^CippLogs$', '^AuditLogs$')
$SkipPatterns = if ($IncludeLogs) { $SkipAlways } else { $SkipAlways + $LogTables }

$SrcCtx = New-AzStorageContext -ConnectionString $SourceConnectionString
$DstCtx = New-AzStorageContext -ConnectionString $TargetStorageConnectionString

$Summary = [System.Collections.Generic.List[object]]::new()

# ── 1. Tables ───────────────────────────────────────────────────────────────
Write-Host "`n== Tables ==" -ForegroundColor Cyan
$Tables = Get-AzStorageTable -Context $SrcCtx | Select-Object -ExpandProperty Name | Sort-Object
foreach ($T in $Tables) {
    if ($SkipPatterns | Where-Object { $T -match $_ }) {
        Write-Host "  skip  $T"
        $Summary.Add([pscustomobject]@{ Type = 'Table'; Name = $T; Items = 0; Result = 'Skipped' })
        continue
    }
    try {
        $Src = New-AzDataTableContext -ConnectionString $SourceConnectionString -TableName $T
        $Rows = @(Get-AzDataTableEntity -Context $Src)
        if ($Rows.Count -eq 0) {
            $Summary.Add([pscustomobject]@{ Type = 'Table'; Name = $T; Items = 0; Result = 'Empty' }); continue
        }
        # Strip service-managed properties
        $Clean = foreach ($r in $Rows) {
            $h = @{}
            foreach ($p in $r.PSObject.Properties) {
                if ($p.Name -in 'Timestamp', 'ETag', 'odata.etag') { continue }
                $h[$p.Name] = $p.Value
            }
            $h
        }
        if ($PSCmdlet.ShouldProcess("$T ($($Rows.Count) rows)", 'Copy table to Azure')) {
            $Dst = New-AzDataTableContext -ConnectionString $TargetStorageConnectionString -TableName $T
            # batches of 100 keep payloads under the table service limits
            for ($i = 0; $i -lt $Clean.Count; $i += 100) {
                $batch = $Clean[$i..([math]::Min($i + 99, $Clean.Count - 1))]
                Add-AzDataTableEntity -Context $Dst -Entity $batch -Force -CreateTableIfNotExists
            }
        }
        Write-Host ("  copy  {0,-40} {1,8} rows" -f $T, $Rows.Count) -ForegroundColor Green
        $Summary.Add([pscustomobject]@{ Type = 'Table'; Name = $T; Items = $Rows.Count; Result = 'Copied' })
    } catch {
        Write-Warning "  FAIL  $T : $($_.Exception.Message)"
        $Summary.Add([pscustomobject]@{ Type = 'Table'; Name = $T; Items = 0; Result = "Failed: $($_.Exception.Message)" })
    }
}

# ── 2. Blobs ────────────────────────────────────────────────────────────────
Write-Host "`n== Blob containers ==" -ForegroundColor Cyan
$Tmp = Join-Path ([IO.Path]::GetTempPath()) "cipp-blobs-$(Get-Random)"
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
    foreach ($C in Get-AzStorageContainer -Context $SrcCtx) {
        # Functions-runtime housekeeping containers are not CIPP data
        if ($C.Name -match '^(azure-webjobs-|scm-)') { continue }
        $Blobs = @(Get-AzStorageBlob -Container $C.Name -Context $SrcCtx)
        if ($PSCmdlet.ShouldProcess("$($C.Name) ($($Blobs.Count) blobs)", 'Copy container to Azure')) {
            if (-not (Get-AzStorageContainer -Name $C.Name -Context $DstCtx -ErrorAction SilentlyContinue)) {
                New-AzStorageContainer -Name $C.Name -Context $DstCtx -Permission Off | Out-Null
            }
            foreach ($B in $Blobs) {
                $local = Join-Path $Tmp ([guid]::NewGuid())
                Get-AzStorageBlobContent -Container $C.Name -Blob $B.Name -Destination $local -Context $SrcCtx -Force | Out-Null
                Set-AzStorageBlobContent -Container $C.Name -Blob $B.Name -File $local -Context $DstCtx -Force | Out-Null
                Remove-Item $local -Force
            }
        }
        Write-Host ("  copy  {0,-40} {1,8} blobs" -f $C.Name, $Blobs.Count) -ForegroundColor Green
        $Summary.Add([pscustomobject]@{ Type = 'Blob'; Name = $C.Name; Items = $Blobs.Count; Result = 'Copied' })
    }
} finally { Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue }

# ── 3. DevSecrets -> Key Vault ──────────────────────────────────────────────
# Mapping derived from CIPP v11 source:
#   Row Secret/Secret : one column per secret (ApplicationID, ApplicationSecret,
#                       TenantID, RefreshToken, SAMCertificate[Previous], and
#                       direct-tenant tokens stored as <guid_with_underscores>)
#   Row SSO/SSO       : SSOAppId, SSOAppSecret, SSOMultiTenant
#   Any other row     : PartitionKey = secret name, value in APIKey / SASUrl
if (-not $SkipSecrets) {
    Write-Host "`n== DevSecrets -> Key Vault '$KeyVaultName' ==" -ForegroundColor Cyan
    if (-not (Get-AzContext)) { throw 'Run Connect-AzAccount first (needs secret set permission on the vault).' }
    $DevCtx = New-AzDataTableContext -ConnectionString $SourceConnectionString -TableName 'DevSecrets'
    $Rows = @(Get-AzDataTableEntity -Context $DevCtx)
    $Meta = 'PartitionKey', 'RowKey', 'Timestamp', 'ETag', 'odata.etag'
    $GuidUnderscore = '^[0-9a-fA-F]{8}(_[0-9a-fA-F]{4}){3}_[0-9a-fA-F]{12}$'

    $ToWrite = [ordered]@{}
    foreach ($r in $Rows) {
        if ($r.PartitionKey -in 'Secret', 'SSO') {
            foreach ($p in $r.PSObject.Properties | Where-Object { $_.Name -notin $Meta }) {
                if ([string]::IsNullOrWhiteSpace([string]$p.Value)) { continue }
                $name = if ($p.Name -match $GuidUnderscore) { $p.Name -replace '_', '-' } else { $p.Name }
                $ToWrite[$name] = [string]$p.Value
            }
        } else {
            $val = if ($r.APIKey) { $r.APIKey } elseif ($r.SASUrl) { $r.SASUrl } else {
                ($r.PSObject.Properties | Where-Object { $_.Name -notin $Meta } | Select-Object -First 1).Value
            }
            if ($val) { $ToWrite[$r.PartitionKey] = [string]$val }
        }
    }

    foreach ($k in $ToWrite.Keys) {
        $kvName = $k -replace '[^0-9a-zA-Z-]', '-'   # KV allows alphanumerics and dashes only
        if ($PSCmdlet.ShouldProcess("$KeyVaultName/$kvName", 'Set Key Vault secret')) {
            try {
                Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $kvName `
                    -SecretValue (ConvertTo-SecureString $ToWrite[$k] -AsPlainText -Force) | Out-Null
                Write-Host "  set   $kvName" -ForegroundColor Green
                $Summary.Add([pscustomobject]@{ Type = 'Secret'; Name = $kvName; Items = 1; Result = 'Set' })
            } catch {
                Write-Warning "  FAIL  $kvName : $($_.Exception.Message)"
                $Summary.Add([pscustomobject]@{ Type = 'Secret'; Name = $kvName; Items = 0; Result = "Failed: $($_.Exception.Message)" })
            }
        }
    }
}

# ── Report ──────────────────────────────────────────────────────────────────
$Csv = [IO.Path]::ChangeExtension($LogPath, '.csv')
$Summary | Export-Csv -Path $Csv -NoTypeInformation
Write-Host "`nSummary: $Csv" -ForegroundColor Cyan
$Summary | Group-Object Type, Result | Select-Object Name, Count | Format-Table -AutoSize

Write-Host @'
Next steps:
  1. Start the Azure web app. Watch Log stream for "[Auth-Init] SAM credentials loaded".
  2. Browse to the azurewebsites.net URL – Azure EasyAuth/SSO setup runs here
     (local used oauth2-proxy, so SSO must be configured once in Azure).
  3. Settings > Super Admin: verify tenants, then run "Refresh Tokens" if any tenant
     shows token errors (refresh tokens are bound to the SAM app, not the host).
  4. Re-save extension settings if any integration fails.
'@
Stop-Transcript | Out-Null
