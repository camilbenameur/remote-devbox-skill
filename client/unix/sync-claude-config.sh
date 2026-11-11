#!/usr/bin/env bash
# Copies your global CLAUDE.md and skills (and optionally auto-memory) from this
# computer to the "devbox" server. macOS / Linux client equivalent of
# client/windows/sync-claude-config.ps1.
#
#  - ~/.claude/CLAUDE.md: copied with a header (templates/host-header.md) that
#    explains the machine's differences to Claude (Linux paths, Playwright MCP,
#    no Browser pane). The server's original CLAUDE.md is kept as CLAUDE.md.bak
#    (only once).
#  - ~/.claude/skills: merged on the server (files are overwritten, skills
#    installed only on the server stay). .venv, node_modules, __pycache__ and
#    .git are not copied.
#  - With --memory, the auto-memory folder of the local project whose path is
#    --local-dev-dir is merged into the server's ~/dev memory (nothing deleted).
#    Local: ~/.claude/projects/<key>/memory, <key> = full path with every
#    character other than A-Z a-z 0-9 replaced by '-'.
#    Server: ~/.claude/projects/-home-<devuser>-dev/memory/
#
# Usage:
#   bash client/unix/sync-claude-config.sh [--alias devbox] [--skip-skills]
#     [--local-dev-dir DIR] [--memory] [--share-root auto|none|PATH]
#   --share-root: where this computer mounts the server's home (host/40-file-share.sh),
#     so sessions there also give file paths on this side. auto (default) finds the mount.
set -euo pipefail

ALIAS='devbox'
SHARE_ROOT='auto'
SKIP_SKILLS=0
MEMORY=0
LOCAL_DEV_DIR=''

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}
fail() { printf '[error] %s\n' "$1" >&2; exit 1; }
need_arg() { [ "$#" -ge 2 ] || fail "Option $1 needs a value."; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --alias)         need_arg "$@"; ALIAS="$2"; shift 2 ;;
    --skip-skills)   SKIP_SKILLS=1; shift ;;
    --local-dev-dir) need_arg "$@"; LOCAL_DEV_DIR="$2"; shift 2 ;;
    --memory)        MEMORY=1; shift ;;
    --share-root)    need_arg "$@"; SHARE_ROOT="$2"; shift 2 ;;
    -h|--help)       usage 0 ;;
    *)               printf 'Unknown option: %s\n' "$1" >&2; usage 1 ;;
  esac
done

case "$ALIAS" in
  *[!A-Za-z0-9_.@-]*|'') fail 'The alias may only contain letters, digits and _ . @ -' ;;
esac
if [ -z "$LOCAL_DEV_DIR" ]; then
  if [ -d "$HOME/Documents/dev" ]; then LOCAL_DEV_DIR="$HOME/Documents/dev"
  elif [ -d "$HOME/dev" ]; then LOCAL_DEV_DIR="$HOME/dev"
  else LOCAL_DEV_DIR="$HOME"
  fi
fi
LOCAL_DEV_DIR="${LOCAL_DEV_DIR%/}"

here="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$here/../.." && pwd)"
claude_dir="$HOME/.claude"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/devbox-sync.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

run() {
  local what="$1"; shift
  "$@" || fail "$what failed"
}

