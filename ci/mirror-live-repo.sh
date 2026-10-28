#!/usr/bin/env bash
# Copy the published OSTree repo (every ref, commit and signature) into a new
# local repo, then regenerate its signed summary and deltas. Commit IDs stay
# the same, so clients see no update.
#
# Usage: mirror-live-repo.sh REPO_URL DEST_DIR GPG_KEY_ID
set -euo pipefail

url=$1 dest=$2 key=$3
pub=$(mktemp)
gpg --export "$key" > "$pub"

rm -rf "$dest"
ostree --repo="$dest" init --mode=archive-z2
ostree --repo="$dest" remote add --gpg-import="$pub" live "$url"
ostree --repo="$dest" pull --mirror live
ostree --repo="$dest" remote delete live
rm -f "$pub"

flatpak build-update-repo --generate-static-deltas --prune \
  --title="Parsec (auto-built)" --gpg-sign="$key" "$dest"
ostree --repo="$dest" refs
