#!/bin/bash
# No auto-stash, reset, push, sudo, recording termination, or stored credentials.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false
REPO=$(cd "$(dirname "$0")/.." && pwd)
STATE="${GLACIER_UPDATER_STATE:-$HOME/Library/Application Support/Glacier/Updater}"
MODE=update
SCHEDULED=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --check-only) MODE=check; shift ;;
    --sync-only) MODE=sync; shift ;;
    --scheduled) SCHEDULED=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$STATE"
chmod 700 "$STATE"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"; }
DAY=$(TZ=America/New_York date +%F)
if $SCHEDULED; then
  HOUR=$(TZ=America/New_York date +%H)
  if [ "$HOUR" -lt 13 ]; then exit 0; fi
  if [ -f "$STATE/last-success-day" ] && [ "$(cat "$STATE/last-success-day")" = "$DAY" ]; then exit 0; fi
fi
LOCK="$STATE/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -f "$LOCK/pid" ] && ! kill -0 "$(cat "$LOCK/pid")" 2>/dev/null; then
    rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || { log 'SKIP: another updater holds the lock'; exit 0; }
  else log 'SKIP: another updater holds the lock'; exit 0; fi
fi
printf '%s\n' "$$" > "$LOCK/pid"
SNAPSHOT=''; STAGE=''
cleanup() {
  if [ -n "$SNAPSHOT" ]; then git -C "$REPO" worktree remove --force "$SNAPSHOT" >/dev/null 2>&1 || true; fi
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then rm -rf "$STAGE"; fi
  rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM
cd "$REPO"
if ! git rev-parse --is-inside-work-tree >/dev/null; then
  log 'ERROR: repository is unavailable; keep the checkout outside protected Desktop/Documents folders'; exit 1
fi
if [ "$(git symbolic-ref --quiet --short HEAD || true)" != main ]; then log 'SKIP: checkout is not on main'; exit 0; fi
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then log 'SKIP: local edits/untracked files are preserved'; exit 0; fi
if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ] || [ -f "$(git rev-parse --git-path MERGE_HEAD)" ]; then
  log 'SKIP: git operation in progress'; exit 0
fi
if [ "$MODE" = check ]; then log 'PASS: clean main checkout; sync/build would be allowed'; exit 0; fi
git fetch origin main
if [ "$(git rev-list --count origin/main..HEAD)" -ne 0 ]; then log 'SKIP: local-only commits require the coding agent to publish them'; exit 0; fi
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then log 'SKIP: checkout changed during fetch'; exit 0; fi
git -c rebase.autoStash=false pull --rebase origin main
if [ "$MODE" = sync ]; then log 'PASS: clean main synchronized'; exit 0; fi
[ "$(uname -s)" = Darwin ] || { log 'ERROR: app installation requires macOS'; exit 1; }
REV=$(git rev-parse HEAD)
INSTALLED=/Applications/Glacier.app
if [ -f "$STATE/installed-revision" ] && [ "$(cat "$STATE/installed-revision")" = "$REV" ] && [ -d "$INSTALLED" ] &&
   [ "$(/usr/libexec/PlistBuddy -c 'Print :GlacierSourceRevision' "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)" = "$REV" ]; then
  codesign --verify --deep --strict "$INSTALLED"
  printf '%s\n' "$DAY" > "$STATE/last-success-day"
  log "PASS: installed app already matches $REV"; exit 0
fi
if pgrep -x LectureCaptions >/dev/null || pgrep -x Glacier >/dev/null; then log 'SKIP: Glacier is running; install deferred'; exit 0; fi
SNAPSHOT="$STATE/build-$$"
git worktree add --detach "$SNAPSHOT" "$REV"
log "Building and verifying committed snapshot $REV"
(cd "$SNAPSHOT" && CI=true bash scripts/ci.sh)
codesign --verify --deep --strict "$SNAPSHOT/dist/Glacier.app"
if [ -n "$(git status --porcelain --untracked-files=all)" ] || [ "$(git rev-parse HEAD)" != "$REV" ]; then
  log 'SKIP: local checkout changed during build; installed app retained'; exit 0
fi
if pgrep -x LectureCaptions >/dev/null || pgrep -x Glacier >/dev/null; then log 'SKIP: Glacier opened during build; installed app retained'; exit 0; fi
STAGE="/Applications/.Glacier-stage-$$.app"
ditto "$SNAPSHOT/dist/Glacier.app" "$STAGE"
codesign --verify --deep --strict "$STAGE"
python3 "$SNAPSHOT/scripts/install_app_atomic.py" "$STAGE" "$INSTALLED"
if [ -d "$STAGE" ]; then
  if [ -d "$STATE/previous.app" ]; then rm -rf "$STATE/previous.app"; fi
  mv "$STAGE" "$STATE/previous.app"
fi
STAGE=''
# Refresh the bootstrap for future runs without replacing this process's open file.
cp "$SNAPSHOT/scripts/sync_and_build_local.sh" "$STATE/sync_and_build_local.sh.next"
mv "$STATE/sync_and_build_local.sh.next" "$STATE/sync_and_build_local.sh"
printf '%s\n' "$REV" > "$STATE/installed-revision"
printf '%s\n' "$DAY" > "$STATE/last-success-day"
log "PASS: installed $REV at $INSTALLED (takes effect next launch)"
