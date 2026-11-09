#!/usr/bin/env bash
# Prepares a fresh Ubuntu 24.04 server for Claude desktop app SSH sessions.
# macOS / Linux client equivalent of client/windows/setup-devbox.ps1.
#
#  1. Creates the SSH key ~/.ssh/devbox_ed25519 (empty passphrase: the desktop
#     app must be able to connect without prompting).
#  2. Has you verify the server host key fingerprint, then authorizes the key
#     for the server's initial user (root or ubuntu).
#  3. Runs host/10-root-bootstrap.sh (system, security, tools).
#  4. Adds the alias to ~/.ssh/config, tests the connection, then restricts
#     SSH to the dev user (root login disabled).
#  5. Runs host/20-user-setup.sh (uv, Claude Code, gh, Playwright MCP, and
#     gatehaul with --gatehaul).
#  6. Copies your global CLAUDE.md and your skills (sync-claude-config.sh).
# If "ssh <alias>" already works, the script resumes from there: it can be
# re-run after a failure, even once SSH is locked down.
#
# Usage:
#   bash client/unix/setup-devbox.sh --show-key
#   bash client/unix/setup-devbox.sh --host 203.0.113.10 [--initial-user ubuntu]
#     [--dev-user NAME] [--alias devbox] [--key PATH] [--skip-config-sync] [--gatehaul]
set -euo pipefail

HOST_ADDRESS=''
INITIAL_USER='root'
DEV_USER="$(id -un | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')"
ALIAS='devbox'
KEY_PATH="$HOME/.ssh/devbox_ed25519"
SHOW_KEY=0
SKIP_SYNC=0
GATEHAUL=0

usage() {
  sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

step() { printf '\n==> %s\n' "$1"; }
warn() { printf '[warning] %s\n' "$1" >&2; }
fail() { printf '[error] %s\n' "$1" >&2; exit 1; }

need_arg() { [ "$#" -ge 2 ] || fail "Option $1 needs a value."; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)             need_arg "$@"; HOST_ADDRESS="$2"; shift 2 ;;
    --initial-user)     need_arg "$@"; INITIAL_USER="$2"; shift 2 ;;
    --dev-user)         need_arg "$@"; DEV_USER="$2"; shift 2 ;;
    --alias)            need_arg "$@"; ALIAS="$2"; shift 2 ;;
    --key)              need_arg "$@"; KEY_PATH="$2"; shift 2 ;;
    --show-key)         SHOW_KEY=1; shift ;;
    --skip-config-sync) SKIP_SYNC=1; shift ;;
    --gatehaul)         GATEHAUL=1; shift ;;
    -h|--help)          usage 0 ;;
    *)                  printf 'Unknown option: %s\n' "$1" >&2; usage 1 ;;
  esac
done

[ -n "$DEV_USER" ] || DEV_USER='dev'
case "$DEV_USER" in
  [a-z_]*) case "$DEV_USER" in *[!a-z0-9_-]*) fail "Invalid --dev-user '$DEV_USER' (use lowercase letters, digits, _ and -)." ;; esac ;;
  *) fail "Invalid --dev-user '$DEV_USER' (use lowercase letters, digits, _ and -)." ;;
esac
case "$DEV_USER$INITIAL_USER$ALIAS" in
  *[!A-Za-z0-9_.@-]*) fail 'User names and alias may only contain letters, digits and _ . @ -' ;;
esac
case "$HOST_ADDRESS" in
  *[!A-Za-z0-9_.:-]*) fail 'Invalid --host value.' ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$here/../.." && pwd)"
host_dir="$repo_dir/host"
user_ssh="$HOME/.ssh"
cfg_path="$user_ssh/config"

command -v ssh >/dev/null 2>&1 || fail 'ssh not found in PATH.'
command -v scp >/dev/null 2>&1 || fail 'scp not found in PATH.'
command -v ssh-keygen >/dev/null 2>&1 || fail 'ssh-keygen not found in PATH.'
[ -d "$host_dir" ] || fail "Folder not found: $host_dir (run this script from a full copy of the repo)."

mkdir -p "$user_ssh" "$(dirname "$KEY_PATH")"
chmod 700 "$user_ssh"

# Options must come before the destination (the last argument).
test_ssh() { ssh -o BatchMode=yes -o ConnectTimeout=20 "$@" true >/dev/null 2>&1; }

run() {
  local what="$1"; shift
  "$@" || fail "$what failed. You can re-run this script."
}

