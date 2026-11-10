---
name: remote-devbox
description: Sets up, from nothing, a remote Linux "devbox" where the Claude desktop app runs its Claude Code sessions over SSH, on the user's Claude subscription (no API credits), then mirrors the user's local Claude environment there (global CLAUDE.md, skills, memory, plugin hooks, projects). Includes a shared Chrome logged in to the user's accounts that agents drive through MCP, a virtual screen viewable in a web browser, long tasks in tmux, and automatic continuation of sessions when the user's computer is turned off. Use when the user wants Claude Code sessions to run on a VPS or another machine instead of their laptop (low RAM, many sessions, Chrome tabs, installs), asks which server to rent for it, wants sessions to keep going with the computer off, wants a browser with their accounts on a server, wants to copy their CLAUDE.md, skills or memory to a remote host, or wants to repair, update or verify an existing devbox.
---

# remote-devbox

You are setting up (or repairing) a **devbox**: a Linux server where Claude Code sessions run while
the Claude desktop app on the user's computer is only the interface. Work through the phases in
order. Each phase says what you do, what only the user can do, and how to check it worked.

`<skill>` below means the folder that contains this file.

## What the user gets

- The desktop app's **Code** tab, unchanged, with every session running on the devbox over SSH:
  shell, tests, installs, Python, Node, Chrome. The computer only draws the interface.
- The user's subscription, not API credits. The desktop app passes and refreshes the session's
  sign-in. **Never set `ANTHROPIC_API_KEY` on the devbox**: billing would move to the API.
- Two browsers as MCP servers: `chrome`, one shared Chrome logged in to the user's accounts, and
  `playwright`, a blank isolated Chrome per session. A virtual screen shows the shared Chrome in any
  web browser on the user's private network (noVNC).
- Sessions that keep going with the computer off: `devbox-relay` resumes cut Desktop sessions in the
  background, and `devbox-rc` hosts sessions started from claude.ai/code or the phone app.
- The same global `CLAUDE.md`, skills, memory and plugin hooks as on the computer.

Read [references/how-it-works.md](references/how-it-works.md) when you need the mechanics, and
[references/troubleshooting.md](references/troubleshooting.md) as soon as something fails.

## Ground rules for you

- The user does: payment and ordering, every password and sign-in (provider, Tailscale, GitHub
  device code, Claude `/login`, the websites in the shared Chrome), clicks in the desktop app's
  settings, and the Tailscale admin console. Give them the exact link or command, one at a time,
  then wait. Never type a password, card number or one-time code yourself.
- Before ordering anything, state the plan, the price and the commitment, and get a yes.
- The setup scripts are idempotent: when one fails, read the error, fix the cause, run it again.
- On the devbox, sudo needs no password. Still ask the user before any system change that the
  scripts do not make themselves (packages, services, firewall, sshd, users).
- When working on the user's live devbox, never stop `devbox-*` services, edit `~/.claude` or
  replace binaries in `~/.local/bin` without saying so first: their sessions may be running.

## Phase 0: check the computer

1. Platform. Windows: scripts in `<skill>/client/windows/` (Windows PowerShell 5.1 is fine).
   macOS or Linux: `<skill>/client/unix/`.
2. Windows only: OpenSSH client 9.4 or newer (`ssh -V`). The desktop app requires it. If older:
   `winget install Microsoft.OpenSSH.Preview`.
3. The Claude desktop app is installed and signed in, and the user's plan includes Claude Code.
4. `git config --global user.name` and `user.email` are set (the scripts copy them to the devbox).
5. Ask the user which optional parts they want: gatehaul (runs heavy builds in GitHub Codespaces,
   `-Gatehaul` / `--gatehaul`), the shared logged-in Chrome (on by default), memory copy.

## Phase 1: choose and order a server

