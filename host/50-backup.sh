#!/usr/bin/env bash
# 50-backup.sh: optional. Nightly encrypted, incremental backup of the devbox with restic, to a
# repository off the server (Google Drive through rclone, S3-compatible storage, B2, SFTP...).
# Installs restic, rclone and sqlite3, /usr/local/sbin/devbox-backup, its configuration in
# /etc/devbox-backup and five system units (nightly run at 04:30, alert on failure, daily freshness
# check). See references/backup.md for choosing the destination and for restoring.
#
# Usage (as root):
#   sudo INIT=1 bash 50-backup.sh <user> <restic-repository>   first install: creates the repository
#   sudo bash 50-backup.sh <user> [<restic-repository>]        update, or reinstall on a rebuilt host
#                                                              (the repository must already exist)
# Repository examples: rclone:gdrive:devbox-restic   s3:https://<endpoint>/<bucket>/devbox
#                      b2:<bucket>:devbox            sftp:<user>@<host>:devbox
# Before running it: /etc/devbox-backup/rclone.conf (rclone repositories) or
# /etc/devbox-backup/credentials.env (keys of other backends), both root only.
#
# Safe to run again: it never replaces the restic password, the cloud credentials, backup.env or
# excludes.local, and it creates a repository only with INIT=1, so that a reinstall whose sign-in
# does not see the old repository cannot start an empty one next to it.
set -euo pipefail

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warning] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo)."
USER_NAME="${1:-}"
REPO="${2:-}"
[ -n "$USER_NAME" ] || die "Usage: sudo [INIT=1] bash 50-backup.sh <user> [<restic-repository>]"
id "$USER_NAME" >/dev/null 2>&1 || die "No such user: $USER_NAME"
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SETUP_DIR/backup"
CONF=/etc/devbox-backup
[ -f "$SRC/devbox-backup" ] || die "Missing $SRC/devbox-backup (copy the whole host folder)."

log "Packages"
if ! command -v restic >/dev/null || ! command -v rclone >/dev/null || ! command -v sqlite3 >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=600 update -qq
  apt-get -o DPkg::Lock::Timeout=600 install -y -qq restic rclone sqlite3 >/dev/null
fi
restic version

log "Script and configuration"
install -d -m 700 "$CONF" /var/lib/devbox-backup /var/cache/restic
# Atomic replacement (rename): a run in progress keeps reading the old file.
install -m 755 "$SRC/devbox-backup" /usr/local/sbin/.devbox-backup.new
mv -f /usr/local/sbin/.devbox-backup.new /usr/local/sbin/devbox-backup
install -m 600 "$SRC/excludes" "$CONF/excludes"