# ------------------------------------------------------------ SSH client
step 'OpenSSH client'
ver="$(ssh -V 2>&1 || true)"
printf '%s\n' "$ver"
major="$(printf '%s' "$ver" | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1/p')"
minor="$(printf '%s' "$ver" | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\2/p')"
if [ -n "$major" ] && [ -n "$minor" ]; then
  if [ "$major" -lt 9 ] || { [ "$major" -eq 9 ] && [ "$minor" -lt 4 ]; }; then
    warn 'OpenSSH older than 9.4: if the desktop app refuses the SSH environment, install a newer one (for example brew install openssh).'
  fi
else
  warn 'Unrecognized OpenSSH version, continuing.'
fi

# ------------------------------------------------------------ key
step "SSH key $KEY_PATH"
if [ ! -f "$KEY_PATH" ]; then
  run 'ssh-keygen' ssh-keygen -t ed25519 -f "$KEY_PATH" -N '' -C devbox
fi
pub="$(tr -d '\r\n' < "$KEY_PATH.pub")"
if ! printf '%s' "$pub" | grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+( [A-Za-z0-9@._-]+)?$'; then
  fail "Unexpected public key in $KEY_PATH.pub (comment with special characters?)."
fi
if [ "$SHOW_KEY" -eq 1 ]; then
  printf "\nPublic key to paste at your hosting provider (the 'SSH key' field):\n\n"
  printf '%s\n' "$pub"
  exit 0
fi
key_core="$(printf '%s' "$pub" | cut -d' ' -f1,2)"

alias_defined=0
if [ -f "$cfg_path" ] && grep -Eq "^[[:space:]]*Host[[:space:]]+${ALIAS}[[:space:]]*\$" "$cfg_path"; then
  alias_defined=1
fi
alias_ok=0
if [ "$alias_defined" -eq 1 ] && test_ssh "$ALIAS"; then alias_ok=1; fi

boot_target=''
boot_opts=()
if [ "$alias_ok" -eq 1 ]; then
  step "'ssh $ALIAS' already works: resuming from there"
  boot_target="$ALIAS"
else
  [ -n "$HOST_ADDRESS" ] || fail 'Pass --host <server ip> (or --show-key to print the key).'
  target="$INITIAL_USER@$HOST_ADDRESS"
  key_opts=(-i "$KEY_PATH" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes)

  # ---------------------------------------------------------- server fingerprint
  step "Fingerprint of server $HOST_ADDRESS"
  # Let ssh itself print the fingerprint and ask yes/no (same flow as the
  # Windows script, where ssh-keyscan cannot handle the sntrup761 key exchange).
  if ssh-keygen -F "$HOST_ADDRESS" >/dev/null 2>&1; then
    echo 'Server already known: ssh will check that its key has not changed.'
  else
    cat <<'EOF'
ssh will print the server's ED25519 fingerprint and ask yes/no.
To be sure, compare it with one seen outside this connection: the hosting
provider's web console (VNC), command  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
Type "yes" if it is identical. The "Permission denied" that follows is expected.
EOF
    ssh -o StrictHostKeyChecking=ask -o PreferredAuthentications=none -o ConnectTimeout=20 "$target" true || true
    ssh-keygen -F "$HOST_ADDRESS" >/dev/null 2>&1 || fail 'Stopped: fingerprint not accepted (or server unreachable).'
  fi

  # ---------------------------------------------------------- initial access
  step "Access to $target"
  if ! test_ssh "${key_opts[@]}" "$target"; then
    echo "The key is not authorized yet: enter the password of $INITIAL_USER (given by the hosting provider)."
    remote="umask 077; mkdir -p ~/.ssh; grep -qF '$key_core' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys"
    run 'Could not authorize the key' ssh -o StrictHostKeyChecking=yes "$target" "$remote"
    test_ssh "${key_opts[@]}" "$target" || fail "Key-based login still does not work for $target."
  fi
  boot_target="$target"
  boot_opts=("${key_opts[@]}")
fi

# ------------------------------------------------------------ root bootstrap
step 'Copying the scripts to the server'
run 'remote cleanup' ssh ${boot_opts[@]+"${boot_opts[@]}"} "$boot_target" 'rm -rf /tmp/devbox-setup'
run 'scp of the host folder' scp ${boot_opts[@]+"${boot_opts[@]}"} -r "$host_dir" "$boot_target:/tmp/devbox-setup"
# In case an editor introduced CRLF line endings.
run 'line-ending conversion' ssh ${boot_opts[@]+"${boot_opts[@]}"} "$boot_target" \
  "chmod -R go-rwx /tmp/devbox-setup && find /tmp/devbox-setup -type f -exec sed -i 's/\\r\$//' {} +"