Use [references/providers.md](references/providers.md). Requirements: KVM virtual machine, Ubuntu
24.04, x86_64 preferred (arm64 works but is not tested end to end), 8 GB of RAM at the very least
(16 to 24 GB for several parallel sessions plus Chrome), 80 GB of disk, and a web console from the
provider (it is the rescue path if SSH is ever locked).

Help the user compare, then open the order page for them if you have a browser. The user picks the
plan, pays and confirms. If the provider asks for an SSH key at order time, show it first:

```powershell
powershell -ExecutionPolicy Bypass -File <skill>\client\windows\setup-devbox.ps1 -ShowKey
```
```bash
bash <skill>/client/unix/setup-devbox.sh --show-key
```

Ask the user for the public IP and the initial user (often `root`; `ubuntu` on OVH and Oracle).

## Phase 2: bootstrap the server

```powershell
powershell -ExecutionPolicy Bypass -File <skill>\client\windows\setup-devbox.ps1 -HostAddress <IP> -InitialUser root
```
```bash
bash <skill>/client/unix/setup-devbox.sh --host <IP> --initial-user root
```

Run it in a terminal the user can type into (the desktop app's terminal panel, or ask them to run
it). It needs three things from the user:

1. **Host key fingerprint.** The script shows it and asks yes/no. Tell the user to compare it with
   the provider's web console output of `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
2. **Initial password**, once, so the key can be authorized (skipped if the key was given at order).
3. **GitHub device code**: `gh auth login` prints a code and a link.

What it does: creates the key `~/.ssh/devbox_ed25519` (no passphrase, the desktop app must connect
without a prompt), runs `host/10-root-bootstrap.sh` (dev user with sudo, key-only SSH, linger, swap,
Node, gh, Chrome, Tailscale, ufw, fail2ban, unattended upgrades, virtual screen packages), adds the
`Host devbox` block to `~/.ssh/config`, tests it, restricts SSH to the dev user, runs
`host/20-user-setup.sh` (uv, Claude Code CLI, optional gatehaul, MCP servers, `~/.local/bin` tools,
virtual screen services, relay service and hook), then syncs the Claude configuration (Phase 6).

Check: `ssh devbox 'claude --version; claude mcp list; systemctl --user is-active devbox-vnc devbox-chrome devbox-relay'`.

## Phase 3: private network, then close public SSH

1. User: install Tailscale on the computer and sign in (`winget install tailscale.tailscale`, the
   Mac App Store, or tailscale.com/download).
2. On the devbox: `ssh -t devbox sudo tailscale up --hostname=devbox`. It prints a sign-in link:
   the user opens it.
3. User: Tailscale admin console, Machines, `devbox`, **Disable key expiry**. Otherwise the devbox
   leaves the network after 180 days and only the provider console is left.
4. In `~/.ssh/config`, set the `devbox` block's `HostName` to `devbox` (MagicDNS) or to the
   address from `ssh devbox tailscale ip -4`. Check `ssh devbox true`.
5. Close public SSH: `ssh -t devbox 'bash ~/devbox-setup/30-root-lockdown.sh'`. It refuses while an SSH
   session that does not come through Tailscale is open: close those first (including desktop app
   sessions opened on the public IP).

Lock-out rescue: provider web console, then `sudo ufw allow OpenSSH`.

## Phase 4: connect the desktop app

The user, in the desktop app: **Code** tab, environment menu under the prompt box, **New
environment**, **SSH** (labels as of late 2026, they may move):

| Field | Value |
|---|---|
| SSH host | `devbox` (taken from `~/.ssh/config`) |
| SSH key | empty |
| Worktree folder | `~/worktrees` |
| Folder for a session | `~/dev/<project>` |

On first connection the app installs its own engine under `~/.claude/remote/` on the devbox and
shows the host key: same fingerprint as in Phase 2. Sessions in that environment run on the devbox.
There is no Browser pane in SSH sessions: forward ports instead (see Daily use).

## Phase 5: the logged-in Chrome

