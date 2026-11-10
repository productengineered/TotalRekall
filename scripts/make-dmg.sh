#!/usr/bin/env bash
# Build an ad-hoc signed Release TotalRekall.app and package it as a drag-to-install DMG.
#
# Usage: scripts/make-dmg.sh [-h|--help]
# Output: dist/TotalRekall-<version>.dmg (dist/ is gitignored)
#
# The DMG holds TotalRekall.app plus an /Applications symlink. Signing is ad-hoc, so the
# recipient must use Gatekeeper "Open Anyway" once and re-grant Accessibility after each new build.
# Does not touch /Applications or any installed copy of the app.
set -euo pipefail

APP_NAME="TotalRekall"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${REPO_ROOT}/app/${APP_NAME}.xcodeproj"
DIST="${REPO_ROOT}/dist"

for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

# Fail unless the signed app has the hardened runtime flag and no get-task-allow entitlement.
verify_hardening() {
  local app="$1" info ents
  info="$(codesign -dv "$app" 2>&1)" || die "codesign -dv failed for $app"
  printf '%s\n' "$info" | grep -E '^CodeDirectory' | grep -q 'runtime' \
    || die "hardened runtime flag missing from signature of $app"
  ents="$(codesign -d --entitlements - "$app" 2>&1)" || die "codesign entitlement inspection failed for $app"
  if printf '%s\n' "$ents" | grep -q 'get-task-allow'; then
    die "get-task-allow entitlement present in $app"
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/totalrekall-dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Same ad-hoc settings as scripts/install.sh --adhoc.
SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM= "OTHER_CODE_SIGN_FLAGS=--options runtime")

echo "==> Building Release (ad-hoc)"
xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "${WORK}/derived" "${SIGN_ARGS[@]}" build

BUILT="${WORK}/derived/Build/Products/Release/${APP_NAME}.app"
[[ -d "$BUILT" ]] || die "build product not found at $BUILT"

echo "==> Verifying built signature"
codesign --verify --deep --strict "$BUILT" || die "built app failed signature verification"
verify_hardening "$BUILT"

PLIST="${BUILT}/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
[[ -n "$VERSION" ]] || die "could not read CFBundleShortVersionString"

echo "==> Staging ${APP_NAME} ${VERSION} (${BUILD})"
STAGING="${WORK}/staging"
mkdir -p "$STAGING" "$DIST"
ditto "$BUILT" "${STAGING}/${APP_NAME}.app"
ln -s /Applications "${STAGING}/Applications"

OUT="${DIST}/${APP_NAME}-${VERSION}.dmg"
echo "==> Creating ${OUT}"
hdiutil create -volname "TotalRekall" -srcfolder "$STAGING" -ov -format UDZO "$OUT"

echo "==> DMG ready: ${OUT}"
