#!/usr/bin/env bash
set -euo pipefail

# Local Nightly publisher to bypass GitHub Actions billing limits
# Requirements:
#  - JDK 17 on PATH
#  - Android SDK + NDK 28.2.13676358 installed and ANDROID_HOME/ANDROID_SDK_ROOT set
#  - GitHub CLI (gh) authenticated with GH_TOKEN or via 'gh auth login'
# Optional env:
#  - REPO_SLUG=owner/repo (auto-detected from git remote if unset)
#  - TARGET_REF=branch-or-sha (defaults to current HEAD)

ROOT_DIR="$(cd "$(dirname "$0")"/.. && pwd)"
cd "$ROOT_DIR"

echo "[nightly] Using repository root: $ROOT_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[nightly] Missing required command: $1"; exit 1; }
}

need_cmd git
need_cmd ./gradlew
need_cmd gh
need_cmd md5sum

# Derive repo slug from git remote if not provided
if [[ -z "${REPO_SLUG:-}" ]]; then
  origin_url="$(git config --get remote.origin.url || true)"
  if [[ "$origin_url" =~ ^git@github.com:(.+)\.git$ ]]; then
    REPO_SLUG="${BASH_REMATCH[1]}"
  elif [[ "$origin_url" =~ ^https://github.com/([^/]+/[^/]+)(\.git)?$ ]]; then
    REPO_SLUG="${BASH_REMATCH[1]}"
  else
    echo "[nightly] Could not auto-detect REPO_SLUG from remote.origin.url ($origin_url)" >&2
    echo "[nightly] Set REPO_SLUG=owner/repo in the environment." >&2
    exit 1
  fi
fi

TARGET_REF="${TARGET_REF:-$(git rev-parse --abbrev-ref HEAD)}"
echo "[nightly] Repo: $REPO_SLUG @ $TARGET_REF"

OUT_DIR="$ROOT_DIR/out"
mkdir -p "$OUT_DIR"

echo "[nightly] Building APKs..."
./gradlew :app_pojavlauncher:assembleFullDebug :app_pojavlauncher:assembleNoruntimeDebug -x lint -x test

FULL_APK_SRC="app_pojavlauncher/build/outputs/apk/full/debug/app_pojavlauncher-full-debug.apk"
NORUNTIME_APK_SRC="app_pojavlauncher/build/outputs/apk/noruntime/debug/app_pojavlauncher-noruntime-debug.apk"

[[ -f "$FULL_APK_SRC" ]] || { echo "[nightly] Missing built APK: $FULL_APK_SRC"; exit 1; }
[[ -f "$NORUNTIME_APK_SRC" ]] || { echo "[nightly] Missing built APK: $NORUNTIME_APK_SRC"; exit 1; }

APP_DEBUG="$OUT_DIR/app-debug.apk"
APP_DEBUG_NR="$OUT_DIR/app-debug-noruntime.apk"

cp -f "$FULL_APK_SRC" "$APP_DEBUG"
cp -f "$NORUNTIME_APK_SRC" "$APP_DEBUG_NR"

echo "[nightly] Generating checksums..."
md5sum "$APP_DEBUG" > "$OUT_DIR/app-debug.md5"
md5sum "$APP_DEBUG_NR" > "$OUT_DIR/app-debug-noruntime.md5"

echo "[nightly] Preparing GitHub Release 'nightly'..."
set +e
gh release view nightly --repo "$REPO_SLUG" >/dev/null 2>&1
has_release=$?
set -e

if [[ $has_release -ne 0 ]]; then
  echo "[nightly] Creating release 'nightly'..."
  gh release create nightly \
    --repo "$REPO_SLUG" \
    --title "Nightly" \
    --notes "Automated nightly build" \
    --prerelease \
    --target "$TARGET_REF" \
    "$APP_DEBUG" "$OUT_DIR/app-debug.md5" \
    "$APP_DEBUG_NR" "$OUT_DIR/app-debug-noruntime.md5"
else
  echo "[nightly] Updating release 'nightly' (clobbering assets)..."
  gh release upload nightly \
    --repo "$REPO_SLUG" \
    --clobber \
    "$APP_DEBUG" "$OUT_DIR/app-debug.md5" \
    "$APP_DEBUG_NR" "$OUT_DIR/app-debug-noruntime.md5"
fi

echo "[nightly] Done. Download URLs:"
echo "  https://github.com/$REPO_SLUG/releases/download/nightly/app-debug.apk"
echo "  https://github.com/$REPO_SLUG/releases/download/nightly/app-debug-noruntime.apk"

