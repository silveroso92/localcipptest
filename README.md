# CIPP – Local/On-Prem Test Stack → Azure

Built against **CIPP v11.0.2** (`CyberDrain/CIPP` mono-repo). Drop this folder into
your fork at `build/local/`. No upstream files are modified, so `git merge upstream/main`
stays conflict-free.

## What it is

| | Local (this stack) | Azure (`deployment/cipp-deploy.bicep`) |
|---|---|---|
| App | `ghcr.io/cyberdrain/cipp` container (CRAFT runtime) | **Same image** on App Service Linux B2 |
| Data | Azurite (Table/Blob/Queue emulator) | Storage Account |
| Secrets | `DevSecrets` table (auto when `NonLocalHostAzurite=true`) | Key Vault |
| Tech sign-in | Caddy (TLS) → oauth2-proxy (Entra) | App Service EasyAuth (CIPP-SSO) |
| Tenant access | Graph / Partner Center via SAM app | identical |

Since v11, CIPP runs as one container (not Function App + Static Web App), so the local
runtime is the production runtime – only storage, secrets and the auth front door differ.

```
build/local/
├─ docker-compose.local.yml
├─ .env.example
├─ config/appsettings.Local.json     # Production settings + local auth posture
├─ caddy/Caddyfile
├─ monitoring/prometheus.yml
├─ scripts/  collect-stats.sh  summarize-stats.sh  backup.sh  restore.sh
└─ migrate/Move-CippLocalToAzure.ps1
```

## 1. VM (Proxmox)

Ubuntu Server 24.04, **4 vCPU / 12 GB RAM / 80 GB disk**, internal VLAN.
(CIPP container is capped at B2 = 2 vCPU/3.5 GB; Azurite holds its whole table DB in
RAM; leave headroom for the OS and monitoring.)

```bash
sudo apt update && sudo apt install -y git curl
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER && newgrp docker
```

## 2. Entra app registration for the front door ("CIPP-Local-Proxy")

In **your MSP tenant** – this only protects the UI; it is NOT the CIPP SAM app.

1. App registrations → New → *Single tenant*
2. Redirect URI (Web): `https://<CIPP_HOSTNAME>/oauth2/callback`
3. Certificates & secrets → new client secret
4. Optional: Token configuration → add **groups** claim, then set `ALLOWED_GROUP_IDS`
5. Enterprise app → **Assignment required = Yes**, assign your CIPP techs group

## 3. Start

```bash
git clone https://github.com/<YourOrg>/CIPP.git && cd CIPP
git remote add upstream https://github.com/CyberDrain/CIPP.git
# copy this folder to build/local/
cd build/local
cp .env.example .env && chmod 600 .env
openssl rand -base64 32 | tr -- '+/' '-_'     # -> OAUTH2_COOKIE_SECRET
nano .env
docker compose -f docker-compose.local.yml up -d
docker compose -f docker-compose.local.yml logs -f cipp-api
```

Wait for the warmup lines (`[Auth-Init] ...`), then browse `https://<CIPP_HOSTNAME>`.
With `CADDY_TLS=internal`, trust Caddy's root once on test PCs:

```bash
docker compose -f docker-compose.local.yml cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
```
Import into *Trusted Root Certification Authorities* (or push via Intune trusted cert profile).

## 4. CIPP Setup Wizard

Run **First Setup** as documented by CyberDrain – use the dedicated CIPP service account,
choose **certificate** auth, Connect to Partner Tenant, then add GDAP/direct tenants.
Locally the SAM credentials land in `DevSecrets`; nothing touches Key Vault.

> **Start with a dev/sandbox tenant or your internal tenant.** The SAM app the wizard
> creates is real and has real permissions in every tenant you connect.

## 5. Running your fork's code

```bash
# .env:  COMPOSE_PROFILES=build,monitoring
docker compose -f docker-compose.local.yml up -d --build
```
Builds `build/Dockerfile.release` (first build ~10–20 min). Never enable `image` and
`build` together.

## 6. Performance & cost data

```bash
nohup ./scripts/collect-stats.sh 60 >/dev/null 2>&1 &   # leave running for 1–2 weeks
./scripts/summarize-stats.sh                            # any time
```
Prometheus (profile `monitoring`): `ssh -L 9090:localhost:9090 user@vm` → http://localhost:9090
Useful queries:
- `rate(container_cpu_usage_seconds_total{container_label_com_docker_compose_service="cipp-api"}[5m])`
- `container_memory_working_set_bytes{container_label_com_docker_compose_service="cipp-api"}`
- `container_oom_events_total` (any increase = plan too small)

### Sizing profiles (App Service Linux)

Set in `.env`, then `docker compose ... up -d`. Pool sizes mirror CIPP's own `SkuProfiles`.

