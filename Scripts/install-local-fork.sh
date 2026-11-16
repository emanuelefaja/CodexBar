#!/usr/bin/env bash
# Build first, then replace the app while retaining a private rollback copy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# The launch smoke test denies all reads under the checkout, including TMPDIR.
# Keep its relocated app on disk outside the checkout, not under ROOT/tmp.
umask 077
export TMPDIR="$HOME/Library/Caches/CodexBarForkBuild/tmp"
mkdir -p "$TMPDIR"
export CODEXBAR_SIGNING=adhoc
./Scripts/package_app.sh release

APP=/Applications/CodexBar.app
STAGE=/Applications/.CodexBar-local-fork.app
BACKUP_ROOT="$HOME/Library/Application Support/CodexBar/ForkBackups"
umask 077
mkdir -p "$BACKUP_ROOT"
BACKUP="$(mktemp -d "$BACKUP_ROOT/install-XXXXXXXX")"
if [[ -e "$STAGE" ]]; then
  echo "Staging path already exists: $STAGE. Inspect it before retrying." >&2
  exit 1
fi
ditto "$ROOT/CodexBar.app" "$STAGE"
codesign --verify --deep --strict "$STAGE"

# Save preferences/config without printing any credentials.
defaults export com.steipete.codexbar "$BACKUP/preferences.plist" 2>/dev/null || true
for CONFIG in "$HOME/.config/codexbar/config.json" "$HOME/.codexbar/config.json"; do
  if [[ -f "$CONFIG" ]]; then
    NAME=xdg-config.json
    [[ "$CONFIG" == "$HOME/.codexbar/config.json" ]] && NAME=legacy-config.json
    cp -p "$CONFIG" "$BACKUP/$NAME"
    chmod 600 "$BACKUP/$NAME"
  fi
done
if pgrep -x CodexBar >/dev/null; then
  osascript -e 'tell application id "com.steipete.codexbar" to quit'
  for _ in {1..15}; do
    pgrep -x CodexBar >/dev/null || break
    sleep 1
  done
  if pgrep -x CodexBar >/dev/null; then
    echo "CodexBar did not quit. Existing app is unchanged; staging remains at $STAGE." >&2
    exit 1
  fi
fi
if [[ -e "$APP" ]]; then
  mv "$APP" "$BACKUP/CodexBar.app"
fi
if ! mv "$STAGE" "$APP"; then
  [[ ! -e "$APP" && -d "$BACKUP/CodexBar.app" ]] && mv "$BACKUP/CodexBar.app" "$APP"
  exit 1
fi
launch_ok=1
open -n "$APP" || launch_ok=0
PID=""
for _ in {1..10}; do
  PID="$(pgrep -f '^/Applications/CodexBar\.app/Contents/MacOS/CodexBar( |$)' || true)"
  [[ -n "$PID" ]] && break
  sleep 1
done
if [[ -z "$PID" ]]; then
  launch_ok=0
else
  for _ in {1..30}; do
    if ! kill -0 "$PID" 2>/dev/null; then
      launch_ok=0
      break
    fi
    sleep 1
  done
fi
if [[ "$launch_ok" != "1" ]]; then
  echo "Installed fork failed its normal-startup check; restoring the previous app." >&2
  # Do not leave a partial launch running while restoring its executable.
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    echo "A fork process is still running; stop it before restoring from $BACKUP." >&2
    exit 1
  fi
  mv "$APP" "$BACKUP/failed-fork.app"
  if [[ -d "$BACKUP/CodexBar.app" ]]; then
    ditto "$BACKUP/CodexBar.app" "$APP"
    open -n "$APP"
  fi
  exit 1
fi
printf 'Installed local fork; normal startup survived 30 seconds. Rollback app and private settings: %s\n' "$BACKUP"
printf 'A changed signature may require renewed browser/Full Disk Access permission.\n'
