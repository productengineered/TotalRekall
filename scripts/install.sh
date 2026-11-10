#!/usr/bin/env bash
# Build the signed Release configuration, replace /Applications/TotalRekall.app, and relaunch.
#
# Team ID: env var DEVELOPMENT_TEAM, else app/Config/Local.xcconfig (untracked; see Local.xcconfig.example).
# Signing is required by default. A stable signature keeps the macOS Accessibility grant across reinstalls.
# Pass --adhoc to build with ad-hoc signing instead (the grant may be lost on every reinstall).
set -euo pipefail

APP_NAME="TotalRekall"
DEST="/Applications/${APP_NAME}.app"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${REPO_ROOT}/app/${APP_NAME}.xcodeproj"
LOCAL_XCCONFIG="${REPO_ROOT}/app/Config/Local.xcconfig"

ADHOC=0
for arg in "$@"; do
  case "$arg" in
    --adhoc) ADHOC=1 ;;
    -h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}"; exit 0 ;;
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

SIGN_ARGS=()
if [[ "$ADHOC" -eq 1 ]]; then
  cat >&2 <<'MSG'
WARNING: --adhoc build. Ad-hoc signatures change with every build, so macOS may drop the
Accessibility (and other TCC) permission granted to TotalRekall on each reinstall. You will
likely need to re-grant it in System Settings > Privacy & Security > Accessibility.
MSG
  SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM= "OTHER_CODE_SIGN_FLAGS=--options runtime")
else
  TEAM="${DEVELOPMENT_TEAM:-}"
  if [[ -z "$TEAM" && -f "$LOCAL_XCCONFIG" ]]; then
    TEAM="$(sed -n -E 's|^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Za-z0-9]+).*|\1|p' "$LOCAL_XCCONFIG" | head -n1)"
  fi
  if [[ -z "$TEAM" || "$TEAM" == "XXXXXXXXXX" ]]; then
    die "no development team ID found.
  Set it via either:
    - copy app/Config/Local.xcconfig.example to app/Config/Local.xcconfig and fill in DEVELOPMENT_TEAM, or
    - export DEVELOPMENT_TEAM=<team id>
  A signing identity is required so the Accessibility grant survives reinstalls.
  (To build anyway with ad-hoc signing, run: scripts/install.sh --adhoc)"
  fi
  if ! security find-identity -v -p codesigning | grep -q "Apple Development"; then
    die "no valid 'Apple Development' code-signing identity in the keychain.
  Sign in to Xcode > Settings > Accounts and create/download an Apple Development certificate,
  then check: security find-identity -v -p codesigning
  (To build anyway with ad-hoc signing, run: scripts/install.sh --adhoc)"
  fi
  SIGN_ARGS=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic "OTHER_CODE_SIGN_FLAGS=--options runtime")
fi

DERIVED="$(mktemp -d "${TMPDIR:-/tmp}/totalrekall-install.XXXXXX")"
trap 'rm -rf "$DERIVED"' EXIT

echo "==> Building Release"
xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$DERIVED" "${SIGN_ARGS[@]}" build

BUILT="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
[[ -d "$BUILT" ]] || die "build product not found at $BUILT"

echo "==> Verifying built signature"
codesign --verify --deep --strict "$BUILT" || die "built app failed signature verification"
verify_hardening "$BUILT"

echo "==> Quitting running ${APP_NAME}"
if pgrep -x "$APP_NAME" >/dev/null; then
  osascript -e "quit app \"${APP_NAME}\"" || true
  for _ in {1..20}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.5; done
  if pgrep -x "$APP_NAME" >/dev/null; then
    pkill -x "$APP_NAME" || true
    for _ in {1..20}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.5; done
  fi
  if pgrep -x "$APP_NAME" >/dev/null; then
    die "${APP_NAME} did not exit within 10s; quit it manually and re-run (refusing to race the instance lock)"
  fi
fi

echo "==> Installing to ${DEST}"
# Never delete the installed app until the replacement is staged and verified.
STAGE="$(dirname "$DEST")/.${APP_NAME}.app.new"
BACKUP="$(dirname "$DEST")/.${APP_NAME}.app.bak"
rollback() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -rf "$STAGE"
    if [[ -d "$BACKUP" ]]; then
      echo "error: install failed; restoring previous ${APP_NAME}.app" >&2
      rm -rf "$DEST"
      mv "$BACKUP" "$DEST" || echo "error: could not restore backup at $BACKUP" >&2
    fi
  fi
  rm -rf "$DERIVED"
}
trap rollback EXIT

rm -rf "$STAGE" "$BACKUP"
ditto "$BUILT" "$STAGE"
codesign --verify --deep --strict "$STAGE" || die "staged app failed signature verification"
verify_hardening "$STAGE"
if [[ -d "$DEST" ]]; then mv "$DEST" "$BACKUP"; fi
mv "$STAGE" "$DEST"

echo "==> Installed signature"
codesign -dv "$DEST" 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|Signature' || true
codesign --verify --deep --strict "$DEST" || die "installed app failed signature verification"
rm -rf "$BACKUP"

echo "==> Launching"
open "$DEST"
