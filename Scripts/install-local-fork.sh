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
open -n "$APP"
printf 'Installed local fork. Rollback app and private settings: %s\n' "$BACKUP"
printf 'A changed signature may require renewed browser/Full Disk Access permission.\n'
