# Rando Mon — Deployment

## Step 0 — GCP project

Do this from your local machine with the `gcloud` CLI installed.

Pick a globally unique project ID. It can contain lowercase letters, numbers, and hyphens. Example:

```bash
PROJECT_ID=randomon-prod
PROJECT_NAME="Rando Mon"

gcloud auth login
gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME"
gcloud config set project "$PROJECT_ID"
```

Link billing:

```bash
gcloud billing accounts list

# Copy the billing account ID you want to use, then:
BILLING_ACCOUNT_ID=<billing-account-id>
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT_ID"
```

Enable required APIs:

```bash
gcloud services enable compute.googleapis.com storage.googleapis.com
```

After this, continue with Step 1. Do not update DNS yet; wait until Step 1 prints the VM external IP.

---

## What lives where

```
/opt/randomon/                            ← git clone of patatoa/randomon
│
├── pokemon-showdown                      ← PS game server entry point
├── config/
│   └── config.js                         ← SERVER config (gitignored — create on VM)
│
├── client/                               ← PS web client (monorepo, not a submodule)
│   ├── build-tools/update                ← client build script (run from client/)
│   ├── config/
│   │   ├── config.js                     ← CLIENT config (gitignored — create on VM)
│   │   ├── config.production.js          ← template for config.js (committed)
│   │   ├── routes.json                   ← local asset URL roots (committed as localhost:8080)
│   │   └── routes.production.json        ← production routes used by deploy builds via PS_ROUTES
│   └── play.pokemonshowdown.com/         ← nginx serves this directory as the website root
│       ├── index.html                    ← generated: cp caches/index-new.html index.html
│       ├── sprites/                      ← downloaded by scripts/download-assets.sh (gitignored)
│       ├── data/                         ← built: graphics.js, battledata.js, etc.
│       └── js/                           ← built: client JS bundle
│
└── scripts/
    └── download-assets.sh                ← pulls assets from GCS by default, or from PS CDN with --cdn
```

**Traffic flow:**
```
Browser (HTTPS / WSS)
    │
    ▼
nginx :443  (TLS via Let's Encrypt)
    ├── /*           → static files served directly from disk
    │                  /opt/randomon/client/play.pokemonshowdown.com/
    │                  (index.html, js/, data/, sprites/, fx/)
    │
    └── /showdown/*  → reverse-proxy to PS game server on 127.0.0.1:8000
                       (WebSocket upgrade; SockJS appends its own path segments)
```

nginx and the PS server both run on the same VM. The PS server never listens on a public port — only on loopback :8000. nginx terminates TLS and forwards WebSocket traffic.

---

## Step 1 — GCP VM

From your local machine (needs `gcloud` CLI, `gcloud auth login` first):

```bash
# Create the instance (e2-micro is free-tier eligible in us-central1).
gcloud compute instances create randomon \
  --zone=us-central1-a \
  --machine-type=e2-micro \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB \
  --boot-disk-type=pd-standard \
  --tags=http-server,https-server

# Open ports 80 + 443 (these rules apply to all instances with the tags above)
gcloud compute firewall-rules create allow-http \
  --allow=tcp:80 --target-tags=http-server --direction=INGRESS 2>/dev/null || true
gcloud compute firewall-rules create allow-https \
  --allow=tcp:443 --target-tags=https-server --direction=INGRESS 2>/dev/null || true

# Print the external IP (copy this — you'll use it in Step 2)
gcloud compute instances describe randomon \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'

# SSH in
gcloud compute ssh randomon --zone=us-central1-a
```

---

## Step 2 — DNS

At your registrar, add one A record:

| Type | Name | Value | TTL |
|------|------|-------|-----|
| A | `randomon` | `<GCP external IP>` | 300 |

This makes `randomon.patatoa.com` point to the VM.

---

## Step 3 — VM base setup

```bash
# As root on the VM
apt update && apt upgrade -y
apt install -y nginx certbot python3-certbot-nginx git ca-certificates curl gnupg

# Node.js 22+ is required by this repo's build and startup scripts.
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y nodejs

# Google Cloud CLI for `gcloud storage rsync` in scripts/download-assets.sh.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg
echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  > /etc/apt/sources.list.d/google-cloud-sdk.list
apt update
apt install -y google-cloud-cli

# Service user
useradd -m -s /bin/bash randomon

# Deployment directory owned by the service user.
mkdir -p /opt/randomon
chown randomon:randomon /opt/randomon
```

---

## Step 4 — Clone repo and install deps

