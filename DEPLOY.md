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
/opt/randomon/                            ← git clone of patatoa/randomPokemon
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

git clone https://github.com/patatoa/randomPokemon.git /opt/randomon
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

```bash
# As the randomon user.
su - randomon
cd /opt/randomon

git pull

# Reinstall dependencies after pulls that change package-lock.json.
npm ci
node build

cd client
npm ci

# Rebuild client.
PS_ROUTES=config/routes.production.json node build-tools/update full
cp play.pokemonshowdown.com/caches/index-new.html play.pokemonshowdown.com/index.html
exit

# Restart as root; nginx picks up static files automatically.
systemctl restart randomon
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
