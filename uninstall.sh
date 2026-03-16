#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_ID="com.claude-code-reviewer"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_ID}.plist"

info()  { echo "  [*] $*"; }
ok()    { echo "  [+] $*"; }
warn()  { echo "  [!] $*"; }

echo ""
echo "=== claude-code-reviewer uninstall ==="
echo ""

# ─── Remove Scheduler ─────────────────────────────────────────────────────────

if [[ "$(uname)" == "Darwin" ]]; then
  if [[ -f "$PLIST_PATH" ]]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    ok "Removed launchd plist"
  else
    info "No launchd plist found"
  fi
else
  if crontab -l 2>/dev/null | grep -qF "review.sh"; then
    crontab -l 2>/dev/null | grep -vF "review.sh" | crontab -
    ok "Removed crontab entry"
  else
    info "No crontab entry found"
  fi
fi

# ─── Remove Data Files ────────────────────────────────────────────────────────

echo ""
read -rp "  Remove config.env, reviewed-prs.txt, and logs? [y/N]: " remove_data

if [[ "$(echo "$remove_data" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
  rm -f "$SCRIPT_DIR/config.env"
  rm -f "$SCRIPT_DIR/reviewed-prs.txt"
  rm -f "$SCRIPT_DIR/review.log"
  ok "Removed data files"
else
  info "Kept data files"
fi

echo ""
echo "=== Uninstall complete ==="
echo ""
echo "  The scripts themselves are still in: ${SCRIPT_DIR}"
echo "  To fully remove: rm -rf ${SCRIPT_DIR}"
echo ""