# ---------------------------------------------------------- CLAUDE.md
src="$claude_dir/CLAUDE.md"
if [ -f "$src" ]; then
  tpl="$repo_dir/templates/host-header.md"
  [ -f "$tpl" ] || fail "Template not found: $tpl"
  dev_esc="$(printf '%s' "$LOCAL_DEV_DIR" | sed 's/[&|\\]/\\&/g')"
  # File-share links: auto = where the server share is mounted (macOS: //user@<alias>/... in mount).
  share="$SHARE_ROOT"
  if [ "$share" = auto ]; then
    mnt="$(mount 2>/dev/null || true)"
    share="$(printf '%s\n' "$mnt" | sed -n "s|^//[^ ]*@$ALIAS/[^ ]* on \(.*\) (.*|\1|p" | head -n 1)"
    [ -n "$share" ] || share=none
  fi
  if [ "$share" = none ]; then
    sed -e '/^@SHARE_BEGIN@$/,/^@SHARE_END@$/d' "$tpl" > "$tmp/header.md"
    echo 'No mounted server share: share paths rule left out.'
  else
    share="${share%/}"
    share_esc="$(printf '%s' "$share" | sed 's/[&|\\]/\\&/g')"
    sed -e '/^@SHARE_BEGIN@$/d' -e '/^@SHARE_END@$/d' \
      -e "s|@SHARE_EXAMPLE@|$share_esc/dev/app/docs/report.md|g" -e "s|@SHARE_ROOT@|$share_esc|g" "$tpl" > "$tmp/header.md"
    echo "Sessions will also give file paths under $share"
  fi
  sed -e "s|@ALIAS@|$ALIAS|g" -e "s|@LOCAL_DEV_DIR@|$dev_esc|g" "$tmp/header.md" > "$tmp/CLAUDE.md"
  tr -d '\r' < "$src" >> "$tmp/CLAUDE.md"
  run 'preparing ~/.claude' ssh "$ALIAS" \
    'mkdir -p ~/.claude && if [ -f ~/.claude/CLAUDE.md ] && [ ! -f ~/.claude/CLAUDE.md.bak ]; then cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.bak; fi'
  run 'copying CLAUDE.md' scp "$tmp/CLAUDE.md" "$ALIAS:.claude/CLAUDE.md"
  echo 'CLAUDE.md copied.'
else
  echo "No $src : nothing to copy."
fi

# ---------------------------------------------------------- skills
if [ "$SKIP_SKILLS" -eq 0 ] && [ -d "$claude_dir/skills" ]; then
  run 'skills archive' env COPYFILE_DISABLE=1 tar -czf "$tmp/skills.tgz" --exclude .venv --exclude node_modules \
    --exclude __pycache__ --exclude .git -C "$claude_dir" skills
  size_kb="$(( $(wc -c < "$tmp/skills.tgz") / 1024 ))"
  echo "Skills archive: $size_kb KB"
  run 'copying skills' scp "$tmp/skills.tgz" "$ALIAS:.claude/skills-sync.tgz"
  run 'extracting skills' ssh "$ALIAS" 'cd ~/.claude && tar -xzf skills-sync.tgz && rm -f skills-sync.tgz && ls skills'
  echo 'Skills merged into ~/.claude/skills on the server.'
fi

# ---------------------------------------------------------- auto-memory
if [ "$MEMORY" -eq 1 ]; then
  full="$(cd "$LOCAL_DEV_DIR" 2>/dev/null && pwd)" || fail "Folder not found: $LOCAL_DEV_DIR"
  key="$(printf '%s' "$full" | sed 's/[^A-Za-z0-9]/-/g')"
  mem_dir="$claude_dir/projects/$key/memory"
  if [ ! -d "$mem_dir" ]; then
    echo "No auto-memory at $mem_dir : nothing to copy."
  else
    dev_user="$(ssh "$ALIAS" whoami | head -n 1 | tr -d '\r')" || fail 'Could not read the server user name (ssh whoami).'
    case "$dev_user" in
      ''|[!a-z_]*|*[!a-z0-9_-]*) fail 'Could not read the server user name (ssh whoami).' ;;
    esac
    remote_dir=".claude/projects/-home-$dev_user-dev/memory"
    run 'memory archive' env COPYFILE_DISABLE=1 tar -czf "$tmp/memory.tgz" -C "$mem_dir" .
    run 'creating the memory folder' ssh "$ALIAS" "mkdir -p ~/$remote_dir"
    run 'copying memory' scp "$tmp/memory.tgz" "$ALIAS:.claude/memory-sync.tgz"
    run 'extracting memory' ssh "$ALIAS" "tar -xzf ~/.claude/memory-sync.tgz -C ~/$remote_dir && rm -f ~/.claude/memory-sync.tgz"
    count="$(find "$mem_dir" -type f | wc -l | tr -d ' ')"
    echo "Memory merged: $count file(s) from $mem_dir"
    echo "  -> ~/$remote_dir on the server"
    (cd "$mem_dir" && find . -type f | sed 's|^\./|  |')
  fi
fi