1. `ssh devbox devbox-browser login` (Chrome restarts without its debugging port, because Google
   often refuses sign-in in a Chrome that has one).
2. The user opens `http://devbox:6080/vnc.html` from a machine on the tailnet. Password:
   `ssh devbox devbox-browser password`. Without Tailscale: `ssh -N -L 6080:localhost:6080 devbox`
   and `http://localhost:6080/vnc.html`.
3. The user signs in to the sites agents should use. Advise against banking and anything where an
   injected instruction could cost money: every session can drive this browser.
4. `ssh devbox devbox-browser normal` hands it back to agents (debugging port 9222, local only).

Check: in a devbox session, ask the `chrome` MCP to open a site the user signed in to and confirm
the account is visible, without reading private content. The task bar icon and the right-click
menu of the screen open this Chrome; it is also the devbox's default browser.

## Phase 6: mirror the local Claude environment

Goal: a session on the devbox behaves like one on the computer.

1. **Global CLAUDE.md and skills**:
   ```powershell
   powershell -ExecutionPolicy Bypass -File <skill>\client\windows\sync-claude-config.ps1 -Memory
   ```
   ```bash
   bash <skill>/client/unix/sync-claude-config.sh --memory
   ```
   It prepends `<skill>/templates/host-header.md` (what differs on the devbox: paths, browsers,
   screen, continuity, sudo rule) to the local `~/.claude/CLAUDE.md`, merges `~/.claude/skills`
   (without `.venv`, `node_modules`, `.git`), and with `-Memory` copies the auto-memory of the
   local projects folder (`-LocalDevDir`, default `~/Documents/dev`) to the memory of `~/dev` on the
   devbox. Re-run it whenever the local CLAUDE.md or skills change. Edit the header template, not
   the copy on the devbox, which is overwritten. Careful: the skills merge overwrites files that
   were fixed for Linux on the devbox (step 2). Make those fixes portable on the computer side
   (both paths, or paths relative to the skill), or re-run with `-SkipSkills` / `--skip-skills`.
   Likewise `-Memory` overwrites memory files of the same name that devbox sessions updated:
   compare first on a devbox in use.
2. **Skills that need setup**: for each synced skill, look for Python environments
   (`requirements.txt`, `pyproject.toml`), Node packages, binaries and Windows paths in `SKILL.md`.
   Recreate environments on the devbox and fix paths. Install system tools they need (for example
   `ffmpeg`) after asking.
3. **Plugins**: the desktop app installs the user's plugins in SSH sessions, but their **hooks do not
   run there**. For each enabled plugin with `hooks/hooks.json`, clone its source on the devbox at the
   same commit into `~/.claude/hooks-thirdparty/<plugin>`, and merge its hooks into the devbox's
   `~/.claude/settings.json`, with `${CLAUDE_PLUGIN_ROOT}` replaced by that folder and interpreters
   fixed for Linux (`python` to `python3`). Merge with `jq`; keep the existing `devbox-relay guard`
   SessionStart hook. Read hook scripts before enabling them.
4. **MCP servers**: compare `claude mcp list` locally and on the devbox. Re-add user-scope stdio
   servers that make sense on Linux. claude.ai connectors follow the account: nothing to do.
