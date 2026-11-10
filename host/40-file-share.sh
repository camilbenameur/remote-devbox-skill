#!/usr/bin/env bash
# 40-file-share.sh: optional. Shares the dev user's home folder over SMB, reachable only from the
# tailnet, so the user can open the files sessions write (reports, PDFs, images...) in their own
# file manager: Windows Explorer (\\devbox\<user>) or macOS Finder (smb://devbox/<user>).
#
# Usage (as root):  sudo bash 40-file-share.sh <user>
# Then the user sets the share password themselves:  sudo smbpasswd -a <user>
#
# Security: SMB3 only, signing and encryption required, no guest access, no printers, no NetBIOS.
# Only tailnet addresses (100.64.0.0/10) and localhost are accepted, and ufw (set up by
# 10-root-bootstrap.sh / 30-root-lockdown.sh) already drops anything that does not come in on
# tailscale0. Safe to run again.
set -euo pipefail

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo)."
USER_NAME="${1:-}"
[ -n "$USER_NAME" ] || die "Usage: sudo bash 40-file-share.sh <user>"
id "$USER_NAME" >/dev/null 2>&1 || die "No such user: $USER_NAME"

log "Samba"
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update -qq
apt-get -o DPkg::Lock::Timeout=600 install -y -qq samba >/dev/null

CONF=/etc/samba/smb.conf
if [ -f "$CONF" ] && [ ! -f "$CONF.orig" ]; then
  cp -a "$CONF" "$CONF.orig"
fi
cat > "$CONF" <<'EOF'
# Written by remote-devbox host/40-file-share.sh (original kept as smb.conf.orig).
[global]
   server string = devbox
   server role = standalone server
   workgroup = WORKGROUP
   security = user
   map to guest = never
   restrict anonymous = 2
   server min protocol = SMB3
   server signing = mandatory
   smb encrypt = required
   disable netbios = yes
   smb ports = 445
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
   hosts allow = 100.64.0.0/10 127.0.0.1
   hosts deny = 0.0.0.0/0
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   # Files keep their Linux owner; new ones get normal permissions.
   unix extensions = no
   create mask = 0644
   directory mask = 0755

[homes]
   comment = Home folder
   browseable = no
   read only = no
   valid users = %S
EOF
testparm -s "$CONF" >/dev/null 2>&1 || die "testparm rejected $CONF (original in $CONF.orig)"

# NetBIOS is off: nmbd is not needed.
systemctl disable --now nmbd >/dev/null 2>&1 || true
systemctl enable smbd >/dev/null
systemctl restart smbd
systemctl is-active smbd

if command -v ufw >/dev/null 2>&1; then
  ufw_out="$(ufw status 2>/dev/null || true)"
  case "$ufw_out" in
    *"Status: active"*) echo "ufw is active: SMB is reachable only where ufw allows it (tailscale0)." ;;
    *) printf '\033[1;33m[warning] ufw is not active: only "hosts allow" protects port 445.\033[0m\n' >&2 ;;
  esac
fi

log "Done"
# Output captured first: grep -q after a pipe can trip pipefail (SIGPIPE).
accounts="$(pdbedit -L 2>/dev/null || true)"
case "
$accounts" in
  *"
$USER_NAME:"*)
    echo "SMB account for $USER_NAME already exists (change its password: sudo smbpasswd $USER_NAME)." ;;
  *)
    echo "Last step, for the user (choose a password, it is only for this share):"
    echo "  sudo smbpasswd -a $USER_NAME" ;;
esac
cat <<EOF
Then, from a machine on the tailnet:
  Windows:  net use Z: \\\\devbox\\$USER_NAME /persistent:yes     (or Explorer > This PC > Map network drive)
  macOS:    Finder > Go > Connect to Server > smb://devbox/$USER_NAME
If the name "devbox" does not resolve, use the address from: tailscale ip -4
EOF
