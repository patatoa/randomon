# Randomon

Randomon is a small, self-hosted Pokemon Showdown fork for playing one custom
format: **[Gen 9] Rando Mon**.

The format gives each player a random team drawn from a curated 457-Pokemon
pool. Box legendaries are excluded, and sets/Tera types are hand-tuned by role.
The public site is intended to be simple: choose a local name, find or challenge
an opponent, and play Randomon.

## Project Status

This repo is a working fork, not a clean upstream Pokemon Showdown distribution.
It includes both the server and the web client so local development and the
deployed site can use the same codebase.

Current production target:

- Site: `https://randomon.patatoa.com`
- Server format: `gen9randomon`
- Static assets: served from the same site after being populated from the
  Randomon GCS asset bucket
- Deployment guide: [DEPLOY.md](./DEPLOY.md)

## What Is Customized

- Custom format definition: [config/custom-formats.ts](./config/custom-formats.ts)
- Custom game data/mod: [data/mods/randomon](./data/mods/randomon)
- Main menu battle button: [client/play.pokemonshowdown.com/src/panel-mainmenu.tsx](./client/play.pokemonshowdown.com/src/panel-mainmenu.tsx)
- Direct challenge defaults: [client/play.pokemonshowdown.com/src/panel-chat.tsx](./client/play.pokemonshowdown.com/src/panel-chat.tsx)
- Production client config template: [client/config/config.production.js](./client/config/config.production.js)
- Asset helpers: [scripts/download-assets.sh](./scripts/download-assets.sh) and
  [scripts/upload-assets-to-gcs.sh](./scripts/upload-assets-to-gcs.sh)

## Local Development

Install dependencies from the repo root:

```bash
npm ci
cd client
npm ci
cd ..
```

Build the server and client:

```bash
node build
cd client
node build-tools/update full
cp play.pokemonshowdown.com/caches/index-new.html play.pokemonshowdown.com/index.html
cd ..
```

Start the Pokemon Showdown server:

```bash
node pokemon-showdown --skip-build 8000
```

Serve the client from `client/play.pokemonshowdown.com` on port 8080:

```bash
cd client/play.pokemonshowdown.com
npx http-server -p 8080
```

Then open:

```text
http://localhost:8080
```

The local client routes are configured for `localhost:8080` and the local server
uses port `8000`.

## Assets

Sprites, battle effects, and generated client data are too large or too noisy to
track directly in git. They are expected under:

```text
client/play.pokemonshowdown.com/sprites/
client/play.pokemonshowdown.com/fx/
client/play.pokemonshowdown.com/data/
```

Use the helper scripts from the repo root:

```bash
# Pull from the configured Randomon asset bucket.
RANDOMON_BUCKET=gs://<bucket-name> bash scripts/download-assets.sh

# Rebuild/populate the bucket after local asset changes.
RANDOMON_BUCKET=gs://<bucket-name> bash scripts/upload-assets-to-gcs.sh
```

For a first-time local bootstrap without the bucket, the download script can pull
from the Pokemon Showdown CDN:

```bash
bash scripts/download-assets.sh --cdn
```

Do not commit bucket names, project IDs, or other deployment-specific values to
the public repo.

## Deployment

Deployment is documented in [DEPLOY.md](./DEPLOY.md). The current production
shape is:

- GCP Compute Engine VM
- nginx for HTTPS/static files/WebSocket proxying
- systemd service running `node pokemon-showdown --skip-build 8000`
- public GCS bucket for bulk static assets
- DNS managed outside Cloudflare

The VM's live server config is intentionally gitignored and created at:

```text
/opt/randomon/config/config.js
```

## Upstream Pokemon Showdown

Randomon is based on Pokemon Showdown. Most simulator, protocol, battle, and
client architecture documentation from upstream still applies:

- [ARCHITECTURE.md](./ARCHITECTURE.md)
- [PROTOCOL.md](./PROTOCOL.md)
- [sim/README.md](./sim/README.md)
- [server/README.md](./server/README.md)
- [client/README.md](./client/README.md)

Upstream Pokemon Showdown server code is MIT licensed. The bundled client code
retains its upstream license. See [LICENSE](./LICENSE) and the client package
metadata for details.
