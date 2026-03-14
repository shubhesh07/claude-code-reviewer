#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
CONFIG_EXAMPLE="$SCRIPT_DIR/config.example.env"
STATE_FILE="$SCRIPT_DIR/reviewed-prs.txt"
REVIEW_SCRIPT="$SCRIPT_DIR/review.sh"
PLIST_ID="com.claude-code-reviewer"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_ID}.plist"

# ─── Auto mode ─────────────────────────────────────────────────────────────────
# --auto flag skips all interactive prompts, uses defaults
AUTO_MODE=false
for arg in "$@"; do
  case "$arg" in
    --auto) AUTO_MODE=true ;;
  esac
done

# ─── Helpers ───────────────────────────────────────────────────────────────────

info()  { echo "  [*] $*"; }
ok()    { echo "  [+] $*"; }
warn()  { echo "  [!] $*"; }
err()   { echo "  [-] $*" >&2; }

check_cmd() {
  if command -v "$1" &>/dev/null; then
    ok "$1 found: $(command -v "$1")"
    return 0
  else
    err "$1 not found."
    return 1
  fi
}

# ─── Step 1: Prerequisites ────────────────────────────────────────────────────

echo ""
echo "=== claude-code-reviewer setup ==="
echo ""
echo "Checking prerequisites..."
echo ""

missing=0

if ! check_cmd claude; then
  info "Install: https://docs.anthropic.com/en/docs/claude-code"
  missing=1
fi

if ! check_cmd jq; then
  info "Install: brew install jq (macOS) or apt install jq (Linux)"
  missing=1
fi

has_gh=false
has_glab=false

if check_cmd gh; then
  has_gh=true
  if gh auth status &>/dev/null; then
    ok "gh authenticated"
  else
    warn "gh installed but not authenticated. Run: gh auth login"
  fi
fi

if check_cmd glab; then
  has_glab=true
  if glab auth status &>/dev/null; then
    ok "glab authenticated"
  else
    warn "glab installed but not authenticated. Run: glab auth login"
  fi
fi

if [[ "$has_gh" == "false" && "$has_glab" == "false" ]]; then
  err "Neither gh nor glab found."
  info "Install gh:   brew install gh   (or https://cli.github.com)"
  info "Install glab: brew install glab (or https://gitlab.com/gitlab-org/cli)"
  missing=1
fi

if [[ "$missing" -eq 1 ]]; then
  echo ""
  err "Missing prerequisites. Install them and re-run ./setup.sh"
  exit 1
fi

# ─── Step 2: Detect Platform ──────────────────────────────────────────────────

echo ""
echo "Detecting platform..."

platform="auto"
if [[ "$has_gh" == "true" ]] && gh auth status &>/dev/null; then
  if [[ "$has_glab" == "true" ]] && glab auth status &>/dev/null; then
    if [[ "$AUTO_MODE" == "true" ]]; then
      platform="github"
      info "Both CLIs detected — defaulting to github (auto mode)"
    else
      echo ""
      echo "  Both GitHub and GitLab CLIs detected."
      echo "  1) GitHub"
      echo "  2) GitLab"
      read -rp "  Select platform [1/2]: " choice
      case "$choice" in
        2) platform="gitlab" ;;
        *) platform="github" ;;
      esac
    fi
  else
    platform="github"
  fi
elif [[ "$has_glab" == "true" ]] && glab auth status &>/dev/null; then
  platform="gitlab"
fi

ok "Platform: ${platform}"

# ─── Step 3: Detect Username ──────────────────────────────────────────────────

echo ""
echo "Detecting username..."

username=""
case "$platform" in
  github)
    username="$(gh api user --jq '.login' 2>/dev/null || true)"
    ;;
  gitlab)
    username="$(glab api user --jq '.username' 2>/dev/null || true)"
    ;;
esac

if [[ -n "$username" ]]; then
  ok "Username: ${username}"
else
  if [[ "$AUTO_MODE" == "true" ]]; then
    warn "Could not auto-detect username. Set USERNAME in config.env manually."
  else
    warn "Could not auto-detect username."
    read -rp "  Enter your username: " username
  fi
fi

# ─── Step 4: Create config.env ─────────────────────────────────────────────────

echo ""
echo "Creating config.env..."

