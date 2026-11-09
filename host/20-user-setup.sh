#!/usr/bin/env bash
# 20-user-setup.sh: tools for the dev user (not root).
# Usage: GIT_NAME='Your Name' GIT_EMAIL='you@example.com' bash 20-user-setup.sh
# Optional variables: PW_MCP_VERSION=0.0.84  SKIP_GH_LOGIN=1
#                     INSTALL_GATEHAUL=1 (optional gatehaul CLI)  GATEHAUL_VERSION=v0.1.0-alpha.4
#                     GATEHAUL_REPO=camilbenameur/gatehaul
# The script can be re-run safely.
#
# arm64 hosts are best effort and NOT tested end to end: there is no Google Chrome for
# Linux arm64, so Playwright's own Chromium is installed and used instead.
set -euo pipefail

INSTALL_GATEHAUL="${INSTALL_GATEHAUL:-0}"
GATEHAUL_VERSION="${GATEHAUL_VERSION:-v0.1.0-alpha.4}"
GATEHAUL_REPO="${GATEHAUL_REPO:-camilbenameur/gatehaul}"
# Pinned @playwright/mcp version: bump it on purpose, not on every session.
PW_MCP_VERSION="${PW_MCP_VERSION:-0.0.84}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warning] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run as the dev user, not as root."
ARCH="$(dpkg --print-architecture)"
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/dev" "$HOME/worktrees" "$HOME/.local/bin" "$HOME/.claude"
export PATH="$HOME/.local/bin:$PATH"

# ~/.local/bin at the TOP of ~/.bashrc: Ubuntu's .bashrc returns right away for
# non-interactive shells, so a line appended at the end would never be read by the
# commands that Claude runs.
log "PATH"
MARK='# devbox: PATH'
if ! grep -qF "$MARK" "$HOME/.bashrc" 2>/dev/null; then
  tmp="$(mktemp)"
  { echo "$MARK"; echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'; echo; cat "$HOME/.bashrc" 2>/dev/null || true; } > "$tmp"
  mv "$tmp" "$HOME/.bashrc"
fi

log "Guard: no Anthropic API key (otherwise usage is billed to the API instead of the subscription)"
if grep -qs 'ANTHROPIC_API_KEY' "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" /etc/environment; then
  warn "ANTHROPIC_API_KEY is set in a startup file: remove it."
fi

log "git"
[ -n "${GIT_NAME:-}" ]  && git config --global user.name "$GIT_NAME"
[ -n "${GIT_EMAIL:-}" ] && git config --global user.email "$GIT_EMAIL"
git config --global init.defaultBranch main
git config --global fetch.prune true
git lfs install --skip-repo >/dev/null

log "uv (Python)"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
fi
uv --version

log "Claude Code CLI (for tmux and Remote Control; the desktop app installs its own copy)"
if ! command -v claude >/dev/null 2>&1; then
  curl -fsSL https://claude.ai/install.sh | bash
fi
claude --version || warn "claude not found in PATH"

if [ "$INSTALL_GATEHAUL" = "1" ]; then
  log "gatehaul $GATEHAUL_VERSION (optional, verified with SHA256SUMS)"
  asset="gatehaul_${GATEHAUL_VERSION}_linux_${ARCH}"
  current="$(gatehaul --version 2>/dev/null || true)"
  if [[ "$current" != *"${GATEHAUL_VERSION}"* ]]; then
    tmpd="$(mktemp -d)"
    base="https://github.com/${GATEHAUL_REPO}/releases/download/${GATEHAUL_VERSION}"
    curl -fsSL -o "$tmpd/$asset" "$base/$asset"
    curl -fsSL -o "$tmpd/SHA256SUMS" "$base/SHA256SUMS"
    ( cd "$tmpd" && grep -E "[ *]${asset}\$" SHA256SUMS | sha256sum -c - ) || { rm -rf "$tmpd"; die "gatehaul SHA256 checksum mismatch: binary not installed."; }
    install -m 755 "$tmpd/$asset" "$HOME/.local/bin/gatehaul"
    rm -rf "$tmpd"
  fi
  gatehaul --version
else
  log "gatehaul: skipped (optional, set INSTALL_GATEHAUL=1 to install it)"
fi

log "GitHub CLI: login"
if gh auth status >/dev/null 2>&1; then
  echo "Already logged in."
elif [ "${SKIP_GH_LOGIN:-0}" = "1" ]; then
  warn "gh login skipped: run 'gh auth login' then 'gh auth setup-git' later."
else
  echo "Open the link shown on your computer and enter the code."
  gh auth login --hostname github.com --git-protocol https --web
fi
gh auth status >/dev/null 2>&1 && gh auth setup-git

log "Playwright MCP (headless Chrome, one isolated browser per Claude session)"
PW_ARGS=(--headless --isolated)
if [ "$ARCH" = "amd64" ]; then
  PW_ARGS+=(--browser chrome)
else
  # arm64 (best effort, not tested end to end): Chromium from the playwright version
  # bundled with the pinned MCP.
  PW_VERSION="$(npm view "@playwright/mcp@${PW_MCP_VERSION}" dependencies.playwright)"
  [ -n "$PW_VERSION" ] || die "Could not find the playwright version for @playwright/mcp@${PW_MCP_VERSION}"
  npx -y "playwright@${PW_VERSION}" install chromium
  CHROMIUM="$(ls -d "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux*/chrome 2>/dev/null | sort -V | tail -n1 || true)"
  [ -n "$CHROMIUM" ] || die "Playwright Chromium not found after installation."
  PW_ARGS+=(--executable-path "$CHROMIUM")
