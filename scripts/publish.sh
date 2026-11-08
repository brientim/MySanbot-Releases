#!/usr/bin/env bash
# Publish a signed robot APK as a GitHub Release and record it in latest.json.
#
# Usage:
#   scripts/publish.sh <apk> <slug> [notes]
#   DRY_RUN=1 scripts/publish.sh app-release.apk opensdkproxy "Update support"
#
# <slug> names the release tag and asset: <slug>-<versionName> / <slug>-<versionName>.apk.
# The OpenSDK Proxy on each robot reads latest.json from main and installs from apk_url.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/latest.json"
REPO="${MYSANBOT_RELEASES_REPO:-brientim/MySanbot-Releases}"
# Robots only accept in-place updates signed by this certificate (canonical robot key).
EXPECTED_CERT_SHA256="${EXPECTED_CERT_SHA256:-4c94fbf5dce682c2ad3bbaf83f101dc65d6a1debcbf32ddee23b64e5b41e4e57}"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <apk> <slug> [notes]" >&2
  exit 64
fi
APK="$1"
SLUG="$2"
NOTES="${3:-}"

if [[ ! -f "$APK" ]]; then
  echo "ERROR: no such APK: $APK" >&2
  exit 66
fi
if [[ ! "$SLUG" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  echo "ERROR: slug must be lowercase letters, digits, - or _" >&2
  exit 64
fi

newest_tool() {
  ls -1 "$HOME"/Library/Android/sdk/build-tools/*/"$1" 2>/dev/null | sort -V | tail -1
}
AAPT_BIN="${AAPT_BIN:-$(command -v aapt || newest_tool aapt)}"
APKSIGNER_BIN="${APKSIGNER_BIN:-$(command -v apksigner || newest_tool apksigner)}"
for tool in "$AAPT_BIN" "$APKSIGNER_BIN"; do
  if [[ -z "$tool" || ! -x "$tool" ]]; then
    echo "ERROR: aapt and apksigner are required (Android SDK build-tools)" >&2
    exit 69
  fi
done
for tool in jq gh shasum git; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required" >&2; exit 69; }
done

# aapt exits non-zero for APKs whose icon is a framework drawable, after printing the badging lines.
BADGING="$("$AAPT_BIN" dump badging "$APK" 2>/dev/null || true)"
PACKAGE="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$BADGING")"
VERSION_CODE="$(sed -n "s/^package: .*versionCode='\([0-9]*\)'.*/\1/p" <<<"$BADGING")"
VERSION_NAME="$(sed -n "s/^package: .*versionName='\([^']*\)'.*/\1/p" <<<"$BADGING")"
LABEL="$(sed -n "s/^application-label:'\(.*\)'$/\1/p" <<<"$BADGING" | head -1)"
MIN_SDK="$(sed -n "s/^sdkVersion:'\([0-9]*\)'$/\1/p" <<<"$BADGING")"
if [[ -z "$PACKAGE" || -z "$VERSION_CODE" || -z "$VERSION_NAME" ]]; then
  echo "ERROR: could not read package / versionCode / versionName from $APK" >&2
  exit 65
fi

CERT="$("$APKSIGNER_BIN" verify --print-certs "$APK" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -1)"
if [[ "$CERT" != "$EXPECTED_CERT_SHA256" ]]; then
  echo "ERROR: $APK is signed with $CERT, expected the canonical robot key $EXPECTED_CERT_SHA256" >&2
  exit 65
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo '{"schema":1,"generated_at":"","apps":[]}' > "$MANIFEST"
fi
CURRENT_CODE="$(jq -r --arg p "$PACKAGE" '[.apps[] | select(.package == $p) | .version_code][0] // empty' "$MANIFEST")"
if [[ -n "$CURRENT_CODE" && "$VERSION_CODE" -le "$CURRENT_CODE" ]]; then
  echo "ERROR: $PACKAGE versionCode $VERSION_CODE is not higher than published $CURRENT_CODE" >&2
  exit 65
fi

TAG="$SLUG-$VERSION_NAME"
ASSET="$SLUG-$VERSION_NAME.apk"
SHA256="$(shasum -a 256 "$APK" | awk '{print $1}')"
SIZE="$(stat -f%z "$APK" 2>/dev/null || stat -c%s "$APK")"
APK_URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Package:  $PACKAGE ($LABEL)"
echo "Version:  $VERSION_NAME ($VERSION_CODE), was ${CURRENT_CODE:-unpublished}"
echo "Asset:    $ASSET  bytes=$SIZE  sha256=$SHA256"
echo "URL:      $APK_URL"

UPDATED="$(jq \
  --arg package "$PACKAGE" --arg label "$LABEL" --arg slug "$SLUG" \
  --argjson version_code "$VERSION_CODE" --arg version_name "$VERSION_NAME" \
  --arg apk_url "$APK_URL" --arg sha256 "$SHA256" --argjson size "$SIZE" \
  --argjson min_sdk "${MIN_SDK:-21}" --arg notes "$NOTES" --arg now "$NOW" \
  '.schema = 1 | .generated_at = $now
   | .apps = ([.apps[] | select(.package != $package)] + [{
       package: $package, label: $label, slug: $slug,
       version_code: $version_code, version_name: $version_name,
       apk_url: $apk_url, sha256: $sha256, size: $size,
       min_sdk: $min_sdk, notes: $notes, published_at: $now
     }] | sort_by(.package))' "$MANIFEST")"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: would create release $TAG and write:"
  echo "$UPDATED"
  exit 0
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$APK" "$STAGE/$ASSET"

gh release create "$TAG" "$STAGE/$ASSET" \
  --repo "$REPO" \
  --title "$LABEL $VERSION_NAME" \
  --notes "${NOTES:-$LABEL $VERSION_NAME ($PACKAGE, versionCode $VERSION_CODE)}"

echo "$UPDATED" > "$MANIFEST"
git -C "$ROOT" add latest.json
git -C "$ROOT" commit -m "Publish $PACKAGE $VERSION_NAME ($VERSION_CODE)"
git -C "$ROOT" push origin HEAD

echo "Published $TAG. Robots see it on their next update check (or GET /apps/updates?refresh=true)."