create_config() {
  cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
  sed -i.bak "s/^PLATFORM=auto/PLATFORM=${platform}/" "$CONFIG_FILE"
  sed -i.bak "s/^USERNAME=/USERNAME=${username}/" "$CONFIG_FILE"
  rm -f "${CONFIG_FILE}.bak"
}

if [[ -f "$CONFIG_FILE" ]]; then
  if [[ "$AUTO_MODE" == "true" ]]; then
    info "Keeping existing config.env (auto mode)"
  else
    warn "config.env already exists."
    read -rp "  Overwrite? [y/N]: " overwrite
    if [[ "${overwrite,,}" == "y" ]]; then
      create_config
      ok "config.env updated"
    else
      info "Keeping existing config.env"
    fi
  fi
else
  create_config
  ok "config.env created"
fi

# ─── Step 5: Create State File ─────────────────────────────────────────────────

touch "$STATE_FILE"
ok "State file ready: reviewed-prs.txt"

# ─── Step 6: Make Scripts Executable ───────────────────────────────────────────

chmod +x "$REVIEW_SCRIPT" "$SCRIPT_DIR/uninstall.sh" 2>/dev/null || true
ok "Scripts marked executable"

# ─── Step 7: Install Scheduler ─────────────────────────────────────────────────

echo ""
echo "Setting up scheduled reviews..."

# Read poll interval from config
# shellcheck source=/dev/null
source "$CONFIG_FILE"
interval="${POLL_INTERVAL:-900}"

install_scheduler=true
if [[ "$(uname)" == "Darwin" ]]; then
  # macOS — launchd
  if [[ -f "$PLIST_PATH" ]]; then
    if [[ "$AUTO_MODE" == "true" ]]; then
      info "Keeping existing scheduler (auto mode)"
      install_scheduler=false
    else
      warn "launchd plist already exists."
      read -rp "  Overwrite? [y/N]: " overwrite
      if [[ "${overwrite,,}" != "y" ]]; then
        install_scheduler=false
        info "Keeping existing scheduler"
      fi
    fi
  fi

  if [[ "$install_scheduler" == "true" ]]; then
    cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_ID}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${REVIEW_SCRIPT}</string>
    </array>
    <key>StartInterval</key>
    <integer>${interval}</integer>
    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/review.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/review.log</string>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
PLIST
    ok "Created launchd plist: ${PLIST_PATH}"

    if [[ "$AUTO_MODE" == "true" ]]; then
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
      launchctl load "$PLIST_PATH"
      ok "Scheduler loaded — reviews will run every ${interval}s"
    else
      read -rp "  Load scheduler now? [Y/n]: " load_now
      if [[ "${load_now,,}" != "n" ]]; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        launchctl load "$PLIST_PATH"
        ok "Scheduler loaded — reviews will run every ${interval}s"
      else
        info "Load manually: launchctl load ${PLIST_PATH}"
      fi
    fi
  fi
else
  # Linux — crontab
  cron_entry="*/$((interval / 60)) * * * * ${REVIEW_SCRIPT} >> ${SCRIPT_DIR}/review.log 2>&1"
  if crontab -l 2>/dev/null | grep -qF "$REVIEW_SCRIPT"; then
    if [[ "$AUTO_MODE" == "true" ]]; then
      info "Keeping existing crontab entry (auto mode)"
    else
      warn "Crontab entry already exists."
      read -rp "  Replace? [y/N]: " overwrite
      if [[ "${overwrite,,}" == "y" ]]; then
        (crontab -l 2>/dev/null | grep -vF "$REVIEW_SCRIPT"; echo "$cron_entry") | crontab -
        ok "Crontab updated"
      fi
    fi
  else
    (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
    ok "Crontab entry added: every $((interval / 60)) minutes"
  fi
fi

# ─── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "=== Setup complete ==="
echo ""
echo "  Platform:  ${platform}"
echo "  Username:  ${username}"
echo "  Interval:  ${interval}s ($(( interval / 60 )) min)"
echo "  Config:    ${CONFIG_FILE}"
echo "  Checklist: ${SCRIPT_DIR}/checklist.md"
echo ""
echo "  Manual run:  ./review.sh"
echo "  Edit config: \$EDITOR config.env"
echo "  Customize:   \$EDITOR checklist.md"
echo "  Uninstall:   ./uninstall.sh"
echo ""
