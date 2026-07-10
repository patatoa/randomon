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
manually with **Actions → Deploy Randomon Production → Run workflow**. It builds
the exact workflow commit on GitHub Actions, packages a release artifact, uploads
that artifact to the VM, switches `/opt/randomon/current` to the new release,
restarts `randomon`, and checks local, public, and real Showdown WebSocket
startup health.

The production VM is no longer expected to be a Git checkout. Git belongs to the
GitHub runner; the VM is a runtime host with shared config, logs, databases, and
large downloaded assets kept outside release directories.

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

### One-time artifact-release setup

The workflow intentionally fails until `/opt/randomon` is prepared as a release
root. Do this manually and carefully. Do not let GitHub Actions restructure a
live production directory.

Do this from an admin shell on the VM:

```bash
# Stop the service only when ready for the final switch.
sudo systemctl stop randomon

# Preserve the current production directory.
sudo mv /opt/randomon /opt/randomon.pre-artifact.$(date +%Y%m%d%H%M%S)

# Create the release-root layout.
sudo mkdir -p /opt/randomon/releases /opt/randomon/shared/config \
  /opt/randomon/shared/client-config /opt/randomon/shared/logs \
  /opt/randomon/shared/databases /opt/randomon/shared/client-assets \
  /opt/randomon/shared/client-static
sudo chown -R randomon:randomon /opt/randomon

# Keep the timestamped backup path handy.
OLD=/opt/randomon.pre-artifact.<timestamp>

# Restore live-only server and client config.
sudo -u randomon cp "$OLD/config/config.js" /opt/randomon/shared/config/config.js
sudo -u randomon cp "$OLD/client/config/config.js" /opt/randomon/shared/client-config/config.js

# colors.json is referenced through the client config path. Use the old file if
# it exists; otherwise an empty object is acceptable.
if [ -f "$OLD/client/config/colors.json" ]; then
  sudo -u randomon cp "$OLD/client/config/colors.json" /opt/randomon/shared/client-config/colors.json
else
  printf '{}\n' | sudo -u randomon tee /opt/randomon/shared/client-config/colors.json >/dev/null
fi

# Preserve runtime logs and databases.
sudo -u randomon cp -a "$OLD/logs/." /opt/randomon/shared/logs/ 2>/dev/null || true
sudo -u randomon cp -a "$OLD/databases/." /opt/randomon/shared/databases/ 2>/dev/null || true

# Preserve large downloaded client assets that are not committed.
sudo -u randomon mkdir -p /opt/randomon/shared/client-assets
sudo -u randomon cp -a "$OLD/client/play.pokemonshowdown.com/sprites" \
  /opt/randomon/shared/client-assets/ 2>/dev/null || true
sudo -u randomon cp -a "$OLD/client/play.pokemonshowdown.com/audio" \
  /opt/randomon/shared/client-assets/ 2>/dev/null || true

# Preserve ignored static files that a clean GitHub checkout does not contain
# but the browser needs before the Randomon UI can mount.
sudo -u randomon cp -a "$OLD/client/play.pokemonshowdown.com/data" \
  /opt/randomon/shared/client-static/data
sudo -u randomon cp -a "$OLD/client/play.pokemonshowdown.com/js/lib" \
  /opt/randomon/shared/client-static/js-lib

# Seed the first release from the preserved working app so rollback is possible
# before the first artifact workflow succeeds.
sudo -u randomon mkdir -p /opt/randomon/releases/bootstrap
sudo -u randomon cp -a "$OLD/." /opt/randomon/releases/bootstrap/
sudo -u randomon rm -rf /opt/randomon/releases/bootstrap/.git
sudo -u randomon rm -rf /opt/randomon/releases/bootstrap/logs /opt/randomon/releases/bootstrap/databases
sudo -u randomon ln -s /opt/randomon/shared/logs /opt/randomon/releases/bootstrap/logs
sudo -u randomon ln -s /opt/randomon/shared/databases /opt/randomon/releases/bootstrap/databases
sudo -u randomon ln -sfn /opt/randomon/shared/config/config.js /opt/randomon/releases/bootstrap/config/config.js
sudo -u randomon ln -sfn /opt/randomon/shared/client-config/config.js /opt/randomon/releases/bootstrap/client/config/config.js
sudo -u randomon ln -sfn /opt/randomon/shared/client-config/colors.json /opt/randomon/releases/bootstrap/client/config/colors.json
sudo -u randomon rm -rf /opt/randomon/releases/bootstrap/client/play.pokemonshowdown.com/data
sudo -u randomon rm -rf /opt/randomon/releases/bootstrap/client/play.pokemonshowdown.com/js/lib
sudo -u randomon ln -sfn /opt/randomon/shared/client-static/data /opt/randomon/releases/bootstrap/client/play.pokemonshowdown.com/data
sudo -u randomon ln -sfn /opt/randomon/shared/client-static/js-lib /opt/randomon/releases/bootstrap/client/play.pokemonshowdown.com/js/lib
sudo -u randomon ln -sfn /opt/randomon/releases/bootstrap /opt/randomon/current

# Keep nginx's documented static root stable while releases switch underneath it.
sudo -u randomon ln -sfn /opt/randomon/current/client /opt/randomon/client

# Update systemd so the service runs from the current release symlink.
sudo systemctl edit randomon
```

Use this override:

