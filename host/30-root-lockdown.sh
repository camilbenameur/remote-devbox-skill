#!/usr/bin/env bash
# 30-root-lockdown.sh: closes the public SSH port. After that, the host is only
# reachable through Tailscale (or through the hosting provider's web console as a fallback).
#
# Before: Tailscale admin console > Machines > devbox > "Disable key expiry",
# otherwise the host drops out of the tailnet when its key expires (180 days by
# default) and only the provider's console is left.
#
# Run as the dev user, when ALL open SSH sessions (the desktop app included) go
# through Tailscale:
#   ssh devbox   (HostName = Tailscale name or IP)
#   bash ~/devbox-setup/30-root-lockdown.sh
# FORCE=1 skips the check of current sessions.
set -euo pipefail

die() { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  exec sudo FORCE="${FORCE:-0}" bash "$0" "$@"
fi

command -v tailscale >/dev/null || die "Tailscale is not installed."
tailscale status >/dev/null 2>&1 || die "Tailscale is not connected: sudo tailscale up --hostname=devbox"
TS_IP="$(tailscale ip -4 | head -n1)"

# Address inside the tailnet: 100.64.0.0/10 or fd7a:115c:a1e0::/48.
from_tailnet() {
  local ip="${1#::ffff:}" a b
  case "$ip" in fd7a:115c:a1e0:*) return 0 ;; esac
  IFS=. read -r a b _ _ <<<"$ip"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 1
  [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]
}

# Look at the SSH connections that are really established (not SSH_CONNECTION, which a
# tmux shell keeps from an old connection): all of them must come from the tailnet.
if [ "${FORCE:-0}" != "1" ]; then
  conns="$(ss -H -tn state established '( sport = :22 )')"
  [ -n "$conns" ] || die "No established SSH session detected (FORCE=1 if you know what you are doing)."
  while read -r _ _ _ peer _; do
    [ -n "$peer" ] || continue
    ip="${peer%:*}"; ip="${ip#[}"; ip="${ip%]}"
    from_tailnet "$ip" || die "An SSH session comes from $ip, not from Tailscale. Close it (the desktop app included) or reconnect it through $TS_IP, then run this again."
  done <<<"$conns"
fi

ufw allow in on tailscale0 comment 'all tailnet traffic'
if grep -q 'OpenSSH' <<<"$(ufw status)"; then
  ufw --force delete allow OpenSSH
fi
rules="$(ufw status)"
if grep -Eq '^(22|OpenSSH)(/tcp)?( \(v6\))?[[:space:]]+ALLOW' <<<"$rules"; then
  die "A public SSH rule is still active: port 22 is still open. Check 'sudo ufw status numbered'."
fi
printf '%s\n' "$rules"
cat <<EOF

Public port 22 closed. Access: ssh devbox (Tailscale, $TS_IP).
- Open a second "ssh devbox" connection before closing this one.
- Check that key expiry is disabled for devbox (Tailscale admin console > Machines).
- If you get locked out: use the provider's web console, then run "sudo ufw allow OpenSSH".
EOF
