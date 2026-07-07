#!/usr/bin/env bash
# One-time: upload local assets to your GCS bucket.
# Run this after download-assets.sh --cdn has populated client/play.pokemonshowdown.com/.
# After this, future VM deployments use `bash scripts/download-assets.sh` (no --cdn needed).
#
# Set RANDOMON_BUCKET to the asset bucket, for example:
#   RANDOMON_BUCKET=gs://your-randomon-assets bash scripts/upload-assets-to-gcs.sh
#
# Run from the repo root.

set -e

if [ -z "${RANDOMON_BUCKET:-}" ]; then
  echo "ERROR: RANDOMON_BUCKET must be set, for example:"
  echo "       RANDOMON_BUCKET=gs://your-randomon-assets bash scripts/upload-assets-to-gcs.sh"
  exit 1
fi

BUCKET="$RANDOMON_BUCKET"
CLIENT="client/play.pokemonshowdown.com"

if command -v gcloud &>/dev/null && gcloud storage --help &>/dev/null; then
  bucket_create() {
    gcloud storage buckets create "$BUCKET" --location=us-central1 2>/dev/null || true
  }
  public_read() {
    gcloud storage buckets add-iam-policy-binding "$BUCKET" \
      --member=allUsers \
      --role=roles/storage.objectViewer >/dev/null
  }
  storage_rsync() {
    gcloud storage rsync -r "$1" "$2" "${@:3}"
  }
elif command -v gsutil &>/dev/null; then
  bucket_create() {
    gsutil mb -l us-central1 "$BUCKET" 2>/dev/null || true
  }
  public_read() {
    gsutil iam ch allUsers:objectViewer "$BUCKET" >/dev/null
  }
  storage_rsync() {
    local exclude_args=()
    if [ "${3:-}" = "--exclude=battledata\\.js|graphics\\.js" ]; then
      exclude_args=(-x '.*(battledata\.js|graphics\.js)$')
    fi
    gsutil -m rsync -r "${exclude_args[@]}" "$1" "$2"
  }
else
  echo "ERROR: gcloud storage or gsutil not found. Install the Google Cloud SDK."
  exit 1
fi

echo "==> Creating bucket ${BUCKET} (safe if it already exists)..."
bucket_create

echo "==> Making bucket objects publicly readable..."
public_read

echo "==> Uploading sprites..."
storage_rsync "$CLIENT/sprites" "${BUCKET}/sprites"

echo "==> Uploading FX assets..."
storage_rsync "$CLIENT/fx" "${BUCKET}/fx"

echo "==> Uploading data files (excluding built files)..."
# battledata.js and graphics.js are built from source on the VM — don't cache them here
storage_rsync "$CLIENT/data" "${BUCKET}/data" \
  --exclude="battledata\.js|graphics\.js"

echo "==> Done. Bucket ${BUCKET} is ready for VM deployments."
echo "    VM setup: bash scripts/download-assets.sh   (no --cdn flag)"
