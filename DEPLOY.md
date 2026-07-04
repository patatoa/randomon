# Rando Mon — Deployment Plan

## Target

| | |
|---|---|
| **URL** | `https://randomon.patatoa.com` |
| **DNS** | Current registrar (add one A record) — or migrate to Cloudflare (see §DNS) |
| **TLS** | Let's Encrypt via certbot on the VM (free, auto-renews) |
| **Compute** | GCP `e2-micro` — Ubuntu 24.04 LTS (always-free tier) |
| **Server repo** | `github.com/patatoa/randomon` ✓ (already on GitHub) |
| **Client repo** | `github.com/patatoa/randomon-client` ← needs to be created (Step 0) |

---

## Architecture

```
Browser (HTTPS / WSS)
    │
    ▼
nginx on GCP VM  (port 443, TLS via Let's Encrypt)
    ├── GET /*            → static client build (sprites, JS, HTML)
    └── GET /showdown/*   → WebSocket proxy → PS server :8000
```

---

## Step 0 — Push client fork to GitHub  *(one-time, do locally first)*

The client (`client/` submodule) has our custom changes but they only exist locally. We need to push them before anything can be deployed.

```bash
cd /path/to/randomPokemon/client

# 1. Add the patatoa fork as a remote (create the repo on GitHub first: patatoa/randomon-client)
git remote add patatoa https://github.com/patatoa/randomon-client.git

# 2. Commit all local changes
git add -A
git commit -m "Custom client: randomon format, sprites, auth, config"

# 3. Push to the fork
git push patatoa HEAD:main

# 4. Back in the server repo, update the submodule URL and pin it to the new remote
cd ..
git config .gitmodules submodule.client.url https://github.com/patatoa/randomon-client.git
git submodule sync
git add .gitmodules client
git commit -m "Point client submodule to patatoa fork"
git push origin main
```

---

## Step 1 — GCP VM

1. GCP Console → Compute Engine → Create Instance
   - Name: `randomon`
   - Region: pick closest to your users (us-central1 is free-tier eligible)
   - Machine type: **e2-micro**
   - Boot disk: Ubuntu 24.04 LTS, 20GB
   - Firewall: ✓ Allow HTTP, ✓ Allow HTTPS
2. Note the **external IP** — you'll need it for DNS.
3. SSH in (via GCP Console or `gcloud compute ssh randomon`).

---

## Step 2 — DNS

Add one record at your current registrar:

| Type | Name | Value | TTL |
|------|------|-------|-----|
| A | `randomon` | `<GCP external IP>` | 300 |

> **Cloudflare upgrade path (optional later):** If you ever move `patatoa.com` DNS to Cloudflare, you get free CDN + DDoS protection + WebSocket support automatically. But it's not required — certbot works fine with your current registrar.

---

## Step 3 — Server setup

```bash
# As root / sudo on the GCP VM

apt update && apt upgrade -y
apt install -y nginx certbot python3-certbot-nginx git

# Node.js v20 via NodeSource
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# Deploy user
useradd -m -s /bin/bash randomon
```

---

## Step 4 — Clone repos

```bash
su - randomon

# Server
git clone https://github.com/patatoa/randomon.git /opt/randomon/server
cd /opt/randomon/server
git submodule update --init --recursive    # pulls client fork
npm install
node build

# Server config
cp config/config-example.js config/config.js
```

Edit `/opt/randomon/server/config/config.js` — add/set:
```js
exports.bindaddress = '127.0.0.1';
exports.proxyip = ['127.0.0.1'];
exports.noguestsecurity = true;
exports.port = 8000;
```

---

## Step 5 — Build client

> **Critical:** these config files must reflect production values before building.

`/opt/randomon/server/client/config/routes.json`:
```json
{
    "root": "pokemonshowdown.com",
    "client": "randomon.patatoa.com",
    "dex": "dex.pokemonshowdown.com",
    "replays": "replay.pokemonshowdown.com",
    "users": "pokemonshowdown.com/users",
    "teams": "teams.pokemonshowdown.com"
}
```

`/opt/randomon/server/client/config/config.js`:
```js
var Config = Config || {};
Config.version = "0";

Config.defaultserver = {
    id: 'randomon',
    host: 'randomon.patatoa.com',
    port: 443,
    httpport: 443,
    altport: 443,
    registered: true    // CRITICAL — enables wss:// (required from HTTPS pages)
};

Config.customcolors = {};
```

Build:
```bash
cd /opt/randomon/server/client/play.pokemonshowdown.com
npm install
node build
cp caches/index-new.html index.html
```

---

## Step 6 — systemd

`/etc/systemd/system/randomon.service`:
```ini
[Unit]
Description=Rando Mon PS Server
After=network.target

[Service]
Type=simple
User=randomon
WorkingDirectory=/opt/randomon/server
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
# Verify it started:
journalctl -u randomon -n 30
```

---

## Step 7 — nginx

`/etc/nginx/sites-available/randomon`:
```nginx
server {
    listen 80;
    server_name randomon.patatoa.com;

    root /opt/randomon/server/client/play.pokemonshowdown.com;
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

## Step 8 — TLS

DNS must be propagated before running certbot.

```bash
# Verify DNS first:
dig randomon.patatoa.com +short   # should return your GCP IP

# Issue cert:
certbot --nginx -d randomon.patatoa.com

# Auto-renewal is set up automatically by the certbot package
```

Certbot will edit your nginx config to add the SSL block automatically.

---

## Step 9 — Smoke test

```bash
# PS server responding
curl http://127.0.0.1:8000

# HTTPS serving correctly
curl -I https://randomon.patatoa.com

# Check logs
journalctl -u randomon -f
```

Open `https://randomon.patatoa.com` in a browser, open a second tab, challenge yourself — confirm a battle starts with `gen9randomon` and sprites load.

---

## Redeployment

```bash
# Server changes
cd /opt/randomon/server
git pull && node build
systemctl restart randomon

# Client changes
cd /opt/randomon/server/client
git pull
cd play.pokemonshowdown.com
node build && cp caches/index-new.html index.html
# nginx serves files directly — no restart needed
```

---

## Checklist

- [ ] **Step 0**: Create `patatoa/randomon-client` on GitHub, push client changes, update submodule
- [ ] **Step 1**: GCP e2-micro VM created, external IP noted
- [ ] **Step 2**: A record `randomon` → GCP IP added at registrar
- [ ] **Steps 3–8**: VM provisioned, repos cloned, services running
- [ ] **Step 9**: Smoke test passes