step 'System preparation (10-root-bootstrap.sh, takes 5 to 10 minutes)'
run '10-root-bootstrap.sh' ssh -t ${boot_opts[@]+"${boot_opts[@]}"} "$boot_target" \
  "sudo bash /tmp/devbox-setup/10-root-bootstrap.sh $DEV_USER '$pub' $INITIAL_USER"

# ------------------------------------------------------------ ~/.ssh/config
step "Alias '$ALIAS' in $cfg_path"
if [ "$alias_defined" -eq 1 ]; then
  echo "Block 'Host $ALIAS' already present: leaving it alone."
else
  {
    printf '\n'
    printf 'Host %s\n' "$ALIAS"
    printf '  HostName %s\n' "$HOST_ADDRESS"
    printf '  User %s\n' "$DEV_USER"
    printf '  IdentityFile ~/.ssh/%s\n' "$(basename "$KEY_PATH")"
    printf '  IdentitiesOnly yes\n'
    printf '  ServerAliveInterval 30\n'
    printf '  ServerAliveCountMax 6\n'
  } >> "$cfg_path"
  chmod 600 "$cfg_path"
fi
test_ssh -o StrictHostKeyChecking=yes "$ALIAS" || fail "Cannot connect with 'ssh $ALIAS'. SSH is not locked down: $INITIAL_USER keeps access so you can fix it."
echo "ssh $ALIAS: OK"

# ------------------------------------------------------------ SSH lockdown
step "SSH restricted to $DEV_USER (root and $INITIAL_USER can no longer log in)"
run 'cleanup of ~/devbox-setup' ssh "$ALIAS" 'rm -rf ~/devbox-setup'
run 'scp to ~/devbox-setup' scp -r "$host_dir" "$ALIAS:devbox-setup"
run 'cleanup' ssh "$ALIAS" \
  "chmod -R go-rwx ~/devbox-setup && find ~/devbox-setup -type f -exec sed -i 's/\\r\$//' {} + && sudo rm -rf /tmp/devbox-setup"
run 'SSH lockdown' ssh -t "$ALIAS" "sudo bash ~/devbox-setup/10-root-bootstrap.sh --lock-ssh $DEV_USER"
test_ssh "$ALIAS" || fail "ssh $ALIAS no longer works after the lockdown: use the hosting provider's web console."

# ------------------------------------------------------------ user tools
step 'User tools (20-user-setup.sh)'
git_name=''
git_email=''
if command -v git >/dev/null 2>&1; then
  git_name="$(git config --global user.name 2>/dev/null | tr -d "'" || true)"   # only a single quote could break the remote command
  git_email="$(git config --global user.email 2>/dev/null | tr -cd 'A-Za-z0-9._@+-' || true)"
fi
run '20-user-setup.sh' ssh -t "$ALIAS" \
  "GIT_NAME='$git_name' GIT_EMAIL='$git_email' INSTALL_GATEHAUL=$GATEHAUL bash ~/devbox-setup/20-user-setup.sh"

# ------------------------------------------------------------ Claude config
if [ "$SKIP_SYNC" -eq 0 ]; then
  step 'Copying your global CLAUDE.md and your skills'
  bash "$here/sync-claude-config.sh" --alias "$ALIAS" || fail 'Copying CLAUDE.md or skills failed: re-run client/unix/sync-claude-config.sh.'
fi

step 'Done'
cat <<EOF
What is left (see README.md):
  1. Tailscale: install it on this computer, then  ssh $ALIAS  and  sudo tailscale up --hostname=$ALIAS
     Tailscale admin console > Machines > $ALIAS > Disable key expiry.
     Set HostName = $ALIAS (the Tailscale name) in ~/.ssh/config, reconnect, then
     bash ~/devbox-setup/30-root-lockdown.sh  to close the public port 22.
  2. Reboot the server if the script advised it:  ssh $ALIAS sudo reboot
  3. Claude desktop app > Code > environment > New environment > SSH:
     host "$ALIAS", empty key (taken from ~/.ssh/config), worktrees ~/worktrees, folder ~/dev/<project>
EOF