5. **Projects**: clone into `~/dev/<name>` with `gh repo clone`. Copy uncommitted or ignored local
   files that matter (`.env` files only with the user's consent), install dependencies, run a light
   test. Heavy builds belong in Codespaces via gatehaul if installed.
6. **Long migration without the user**: if there is a lot to move, write a work list, then start an
   autonomous session on the devbox with
   [references/setup-agent-prompt.md](references/setup-agent-prompt.md) through `claude-task`.

## Phase 7: sessions that continue with the computer off

1. **CLI sign-in on the devbox** (the relay and Remote Control use it):
   `ssh -t devbox claude`, then `/login`; the user opens the link and pastes the code; `/exit`.
2. **Relay**: already enabled by `20-user-setup.sh`. Check `ssh devbox devbox-relay test` (all
   cases OK) and `ssh devbox devbox-relay status`.
3. **Remote Control server**, once by hand because it asks two confirmations:
   `ssh -t devbox 'cd ~/dev && claude remote-control'`, the user answers `y` twice, then Ctrl+C. Then
   `ssh devbox 'touch ~/.config/devbox/rc-accepted && systemctl --user enable --now devbox-rc'`.
   In claude.ai/code or the phone app, the environment named after the folder and the host (for
   example `dev · <hostname>`) now starts sessions on the devbox. Pick the **Auto** permission mode
   there for sessions that should progress alone. claude.ai may ask the user to sign in again to
   verify the device.
4. Optional real test, with the user: start a small task in a Desktop session that will stop on a
   permission question, the user quits the desktop app, waits about 30 minutes, reopens it; the log
   `~/dev/_relay/log.md` shows the relay, `claude agents` on the devbox shows `relay · <name>`, and
   the reopened original session says it was relayed.

## Phase 7b (optional): the devbox's files in the computer's file manager

Sessions write reports, PDFs and images on the devbox, where the user cannot open them from the
desktop app. Offer an SMB share of the dev user's home, reachable only from the tailnet (SMB3 with
signing and encryption, no guest, ufw drops everything that is not on `tailscale0`):

1. `ssh -t devbox 'sudo bash ~/devbox-setup/40-file-share.sh <user>'`
2. The user picks a password used only for this share: `ssh -t devbox sudo smbpasswd -a <user>`.
3. The user maps it. Windows: `net use Z: \\devbox\<user> /persistent:yes`, user name
   `devbox\<user>` (or Explorer, This PC, Map network drive). macOS: Finder, Go, Connect to Server,
   `smb://devbox/<user>`. If `devbox` does not resolve, use the address from `tailscale ip -4`.

Files keep their Linux owner, so sessions and the user can edit the same files. Remind the user that
anything on this drive can be read and changed by every session on the devbox.

## Phase 8: final check

Run and report each line:

```bash
ssh devbox 'claude --version; gh auth status 2>&1 | head -3; claude mcp list'
ssh devbox 'systemctl --user is-active devbox-vnc devbox-wm devbox-novnc devbox-panel devbox-chrome devbox-relay devbox-rc'
ssh devbox 'devbox-browser status; devbox-relay test | tail -1; free -h; df -h ~'
ssh devbox 'grep -c ANTHROPIC_API_KEY ~/.bashrc ~/.profile 2>/dev/null; sudo ufw status'
```

Expected: every service `active` (`devbox-rc` only after Phase 7), MCP servers `chrome` and
`playwright` connected, no API key, ufw allowing only `tailscale0` (and 41641/udp).
Then tell the user what is ready, what they still have to do, and how to reach each part.

## Daily use (tell the user)

- See a dev server: run it on `127.0.0.1:<port>` on the devbox, then on the computer
  `ssh -N -L <port>:localhost:<port> devbox` and open `http://localhost:<port>`.
- Long task in tmux: `claude-task start <name> ~/dev/<project> "<prompt>" [--rc] [--mode auto]`,
  then `claude-task list | show | send | stop`; `tmux attach -t ct-<name>` (Ctrl+b d to leave).
- Hand a session to the background on purpose:
  `claude --resume <id> --fork-session --bg --remote-control "<name>" --permission-mode auto "<prompt>"`.
- Relay activity: `ssh devbox devbox-relay status`, log in `~/dev/_relay/log.md`.
- Open a file a session wrote: the mapped drive from Phase 7b (for example `Z:\dev\<project>\...`).
- Update tools: `PW_MCP_VERSION=<v> INSTALL_GATEHAUL=1 GATEHAUL_VERSION=<tag> bash ~/devbox-setup/20-user-setup.sh`.
- A powered-off server is usually still billed.
