#!/usr/bin/env bash
# One-time: upload local assets to your GCS bucket.
# Run this after download-assets.sh --cdn has populated client/play.pokemonshowdown.com/.
# After this, future VM deployments use `bash scripts/download-assets.sh` (no --cdn needed).
#
# Run from the repo root.

set -e

BUCKET="${RANDOMON_BUCKET:-gs://randomon-assets}"
CLIENT="client/play.pokemonshowdown.com"

if ! command -v gcloud &>/dev/null; then
  echo "ERROR: gcloud not found. Install the Google Cloud SDK."
  exit 1
fi

echo "==> Creating bucket ${BUCKET} (safe if it already exists)..."
gcloud storage buckets create "$BUCKET" --location=us-central1 2>/dev/null || true

echo "==> Uploading sprites..."
gcloud storage rsync -r "$CLIENT/sprites" "${BUCKET}/sprites"

echo "==> Uploading FX assets..."
gcloud storage rsync -r "$CLIENT/fx" "${BUCKET}/fx"

echo "==> Uploading data files (excluding built files)..."
# battledata.js and graphics.js are built from source on the VM — don't cache them here
gcloud storage rsync -r "$CLIENT/data" "${BUCKET}/data" \
  --exclude="battledata\.js|graphics\.js"

echo "==> Done. Bucket ${BUCKET} is ready for VM deployments."
echo "    VM setup: bash scripts/download-assets.sh   (no --cdn flag)"