| Plan | vCPU / RAM | SIM_SKU | SIM_CPUS | SIM_MEM | HTTP_POOL | BG_POOL | GC_HEAP_LIMIT |
|---|---|---|---|---|---|---|---|
| B1 | 1 / 1.75 GB | Basic | 1 | 1792m | 2 | 2 | 0x60000000 |
| **B2 (template default)** | 2 / 3.5 GB | Basic | 2 | 3584m | 6 | 8 | 0x95E00000 |
| B3 | 4 / 7 GB | Basic | 4 | 7168m | 8 | 12 | 0x1A0000000 |
| P1v3 | 2 / 8 GB | PremiumV3 | 2 | 8192m | 8 | 12 | 0x1E0000000 |

### Turning measurements into an Azure estimate

App Service is billed **per plan-hour regardless of load**, so the result is a SKU choice,
not a usage bill:

| Signal from local run | Meaning |
|---|---|
| `cipp-api` mem p95 < ~75% of limit, no OOM, CPU p95 < ~150% (B2) | B2 is enough |
| OOM events / container restarts during standards or audit-log runs | step up (B3 or P1v3) |
| UI slow only while the 12-hourly standards run | consider B3 before Premium |

Then add:
- **Storage Account** – capacity ≈ final Azurite size from the summary; transactions scale
  with tenant count × timers (`backend/Config/CIPPTimers.json`). Get the transaction count
  from the Storage Account metrics after the first Azure week – Azurite can't report it.
- **Key Vault** – secret reads at warmup/token refresh; minor.

Price the plan + storage in the Azure Pricing Calculator for your region and compare with
CyberDrain's hosted plan.

> Local numbers are directional: your Proxmox host CPU is likely faster per core than a
> B-series vCPU, and Azurite (in-memory LokiJS) is faster than remote Table storage.
> Treat B2 headroom found locally as an upper bound.

## 7. Backups

```bash
./scripts/backup.sh /mnt/backup/cipp          # cron nightly; stops app ~10–30 s
./scripts/restore.sh /mnt/backup/cipp/cipp-azurite-YYYY-MM-DD-HHMM.tgz
```
Archives contain the SAM secret / refresh token – protect them accordingly.
Snapshot the VM in Proxmox before every CIPP image upgrade.

## 8. Migrating to Azure

1. Deploy `deployment/cipp-deploy.bicep` (or the Deploy-to-Azure button) into a new RG.
   For your fork's image, push it to a registry and pass `containerImage=DOCKER|<registry>/cipp:<tag>`.
2. **Stop** the Azure web app. On the VM: `docker compose -f docker-compose.local.yml stop cipp-api`
3. On the VM (needs PowerShell 7 + `AzBobbyTables`, `Az.Storage`, `Az.KeyVault`):
   ```powershell
   Connect-AzAccount -Tenant <msp-tenant-id>
   $cs = '<AzureWebJobsStorage value from the web app>'
   ./migrate/Move-CippLocalToAzure.ps1 -TargetStorageConnectionString $cs -KeyVaultName <webappname> -WhatIf
   ./migrate/Move-CippLocalToAzure.ps1 -TargetStorageConnectionString $cs -KeyVaultName <webappname>
   ```
   Your account needs secret **Set** permission on the vault (the template only grants the
   web app's identity – add an access policy for yourself first).
4. Start the web app → configure SSO/custom domain → validate tenants.
5. Alternative to step 3: copy nothing, run First Setup fresh in Azure, re-onboard tenants.
   Use CIPP's built-in backup/restore (Settings → Backup) to carry templates/standards over.

Leave the VM stack as your pre-production environment for testing new CIPP releases.

## Known limits / verify on first run

- **Not a CyberDrain-supported topology.** It reuses their dev-mode switches
  (`NonLocalHostAzurite`, `DevSecrets`) with the release image. Upgrades could change that.
- **All authenticated techs are CIPP superadmin locally** (`DevRoles`); CIPP role-based
  access and per-user audit attribution only apply after moving to Azure EasyAuth.
  Restrict who gets through with Entra assignment / `ALLOWED_GROUP_IDS`.
- **Frontend serving in Development env:** the dev compose files proxy the UI to a Next.js
  dev server via `CRAFT_DEV_FRONTEND_URL`; this stack leaves that unset so CRAFT should serve
  the prebuilt `/app/Frontend`. If the UI 404s, change `ASPNETCORE_ENVIRONMENT` to
  `Production` and mount `config/appsettings.Local.json` to `/app/appsettings.Production.json`.
- **Inbound webhooks** (Graph change notifications, partner webhooks) can't reach a LAN-only
  VM. Alerts relying on them only work after migration or behind a public hostname.
- Azurite is single-node and in-memory; fine for test, not a long-term production store.
