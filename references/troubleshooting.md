# Troubleshooting

Problems met while building the reference setup, with their fix.

## SSH and network

| Symptom | Cause and fix |
|---|---|
| `ssh-keyscan` on Windows fails with "unsupported KEX sntrup761" | Windows OpenSSH 9.5 does not support that key exchange in `ssh-keyscan`. The setup script asks `ssh -o StrictHostKeyChecking=ask` instead. |
| The desktop app refuses the SSH environment | Windows OpenSSH older than 9.4: `winget install Microsoft.OpenSSH.Preview`. The key must have no passphrase. |
| `scp` from Git Bash hangs on Windows | Use `C:\Windows\System32\OpenSSH\scp.exe`. |
| Locked out after `30-root-lockdown.sh` | Provider web console, sign in, `sudo ufw allow OpenSSH`. |
| The devbox left the tailnet after months | Key expiry: Tailscale admin console, Machines, Disable key expiry; then `sudo tailscale up` from the provider console. |

## Server

| Symptom | Cause and fix |
|---|---|
| `apt` waits on a lock right after the first boot | cloud-init is still running. The bootstrap waits for `cloud-init status --wait` and uses a 600 s lock timeout. A cloud-init error at boot on some providers is harmless. |
| `modprobe zram` fails | Some provider kernels have no zram (Contabo). Swap only; the script skips zram. |
| `devbox-rc` keeps restarting | Another `claude remote-control` already serves `~/dev` (for example one started by hand in tmux). Stop it, then `systemctl --user restart devbox-rc`. |
| `devbox-rc` never starts | The one-time confirmations were not given: run `cd ~/dev && claude remote-control` by hand once, answer `y` twice, then create `~/.config/devbox/rc-accepted`. |
| claude.ai says "Sign in again to verify your device" | Remote Control's trusted devices check. The user signs in again on claude.ai. |

## Browser and screen

| Symptom | Cause and fix |
|---|---|
| Chrome ignores `--remote-debugging-port` | Chrome 136 and later need a non-default `--user-data-dir`. `devbox-chrome` uses `~/.config/devbox-chrome`. |
| Google refuses to sign in ("This browser may not be secure") | Sign in in login mode (`devbox-browser login`), which has no debugging port, then `devbox-browser normal`. |
| A Chrome opened from the screen has no accounts | It used the default profile. Use the task bar icon, the right-click menu or `devbox-browser open [url]`. |
| noVNC asks for a password | The VNC password: `devbox-browser password`. |
| noVNC unreachable | It listens on the Tailscale address only. Without Tailscale: `ssh -N -L 6080:localhost:6080 devbox`. |
| YouTube: "Sign in to confirm you're not a bot" | Datacenter IPs are blocked. `yt-cookies` exports the YouTube cookies of the logged-in Chrome to `~/.config/devbox/youtube-cookies.txt`; pass `--cookies` to yt-dlp, and install Deno (recent yt-dlp needs a JavaScript runtime for YouTube). |

## Sessions

| Symptom | Cause and fix |
|---|---|
| A `claude-task` session exits right away | The folder trust question defaults to "No, exit". `claude-task` moves to "Yes, I trust this folder" before pressing Enter; check `claude-task show <name>`. |
| Plugin hooks do not fire in SSH sessions | The app does not send them. Declare them in the devbox's `~/.claude/settings.json` (SKILL.md, Phase 6). |
| Usage is billed to the API | `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` is set on the devbox. Remove it; check with `/status` in a session. |
| A relayed original session starts redoing the work | The guard hook is missing: `jq .hooks.SessionStart ~/.claude/settings.json` must contain `devbox-relay guard`. Re-run `20-user-setup.sh`. |
| The relay did nothing | `devbox-relay status` shows what it sees. A session that finished its turn, was interrupted, or was idle long before the app left is not relayed, by design. |
| `devbox-relay test` fails | Claude Code's output format may have changed: read the failing case and the transcript format in `~/.claude/projects/*/*.jsonl`. |