check_repo_form() {
  case "$1" in
    *$'\n'*) die "The repository must be on one line." ;;
    /*)
      # A local folder: a mounted external disk, or a test. The nightly service has a private /tmp
      # and read-only /home, /root, /etc and /usr, and those are backed up themselves.
      case "$1/" in
        /tmp/*|/var/tmp/*|/home/*|/root/*|/etc/*|/usr/*|/var/backups/*)
          die "Local repository $1: not under /tmp, /home, /root, /etc, /usr or /var/backups (use for example /mnt/<disk>/devbox-restic)." ;;
      esac
      warn "Local repository $1: it is not off the server unless it is on a separate, mounted disk." ;;
    [a-z0-9]*:*) ;;
    *) die "Repository: an absolute path or a restic backend URL (rclone:, s3:, b2:, sftp:, rest:...), got: $1" ;;
  esac
}

if [ ! -f "$CONF/backup.env" ]; then
  [ -n "$REPO" ] || die "First install: give the repository, e.g. rclone:gdrive:devbox-restic"
  check_repo_form "$REPO"
  {
    echo "# devbox-backup configuration (written by 50-backup.sh, kept on later runs)."
    echo "# Literal values only: the file is read before any variable such as \$HOME is known."
    printf 'BACKUP_USER=%q\n' "$USER_NAME"
    printf 'RESTIC_REPOSITORY=%q\n' "$REPO"
    cat <<EOF
# Paths to back up, space-separated, no spaces inside a path. Missing paths are skipped.
#BACKUP_PATHS="/home/$USER_NAME /etc /root /usr/local /usr/share/keyrings /var/lib/tailscale /var/lib/samba /var/spool/cron /var/backups"
# Retention: one snapshot per day for 14 days, per week for 8 weeks, per month for 12 months.
KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=12
# The watchdog alerts when the last success is older than this many hours.
MAX_AGE_HOURS=30
# Alerts (strongly advised, both allowed): an ntfy topic URL, and/or a shell command run as
# $USER_NAME, with the message appended as its last argument.
#NOTIFY_URL=https://ntfy.sh/<a-long-random-topic>
#NOTIFY_CMD=
# rclone repositories only (optional): a plain-text copy of the runbook and scripts next to the
# repository, readable when the devbox is gone, e.g. gdrive:devbox-backup-tools
#TOOL_REMOTE=
EOF
  } > "$CONF/backup.env"
else
  bash -n "$CONF/backup.env" || die "$CONF/backup.env has a syntax error."
  # shellcheck source=/dev/null
  current_repo="$(. "$CONF/backup.env"; echo "${RESTIC_REPOSITORY:-}")"
  if [ -n "$REPO" ] && [ "$REPO" != "$current_repo" ]; then
    warn "$CONF/backup.env keeps RESTIC_REPOSITORY=$current_repo (edit it by hand to change)."
  fi
  REPO="$current_repo"
  check_repo_form "$REPO"
fi

case "$REPO" in
  rclone:*) [ -s "$CONF/rclone.conf" ] || die "Missing $CONF/rclone.conf (references/backup.md, Google Drive)." ;;
  s3:*|b2:*|azure:*|gs:*|swift:*)
    [ -s "$CONF/credentials.env" ] || die "Missing $CONF/credentials.env with the backend keys (references/backup.md)." ;;
esac
for f in rclone.conf credentials.env; do [ -f "$CONF/$f" ] && chmod 600 "$CONF/$f"; done

if [ ! -s "$CONF/restic-password" ]; then
  # Only for a new repository: on a rebuilt host, the saved password must be put back instead.
  [ "${INIT:-0}" = 1 ] || die "Missing $CONF/restic-password: put back the saved password first
  (sudo sh -c 'umask 077; cat > $CONF/restic-password'), see references/backup.md, rebuild."
  (umask 077; head -c 36 /dev/urandom | base64 | tr -d '\n' > "$CONF/restic-password")
  PW_CREATED=1
fi

# Plain-text copy of the runbook and scripts (sent by TOOL_REMOTE when set). No secrets.
install -d -m 755 /usr/local/share/devbox-backup
install -m 644 "$SRC"/excludes "$SRC"/*.service "$SRC"/*.timer /usr/local/share/devbox-backup/
install -m 755 "$SRC/devbox-backup" "$SRC/devbox-gdrive-auth" "$SETUP_DIR/50-backup.sh" /usr/local/share/devbox-backup/
# The runbook: from the skill checkout, or from the copy of the skill synced to the devbox.
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
for doc in "$SETUP_DIR/../references/backup.md" "$USER_HOME/.claude/skills/remote-devbox/references/backup.md"; do
  if [ -f "$doc" ] && [ ! -L "$doc" ]; then install -m 644 "$doc" /usr/local/share/devbox-backup/backup.md; break; fi
done
[ -f /usr/local/share/devbox-backup/backup.md ] ||
  warn "Runbook not found on this host: copy references/backup.md to /usr/local/share/devbox-backup/ by hand."

log "Repository"
if err="$(/usr/local/sbin/devbox-backup restic cat config 2>&1 >/dev/null)"; then
  echo "Repository found."
elif [ "${INIT:-0}" = 1 ] && printf '%s' "$err" | grep -qiE 'is there a repository|does not exist|no such file|not found'; then
  /usr/local/sbin/devbox-backup restic init
  NEW_REPOSITORY=1
  : > /var/lib/devbox-backup/password-unsaved
else
  printf '%s\n' "$err" | head -5 >&2
  # A password generated by this run cannot be the right one for an existing repository.
  [ "${PW_CREATED:-0}" = 1 ] && rm -f "$CONF/restic-password"
  die "Repository unreadable (above: restic's message). Wrong password, expired sign-in, other
  OAuth client, network? Fix the cause; INIT=1 creates a repository only where none exists."
fi

log "Units"
install -m 644 "$SRC"/*.service "$SRC"/*.timer /etc/systemd/system/
[ -f /var/lib/devbox-backup/installed ] || date -Is > /var/lib/devbox-backup/installed
systemctl daemon-reload
systemctl enable --now devbox-backup.timer devbox-backup-watchdog.timer >/dev/null
systemctl list-timers 'devbox-backup*' --no-pager

log "Done"
if [ -f /var/lib/devbox-backup/password-unsaved ]; then
  printf '\033[1;33m%s\033[0m\n' "The repository is encrypted with $CONF/restic-password." \
    "The user must save that password OUTSIDE the devbox (password manager): without it the backup" \
    "cannot be read. They print it themselves with:  ssh -t devbox sudo cat $CONF/restic-password" \
    "Once saved:  sudo rm /var/lib/devbox-backup/password-unsaved"
fi
# shellcheck source=/dev/null
if [ -z "$(. "$CONF/backup.env"; echo "${NOTIFY_URL:-}${NOTIFY_CMD:-}")" ]; then
  warn "No alert configured: a failing backup shows only in the journal. Set NOTIFY_URL or NOTIFY_CMD in $CONF/backup.env."
fi
if [ "${NEW_REPOSITORY:-0}" = 1 ]; then
  cat <<EOF
First backup now (then every night around 04:30):
  sudo systemctl start --no-block devbox-backup
Follow it:  sudo journalctl -u devbox-backup -n 30 --no-pager
Finished when systemctl show devbox-backup -p ActiveState -p Result says inactive and success,
and sudo devbox-backup status shows a snapshot from today.
EOF
else
  cat <<EOF
Existing repository. Rebuilding this host? Stop the timer now (sudo systemctl stop devbox-backup.timer)
and restore first (references/backup.md, section 6). State:  sudo devbox-backup status
EOF
fi
