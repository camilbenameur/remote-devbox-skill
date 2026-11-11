# How it works

What follows was observed with the Claude desktop app and Claude Code 2.1 in November 2026. The
internals of the app's SSH sessions are not a public interface: re-check them after big updates.

## The pieces

```
Computer (Windows or macOS)            Devbox (Linux server, on a Tailscale tailnet)
+----------------------------+         +----------------------------------------------------+
| Claude desktop app         |  SSH    | ~/.claude/remote/   engine + helper installed by   |
|  Code tab = interface only |-------->|                     the app ("server --serve")     |
|                            |         | helper "--bridge"   lives while the app is connected|
| Tailscale                  |         | Claude Code session: shell, tests, MCP servers     |
+----------------------------+         |   chrome      -> shared logged-in Chrome (CDP 9222)|
                                       |   playwright  -> blank isolated Chrome per session |
claude.ai/code, phone app              | Xtigervnc :1 + openbox + tint2, noVNC on :6080      |
+----------------------------+         | devbox-relay  (systemd user service)               |
| sessions on "dev . host"   |<------->| devbox-rc     (claude remote-control, in tmux)     |
+----------------------------+         | ~/.claude: CLAUDE.md, skills, memory, settings.json|
                                       +----------------------------------------------------+
```

## A desktop session over SSH

1. The app connects with the `devbox` alias from `~/.ssh/config`. On first use it installs its
   engine under `~/.claude/remote/` and starts a helper daemon (`.../srv/<hash>/server --serve`).
2. Each session is a Claude Code process on the devbox. The app gives it the user's sign-in token and
   **refreshes it** while it is connected. Nothing is billed to an API key.
3. The session reads the devbox's `~/.claude`: global `CLAUDE.md`, skills, memory under
   `~/.claude/projects/<folder-key>/memory`, user-scope MCP servers, and hooks from
   `~/.claude/settings.json`. Plugins come from the app, but **plugin hooks are not sent**: declare
   them in the devbox settings (SKILL.md, Phase 6).
4. While the app is connected, a helper process with `--bridge` in its command line exists on the
   devbox. Its absence is how `devbox-relay` knows the app is gone.
5. When the app comes back, it restarts its sessions on the devbox by itself ("Claude Code was
   restarted on the remote host").

## When the computer is turned off

The SSH connection drops (sshd notices within about 3 minutes: `ClientAliveInterval 30`,
`ClientAliveCountMax 6`). The session process keeps running, because the dev user has systemd
linger. It can finish its turn on its own. What it cannot do any more:

- get a fresh sign-in token, so it eventually fails with `401` errors;
- get an answer to a permission question, so it waits forever.

### devbox-relay

A small stdlib Python service (`host/bin/devbox-relay`, `devbox-relay.service`), polling every 30 s:

1. **App absent**: no `--bridge` helper for 10 minutes.
2. For each session from `claude agents --json` that was active within 15 minutes before the app
   left (and is less than 24 hours old), it reads the session transcript and decides:
   - **auth**: `401` API errors for more than 5 minutes;
   - **dead**: no process any more while a turn was not finished;
   - **waiting**: status `waiting` with no activity for 15 minutes.
   A turn the user interrupted on purpose (`[Request interrupted`) or a finished turn is left alone.
3. **Relay**: `claude --resume <id> --fork-session --bg --remote-control "relay · <name>"
   --permission-mode auto <prompt>`. The fork has the whole conversation, runs in the background
   with the devbox CLI's own sign-in (which refreshes itself), and is visible in `claude agents`,
   claude.ai/code and the phone app. Its prompt tells it to finish the task and to stop before any
   decision that belongs to the user (sending, publishing, paying, deleting).
   The fork is also **pinned** (its short id is added to `~/.claude/jobs/pins.json`): the Claude
   background daemon retires an unpinned idle session after about 8 h (`bg retire ...: idle-prompt`
   in `~/.claude/daemon.log`) and then exits, which shows as "Remote Control disconnected" on
   claude.ai/code. Pinned sessions are exempt; the threshold itself cannot be configured.
4. Only once the fork exists, the original is stopped (SIGTERM) for the auth and waiting cases.
5. Each relay is written to `~/dev/_relay/log.md`; state is in `~/.local/state/devbox-relay`. A
   session is relayed again only if its conversation moved on; failures are retried up to 3 times.
   Sessions named `relay · ...` are never relayed.

### The guard hook

When the app comes back and restarts the original session, the `SessionStart` hook
`devbox-relay guard` injects a message: this session was relayed, here is the fork's last answer,
do not run any command, tell the user and wait. Without it, the original would redo the work
(and could be confused by files the fork changed since).

### devbox-rc

`claude remote-control --spawn same-dir --permission-mode auto --capacity 6`, started in
`tmux -L rc` by `devbox-rc.service`. It registers an environment on claude.ai (named after the
folder and the host). Sessions started there run on the devbox from the first message, with the
devbox's `CLAUDE.md`, memory, MCP servers and the user's claude.ai connectors, and do not depend on
any browser tab staying open.

## The shared Chrome

- Profile `~/.config/devbox-chrome` (Chrome 136 and later only open a debugging port on a
  non-default profile), `--password-store=basic`, on display `:1`.
- Normal mode: `--remote-debugging-port=9222` on 127.0.0.1; the `chrome` MCP server attaches with
  `--cdp-endpoint`, so every session shares the same cookies and tabs.
- Login mode (`devbox-browser login`): same profile without the debugging port, for the user to sign
  in through noVNC.
- noVNC (websockify) listens on the Tailscale address only, port 6080; VNC itself on localhost 5901
  with a random 8-character password.

## Limits

- The token-expiry path is covered by the relay's self-tests and by real 401 records, but the exact
  delay before a Desktop session's token runs out was not measured.
- A background command started by a session before the cut does not notify the fork when it ends.
- The relay acts only for sessions it saw active shortly before the app left. A session the user
  stopped is not resumed.
- Everything here relies on undocumented behaviour of the desktop app's SSH sessions.
