# Rando Mon — Deployment

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
│   │   ├── routes.json                   ← asset URL roots (committed as localhost:8080 — overwritten in Step 6b)
│   │   └── routes.production.json        ← production routes (committed; cp'd over routes.json in Step 6b)
│   └── play.pokemonshowdown.com/         ← nginx serves this directory as the website root
│       ├── index.html                    ← generated: cp caches/index-new.html index.html
│       ├── sprites/                      ← downloaded by scripts/download-assets.sh (gitignored)
│       ├── data/                         ← built: graphics.js, battledata.js, etc.
│       └── js/                           ← built: client JS bundle
│
└── scripts/
    └── download-assets.sh                ← downloads all sprites + binary assets from PS CDN
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
# Create the instance (e2-micro is free-tier eligible in us-central1)
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
apt install -y nginx certbot python3-certbot-nginx git

# Node.js 20 (LTS)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# Service user
useradd -m -s /bin/bash randomon
```

---

## Step 4 — Clone repo and install deps

```bash
su - randomon

git clone https://github.com/patatoa/randomPokemon.git /opt/randomon
cd /opt/randomon

# Server deps
npm install

# Client deps
cd client
npm install
cd ..
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
    host: 'randomon.patatoa.com',
    port: 443, httpport: 443, altport: 443,
    registered: true   // enables wss:// — required for HTTPS pages
};
```

**6b. Install production routes** — the committed `routes.json` has `localhost:8080`; replace it with the production copy:

```bash
cp /opt/randomon/client/config/routes.production.json /opt/randomon/client/config/routes.json
```

This controls the URL prefix for all sprites and assets (`//randomon.patatoa.com/sprites/...`). The `cp` keeps `routes.json` untracked in git (no dirty working tree on future `git pull`).

**6c. Build the client:**

```bash
cd /opt/randomon/client
node build-tools/update full
# "full" is required — compiles graphics.js and chat-formatter.js; regular build skips them

cp play.pokemonshowdown.com/caches/index-new.html play.pokemonshowdown.com/index.html
```

---

## Step 7 — Assets (sprites, FX, data files)

Sprites are gitignored (too large for git). They live in a GCS bucket you control — no
runtime dependency on the PS CDN.

### 7a — One-time: create and populate the bucket *(do this locally, not on the VM)*

You need `download-assets.sh --cdn` to have already run locally so the files exist under
`client/play.pokemonshowdown.com/`. Then:

```bash
# From the repo root on your local machine
bash scripts/upload-assets-to-gcs.sh
# Creates gs://randomon-assets and pushes sprites/, fx/, and data/ into it.
# Set RANDOMON_BUCKET=gs://other-name to use a different bucket name.
```

This is a one-time step. Re-run it only when the pool changes (new Pokémon added to roster).

### 7b — Every VM setup: pull from bucket

```bash
# On the VM, from /opt/randomon
bash scripts/download-assets.sh
# Pulls assets from gs://randomon-assets via gcloud storage rsync.
```

**VM authentication:** the e2-micro has a default service account. Grant it read access
to the bucket (run this once from any machine that has GCP permissions):

```bash
# Get the VM's default service account email (format: <project-number>-compute@developer.gserviceaccount.com)
PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='get(projectNumber)')
SA_EMAIL="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

gcloud storage buckets add-iam-policy-binding gs://randomon-assets \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectViewer"
```

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
ExecStart=/usr/bin/node pokemon-showdown 8000
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
cd /opt/randomon

# Pull latest
git pull

# Rebuild server
node build

# Rebuild client (only if client src changed)
cd client
node build-tools/update full
cp play.pokemonshowdown.com/caches/index-new.html play.pokemonshowdown.com/index.html
cd ..

# Restart server; nginx picks up static files automatically
systemctl restart randomon
```

---

## Checklist

- [ ] Step 1: GCP e2-micro VM created, external IP noted
- [ ] Step 2: DNS A record `randomon` → GCP IP propagated
- [ ] Steps 3–4: VM provisioned, repo cloned, deps installed
- [ ] Step 5: `/opt/randomon/config/config.js` created
- [ ] Step 6: Client config copied, routes.json updated, client built, index.html in place
- [ ] Step 7a: GCS bucket created and populated (`scripts/upload-assets-to-gcs.sh`) — one-time, local
- [ ] Step 7b: Assets pulled on VM (`scripts/download-assets.sh`)
- [ ] Step 8: systemd service running (`systemctl status randomon`)
- [ ] Step 9: nginx configured and reloaded
- [ ] Step 10: TLS cert issued (`certbot --nginx`)
- [ ] Step 11: Smoke test passes — Battle button visible, match starts