```ini
[Service]
WorkingDirectory=/opt/randomon/current
ExecStart=
ExecStart=/usr/bin/node pokemon-showdown --skip-build 8000
ExecStartPre=
ExecStartPre=/usr/bin/mkdir -p /opt/randomon/shared/logs /opt/randomon/shared/logs/repl
ExecStartPre=/usr/bin/touch /opt/randomon/shared/logs/chatlog-access.txt /opt/randomon/shared/logs/responder.jsonl /opt/randomon/shared/logs/errors.txt
```

Then verify:

```bash
sudo systemctl daemon-reload
sudo systemctl start randomon
sudo systemctl is-active randomon
test -L /opt/randomon/client
curl -fsS http://127.0.0.1:8000/showdown/info
curl -fsSI https://randomon.patatoa.com
curl -fsSI https://randomon.patatoa.com/js/lib/preact.min.js
curl -fsSI https://randomon.patatoa.com/data/pokedex.js
```

Only remove the preserved `/opt/randomon.pre-artifact.*` directory after a
successful workflow deployment and smoke test.

### Live-only config check

The production server config is `/opt/randomon/shared/config/config.js` and is
linked into every release as `config/config.js`. Confirm these values after the
artifact setup and after deploys that touch matchmaking:

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
user and set `RANDOMON_DEPLOY_USER=randomon`. The workflow uploads the release
artifact to `/tmp`, extracts it into `/opt/randomon/releases`, switches
`/opt/randomon/current`, and needs sudo only for service restart and diagnostics.

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
allowed to write `/opt/randomon/current` and run release-directory file
operations as `randomon`. Keep that policy scoped to `/opt/randomon`; do not
grant unrestricted root sudo.

### What each workflow deployment does

For every automatic or manual deployment, the workflow:

1. Validates required GitHub secrets before SSH.
2. Checks out the exact workflow commit on GitHub Actions.
3. Runs `npm ci` and `npm run build` on GitHub Actions.
4. Runs `npm --prefix client ci`.
5. Runs `PS_ROUTES=config/routes.production.json node build-tools/update full`.
6. Copies `play.pokemonshowdown.com/caches/index-new.html` to
   `play.pokemonshowdown.com/index.html`.
7. Packages the built repository, including `node_modules`, into a tarball.
8. Uploads the tarball to `/tmp` on the VM.
9. Extracts it into `/opt/randomon/releases/<sha>`.
10. Links shared runtime files into the release:
    - `/opt/randomon/shared/config/config.js`
    - `/opt/randomon/shared/client-config/config.js`
    - `/opt/randomon/shared/client-config/colors.json`
    - `/opt/randomon/shared/logs`
    - `/opt/randomon/shared/databases`
    - `/opt/randomon/shared/client-static/data`
    - `/opt/randomon/shared/client-static/js-lib`
    - optional shared sprites and audio directories.
11. Ensures `/opt/randomon/client` points at `/opt/randomon/current/client` for
    nginx static-file serving.
12. Atomically switches `/opt/randomon/current` to the new release.
13. Restarts `randomon`.
14. Verifies `systemctl is-active randomon`.
15. Checks `http://127.0.0.1:8000/showdown/info`.
16. Checks `https://randomon.patatoa.com`.
17. Checks `https://randomon.patatoa.com/showdown/info`.
18. Checks representative public static assets from `js/lib/` and `data/`.
19. Opens local and public Showdown WebSockets and requires both
    `|updateuser|` and `|challstr|` startup frames.

The workflow does not run Git commands on the VM and does not build on the VM.
If post-switch health verification fails, it points `/opt/randomon/current`
back to the previous release and restarts `randomon`.

### Failure recovery

The workflow exits nonzero on build, upload, extraction, restart, or health
failure. Failed restart and health-check stages print `systemctl status randomon`
and recent `journalctl -u randomon` output in the workflow logs. If failure
occurs after switching releases, the workflow attempts to restore the previous
release symlink and restart the service.

Common fixes:

- Missing `/opt/randomon/current`: complete the one-time artifact-release setup
  above.
- Public site returns 404 while `/showdown/info` works: confirm
  `/opt/randomon/client` is a symlink to `/opt/randomon/current/client`. nginx
  serves `/opt/randomon/client/play.pokemonshowdown.com`.
- Public site stays on `Loading...`: confirm ignored static assets exist under
  `/opt/randomon/shared/client-static/data` and
  `/opt/randomon/shared/client-static/js-lib`, and that the current release
  links `client/play.pokemonshowdown.com/data` and
  `client/play.pokemonshowdown.com/js/lib` to those shared directories.
- Missing shared config: restore
  `/opt/randomon/shared/config/config.js` or
  `/opt/randomon/shared/client-config/config.js` from the preserved production
  backup.
- Failed artifact extraction: confirm `/opt/randomon/releases` is writable by
  `randomon` and the VM has enough disk space.
- Missing `index-new.html`: rerun the client build command locally on the VM and
  inspect its failure output, or inspect the GitHub Actions client-build logs.
- Failed health checks: inspect `journalctl -u randomon -n 100 --no-pager` and
  nginx logs, then rerun the same workflow after fixing the issue.

### Manual rollback

The workflow automatically restores the previous release when post-switch health
checks fail. For a manual rollback:

```bash
ls -1dt /opt/randomon/releases/*
sudo -u randomon ln -sfn /opt/randomon/releases/<known-good-sha> /opt/randomon/current.rollback
sudo -u randomon mv -Tf /opt/randomon/current.rollback /opt/randomon/current
sudo systemctl restart randomon
curl -fsS http://127.0.0.1:8000/showdown/info
```

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