```bash
# As the randomon user
su - randomon

git clone https://github.com/patatoa/randomon.git /opt/randomon
cd /opt/randomon

# Server deps
npm ci

# Client deps
cd client
npm ci
cd ..

# Runtime log files expected by the server at startup and during lobby activity.
mkdir -p /opt/randomon/logs /opt/randomon/logs/repl
touch /opt/randomon/logs/chatlog-access.txt \
  /opt/randomon/logs/responder.jsonl \
  /opt/randomon/logs/errors.txt
```

---

## Step 5 — Server config

`/opt/randomon/config/config.js` — create this file (it's gitignored):

```js
/* jshint esversion: 9 */
'use strict';

exports.port = 8000;
exports.bindaddress = '127.0.0.1';
exports.proxyip = ['127.0.0.1'];
exports.noipchecks = true;
exports.noguestsecurity = true;
exports.repl = false;
exports.forcedformat = 'gen9randomon';
```

---

## Step 6 — Client config and build

**6a. Client config** — copy the committed production template:

```bash
cp /opt/randomon/client/config/config.production.js /opt/randomon/client/config/config.js
```

`config.production.js` already has:
```js
Config.defaultserver = {
    id: 'randomon',
    protocol: 'https',
    host: 'randomon.patatoa.com',
    port: 443, httpport: 443, altport: 443,
    registered: false  // local names; do not require real Pokémon Showdown passwords
};
```

**6b. Production routes** — local builds use committed `client/config/routes.json` (`localhost:8080`). Deploy builds use `client/config/routes.production.json` through `PS_ROUTES`, so the VM working tree stays clean.

This controls the URL prefix for all sprites and assets (`//randomon.patatoa.com/sprites/...`). The default local path remains unchanged for development.

**6c. Build the client:**

```bash
cd /opt/randomon/client
PS_ROUTES=config/routes.production.json node build-tools/update full
# "full" is required — compiles graphics.js and chat-formatter.js; regular build skips them

cp play.pokemonshowdown.com/caches/index-new.html play.pokemonshowdown.com/index.html
```

---

## Step 7 — Assets (sprites, FX, data files)

Sprites are gitignored (too large for git). They live in a public GCS bucket you control — no runtime dependency on the PS CDN.

### 7a — One-time: create and populate the bucket *(do this locally, not on the VM)*

You need `download-assets.sh --cdn` to have already run locally so the files exist under
`client/play.pokemonshowdown.com/`. Then:

```bash
# From the repo root on your local machine
RANDOMON_BUCKET=gs://<your-randomon-assets-bucket> bash scripts/upload-assets-to-gcs.sh
# Creates the public bucket if needed and pushes sprites/, fx/, and data/ into it.
```

This is a one-time step. Re-run it only when the pool changes (new Pokémon added to roster).

### 7b — Every VM setup: pull from bucket

```bash
# On the VM, from /opt/randomon
su - randomon
cd /opt/randomon
RANDOMON_BUCKET=gs://<your-randomon-assets-bucket> bash scripts/download-assets.sh
# Pulls assets from the configured bucket via gcloud storage rsync or gsutil.
```

The bucket is public-read, so the VM does not need bucket-specific IAM. The VM still needs `google-cloud-cli` installed because `scripts/download-assets.sh` uses `gcloud storage rsync`.

---

## Step 8 — systemd service

`/etc/systemd/system/randomon.service` (as root):

```ini
[Unit]
Description=Rando Mon PS Server
After=network.target

[Service]
Type=simple
User=randomon
WorkingDirectory=/opt/randomon
ExecStartPre=/usr/bin/mkdir -p /opt/randomon/logs /opt/randomon/logs/repl
ExecStartPre=/usr/bin/touch /opt/randomon/logs/chatlog-access.txt /opt/randomon/logs/responder.jsonl /opt/randomon/logs/errors.txt
ExecStart=/usr/bin/node pokemon-showdown --skip-build 8000
Restart=always
RestartSec=5
StandardInput=null
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now randomon
journalctl -u randomon -n 30   # confirm it started
```

---

## Step 9 — nginx

`/etc/nginx/sites-available/randomon` (as root):

```nginx
server {
    listen 80;
    server_name randomon.patatoa.com;

    root /opt/randomon/client/play.pokemonshowdown.com;
    index index.html;

    location /~~randomon/ {
        proxy_pass https://play.pokemonshowdown.com;
        proxy_ssl_server_name on;
        proxy_set_header Host play.pokemonshowdown.com;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /showdown/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
```

```bash
ln -s /etc/nginx/sites-available/randomon /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
```

---

## Step 10 — TLS

DNS must be propagated first.

```bash
dig +short randomon.patatoa.com   # must return your GCP IP before continuing

certbot --nginx -d randomon.patatoa.com
# Certbot edits the nginx config automatically and sets up auto-renewal
```

---

## Step 11 — Smoke test

```bash
# PS server up?
curl http://127.0.0.1:8000

# HTTPS serving?
curl -I https://randomon.patatoa.com

# Server logs
journalctl -u randomon -f
```

Open `https://randomon.patatoa.com` in two browser tabs. The Battle button should appear immediately (no "Connecting..."). Challenge the other tab and confirm a battle starts with gen9randomon and sprites load.

---

## Redeployment

Production deployment is handled by the `Deploy Randomon Production` GitHub
Actions workflow in `.github/workflows/deploy-production.yml`.

The workflow runs automatically after a push to `master` and can also be run
manually with **Actions → Deploy Randomon Production → Run workflow**. It deploys
the exact commit for the workflow run, prevents overlapping production deploys,
builds the server and client on the VM, restarts `randomon`, and checks local and
public health endpoints.

The workflow intentionally fails if `/opt/randomon` is not already a clean Git
checkout of `https://github.com/patatoa/randomon.git`. It does not delete,
replace, or convert the production directory.

### Required GitHub secrets

Configure these as repository secrets or production environment secrets:

| Secret | Purpose |
|--------|---------|
| `RANDOMON_DEPLOY_HOST` | Production SSH host, for example `randomon.patatoa.com`. |
| `RANDOMON_DEPLOY_USER` | Dedicated SSH deployment user. |
| `RANDOMON_DEPLOY_SSH_KEY` | Private key for the deployment user. |
| `RANDOMON_DEPLOY_KNOWN_HOSTS` | Pinned `known_hosts` line for the production host. |
| `RANDOMON_DEPLOY_PORT` | Optional SSH port. Defaults to `22`. |

Create `RANDOMON_DEPLOY_KNOWN_HOSTS` from a trusted machine:

```bash
ssh-keyscan -H randomon.patatoa.com
```

Verify the fingerprint out of band before saving it as a secret.

### One-time checkout conversion

Current production note: `/opt/randomon` may be an older file-copy deployment
directory instead of a Git checkout. Convert it manually and carefully before
expecting the GitHub workflow to succeed.

Do this from an admin shell on the VM:

```bash
# Stop the service only when you are ready for the final switch.
sudo systemctl stop randomon

# Preserve the current production directory.
sudo mv /opt/randomon /opt/randomon.pre-git.$(date +%Y%m%d%H%M%S)

# Clone a fresh checkout owned by the service user.
sudo -u randomon git clone https://github.com/patatoa/randomon.git /opt/randomon
cd /opt/randomon
sudo -u randomon git checkout master

# Restore live-only files and runtime data from the preserved directory.
OLD=/opt/randomon.pre-git.<timestamp>
sudo -u randomon mkdir -p /opt/randomon/config /opt/randomon/client/config /opt/randomon/logs
sudo -u randomon cp "$OLD/config/config.js" /opt/randomon/config/config.js
sudo -u randomon cp "$OLD/client/config/config.js" /opt/randomon/client/config/config.js
sudo -u randomon cp -a "$OLD/logs/." /opt/randomon/logs/

# Preserve downloaded assets when they already exist locally.
sudo -u randomon cp -a "$OLD/client/play.pokemonshowdown.com/sprites" \
  /opt/randomon/client/play.pokemonshowdown.com/ 2>/dev/null || true
sudo -u randomon cp -a "$OLD/client/play.pokemonshowdown.com/fx" \
  /opt/randomon/client/play.pokemonshowdown.com/ 2>/dev/null || true
sudo -u randomon cp -a "$OLD/client/play.pokemonshowdown.com/data" \
  /opt/randomon/client/play.pokemonshowdown.com/ 2>/dev/null || true

# Rebuild and verify before restarting.
sudo -u randomon npm ci
sudo -u randomon node build
sudo -u randomon bash -lc '
  cd /opt/randomon/client &&
  npm ci &&
  PS_ROUTES=config/routes.production.json node build-tools/update full &&
  cp play.pokemonshowdown.com/caches/index-new.html play.pokemonshowdown.com/index.html
'

sudo systemctl start randomon
sudo systemctl is-active randomon
curl -fsS http://127.0.0.1:8000/showdown/info
curl -fsSI https://randomon.patatoa.com
```

Only remove the preserved `/opt/randomon.pre-git.*` directory after a successful
workflow deployment and smoke test.

### Live-only config check

The production server config is `/opt/randomon/config/config.js` and is
gitignored. Confirm these values after the checkout conversion and after deploys
that touch matchmaking:

```js
exports.proxyip = ['127.0.0.1'];
exports.noipchecks = true;
exports.noguestsecurity = true;
exports.forcedformat = 'gen9randomon';
```

`exports.noipchecks = true` is required for two players behind the same public
IP, including two local browser tabs, to match each other.

### Deployment SSH user and sudo

Recommended setup: install the deployment SSH key for the `randomon` service
user and set `RANDOMON_DEPLOY_USER=randomon`. Git operations and builds then run
directly as `randomon`, and sudo is needed only for service restart and
diagnostics.

```sudoers
Cmnd_Alias RANDOMON_SYSTEMD = /bin/systemctl restart randomon, \
  /bin/systemctl is-active randomon, \
  /bin/systemctl status randomon --no-pager
Cmnd_Alias RANDOMON_JOURNAL = /bin/journalctl -u randomon -n 100 --no-pager

randomon ALL=(root) NOPASSWD: RANDOMON_SYSTEMD, RANDOMON_JOURNAL
```

Adjust `/bin/systemctl` and `/bin/journalctl` paths if `command -v systemctl` or
`command -v journalctl` shows different paths on the VM. Do not grant
`NOPASSWD: ALL`.

If you choose a separate deployment user instead of `randomon`, it must also be
allowed to run the repository Git, npm, Node, test, copy, and client build
commands as `randomon`. Keep that policy scoped to `/opt/randomon`; do not grant
unrestricted root sudo.

### What each workflow deployment does

For every automatic or manual deployment, the workflow:

1. Validates required GitHub secrets before SSH.
2. Connects with strict SSH host-key checking.
3. Verifies `/opt/randomon/.git` exists.
4. Verifies the Git origin is `https://github.com/patatoa/randomon.git`.
5. Fails if tracked production files are dirty, except for the generated
   `client/play.pokemonshowdown.com/index.html` promotion from the previous
   production build.
6. Fetches and checks out the exact workflow SHA.
7. Runs `npm ci` and `node build` from `/opt/randomon`.
8. Runs `npm ci` from `/opt/randomon/client`.
9. Runs `PS_ROUTES=config/routes.production.json node build-tools/update full`.
10. Copies `play.pokemonshowdown.com/caches/index-new.html` to
    `play.pokemonshowdown.com/index.html`.
11. Restarts `randomon`.
12. Verifies `systemctl is-active randomon`.
13. Checks `http://127.0.0.1:8000/showdown/info`.
14. Checks `https://randomon.patatoa.com`.
15. Checks `https://randomon.patatoa.com/showdown/info`.

The workflow never runs `git clean`, so gitignored production configuration,
logs, downloaded sprites, effects, and other runtime files are preserved. The
only tracked file the workflow may reset before checkout is
`client/play.pokemonshowdown.com/index.html`, because production deploys
regenerate it from `caches/index-new.html`.

### Failure recovery

The workflow exits nonzero on checkout, dependency, build, restart, or health
failure. Failed restart and health-check stages print `systemctl status randomon`
and recent `journalctl -u randomon` output in the workflow logs.

Common fixes:

- Non-Git `/opt/randomon`: complete the one-time checkout conversion above.
- Unexpected Git origin: correct the remote with
  `sudo -u randomon git -C /opt/randomon remote set-url origin https://github.com/patatoa/randomon.git`.
- Dirty tracked files: inspect
  `sudo -u randomon git -C /opt/randomon status --short --untracked-files=no`
  and either commit, revert, or manually preserve the change before retrying.
- Missing `index-new.html`: rerun the client build command locally on the VM and
  inspect its failure output.
- Failed health checks: inspect `journalctl -u randomon -n 100 --no-pager` and
  nginx logs, then rerun the same workflow after fixing the issue.

### Manual rollback

Automatic rollback is intentionally out of scope. To roll back, dispatch the
deployment workflow for a previously known-good commit from `master`, or SSH to
the VM and check out that SHA manually, then run the same build, index promotion,
restart, and health checks listed above.

---

## Checklist

- [ ] Step 1: GCP e2-micro VM created, external IP noted
- [ ] Step 2: DNS A record `randomon` → GCP IP propagated
- [ ] Steps 3–4: VM provisioned, repo cloned, deps installed
- [ ] Step 5: `/opt/randomon/config/config.js` created
- [ ] Step 6: Client config copied, production routes selected with `PS_ROUTES`, client built, index.html in place
- [ ] Step 7a: GCS bucket created and populated (`scripts/upload-assets-to-gcs.sh`) — one-time, local
- [ ] Step 7b: Assets pulled on VM (`scripts/download-assets.sh`)
- [ ] Step 8: systemd service running (`systemctl status randomon`)
- [ ] Step 9: nginx configured and reloaded
- [ ] Step 10: TLS cert issued (`certbot --nginx`)
- [ ] Step 11: Smoke test passes — Battle button visible, match starts
