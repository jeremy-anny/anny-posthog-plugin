#!/usr/bin/env bash
#
# Rebuilds the mirror from upstream.
#
# Deliberately not a merge: the tree is thrown away and recreated from a fresh
# upstream checkout, then the patches are re-applied. There is never a conflict
# to resolve -- either every patch still lands, or the sync fails and tells you
# which anchor moved.
#
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=config.env
source .anny/config.env

command -v jq >/dev/null || { echo "sync: jq required" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git clone --depth 1 --branch "$UPSTREAM_REF" --quiet "$UPSTREAM_REPO" "$TMP/up"
SHA=$(git -C "$TMP/up" rev-parse HEAD)
rm -rf "$TMP/up/.git"

# Everything except .git and our own directory is upstream's to define.
find . -mindepth 1 -maxdepth 1 ! -name .git ! -name .anny -exec rm -rf {} +
cp -a "$TMP/up/." .

.anny/apply-patches.sh
printf '%s\n' "$SHA" > .anny/UPSTREAM_SHA

echo "sync: ${UPSTREAM_REPO}@${SHA}"