fi
npx -y "@playwright/mcp@${PW_MCP_VERSION}" --help >/dev/null   # caches the package
if claude mcp get playwright >/dev/null 2>&1; then
  claude mcp remove playwright --scope user >/dev/null 2>&1 || true
fi
claude mcp add playwright --scope user -- npx -y "@playwright/mcp@${PW_MCP_VERSION}" "${PW_ARGS[@]}"

log "devbox tools (devbox-browser, claude-task, devbox-chrome, devbox-relay)"
install -m 755 "$SETUP_DIR"/bin/* "$HOME/.local/bin/"

log "Logged-in Chrome (your accounts) in a virtual screen, viewable through noVNC"
mkdir -p "$HOME/.config/tigervnc" "$HOME/.config/devbox" "$HOME/.config/systemd/user"
chmod 700 "$HOME/.config/devbox" "$HOME/.config/tigervnc"
if [ ! -s "$HOME/.config/tigervnc/passwd" ]; then
  # VNC only uses the first 8 characters of the password.
  pw="$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8)"
  printf '%s\n' "$pw" > "$HOME/.config/devbox/vnc-password"
  chmod 600 "$HOME/.config/devbox/vnc-password"
  printf '%s\n' "$pw" | tigervncpasswd -f > "$HOME/.config/tigervnc/passwd"
  chmod 600 "$HOME/.config/tigervnc/passwd"
fi
install -m 644 "$SETUP_DIR"/systemd/*.service "$HOME/.config/systemd/user/"
# Screen desktop: right-click menu, taskbar icon, default browser = the logged-in Chrome
# (otherwise openbox's "Web browser" opens the default Chrome profile, without your accounts).
mkdir -p "$HOME/.config/openbox" "$HOME/.config/tint2" "$HOME/.local/share/applications"
sed "s|@HOME@|$HOME|g" "$SETUP_DIR/desktop/menu.xml" > "$HOME/.config/openbox/menu.xml"
sed "s|@HOME@|$HOME|g" "$SETUP_DIR/desktop/tint2rc" > "$HOME/.config/tint2/tint2rc"
sed "s|@HOME@|$HOME|g" "$SETUP_DIR/desktop/devbox-chrome.desktop" > "$HOME/.local/share/applications/devbox-chrome.desktop"
xdg-settings set default-web-browser devbox-chrome.desktop 2>/dev/null || true
xdg-mime default devbox-chrome.desktop x-scheme-handler/http x-scheme-handler/https text/html 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable --now devbox-vnc.service devbox-wm.service devbox-novnc.service devbox-chrome.service devbox-panel.service
DISPLAY=:1 openbox --reconfigure 2>/dev/null || true
if claude mcp get chrome >/dev/null 2>&1; then
  claude mcp remove chrome --scope user >/dev/null 2>&1 || true
fi
# No --isolated: Playwright reuses the logged-in Chrome's profile (cookies included).
claude mcp add chrome --scope user -- npx -y "@playwright/mcp@${PW_MCP_VERSION}" --cdp-endpoint http://127.0.0.1:9222
devbox-browser status || true

log "Continuity while your computer is off: devbox-relay (automatic resume of desktop sessions) and guard hook"
SETTINGS="$HOME/.claude/settings.json"
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
tmpj="$(mktemp)"
# Replaces any earlier devbox-relay hook, so re-running the script does not duplicate it.
jq --arg c "$HOME/.local/bin/devbox-relay guard" \
  '.hooks.SessionStart = (((.hooks.SessionStart // []) | map(select(([.hooks[]?.command] | join(" ")) | contains("devbox-relay") | not))) + [{hooks: [{type: "command", command: $c}]}])' \
  "$SETTINGS" > "$tmpj" && mv "$tmpj" "$SETTINGS"
devbox-relay test >/dev/null || warn "devbox-relay: self-test failed (run: devbox-relay test)"
systemctl --user enable --now devbox-relay.service
# The Remote Control server asks for two confirmations the first time (enable Remote
# Control, trust ~/dev): only enable it once the CLI is logged in and those
# confirmations have been given by hand (see the final instructions below).
if [ -s "$HOME/.claude/.credentials.json" ] && [ -f "$HOME/.config/devbox/rc-accepted" ]; then
  systemctl --user enable --now devbox-rc.service
else
  echo "Remote Control server: to be enabled after 'claude' then '/login' (see the final instructions below)."
fi

log "tmux"
if [ ! -f "$HOME/.tmux.conf" ]; then
  cat > "$HOME/.tmux.conf" <<'EOF'
set -g mouse on
set -g history-limit 100000
set -g default-terminal "tmux-256color"
set -sg escape-time 10
EOF
fi

log "Done"
cat <<EOF
Folders: ~/dev (your git clones), ~/worktrees (worktrees of the desktop app sessions)
Next steps:
  1. Tailscale: sudo tailscale up --hostname=devbox
     then lock down public SSH: bash ~/devbox-setup/30-root-lockdown.sh
  2. Clone your projects: cd ~/dev && gh repo clone <owner>/<repo>
  3. In the Claude desktop app: add an SSH environment (host alias "devbox"),
     with worktrees in ~/worktrees
  4. Log in to your accounts in the host's Chrome: devbox-browser login
     then, once done: devbox-browser normal
  5. Log in the CLI once (for long tasks while your computer is off):
     run claude, then /login
  6. Activate Remote Control once (one-time confirmations):
       cd ~/dev && claude remote-control
     answer y to both questions, then press Ctrl+C, then run:
       touch ~/.config/devbox/rc-accepted
       systemctl --user enable --now devbox-rc
After that, Claude can start long tasks with: claude-task start <name> <folder> "<instruction>"
EOF
