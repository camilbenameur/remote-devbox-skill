## Machine: @ALIAS@ (Linux host, SSH sessions of the Claude desktop app)

This file is a copy of the user's global CLAUDE.md from their own computer, pushed by
`client/*/sync-claude-config.*` of the remote-devbox repo: do not edit it here, it will be overwritten.
On this machine:
- Projects are git clones in `~/dev/<project>`. A path under `@LOCAL_DEV_DIR@` in the text
  below maps to `~/dev/<x>` on this host.
- If gatehaul is installed, it is `~/.local/bin/gatehaul` (Linux binary), not `gatehaul.exe`.
- There is no Browser pane, no Claude in Chrome and no computer use in these sessions. Two MCP
  servers replace them:
  - `chrome`: the host's Chrome, where the user is signed in to their accounts. All sessions
    share this browser: open your own tab and do not close other sessions' tabs. Before any
    send, post, application or message, show what you are about to do and wait for the user's
    approval. If a page asks for a login, never type a password: ask the user to run
    `devbox-browser login`, sign in through the screen (see below), then `devbox-browser normal`.
  - `playwright`: a blank, isolated Chrome per session, with no accounts. Use it for tests,
    public scraping, anything that does not need a signed-in browser.
- To let the user see the host's Chrome screen: http://@ALIAS@:6080/vnc.html from one of their
  tailnet machines (password: `devbox-browser password`). `devbox-browser status` gives the
  exact address.
- YouTube refuses the host's IP without cookies. For the video-transcript skill, add
  `--cookies ~/.config/devbox/youtube-cookies.txt`; if YouTube still refuses, regenerate the file
  with `yt-cookies` (cookies of the signed-in Chrome, never printed or copied elsewhere).
- To show a dev server to the user: make it listen on 127.0.0.1:<port>, then give them the
  command to run on their own computer: `ssh -N -L <port>:localhost:<port> @ALIAS@`.
- Continuity when the user's computer is off, automatic:
  - The `devbox-relay` service watches the desktop app's sessions. When the desktop app has been
    absent for 10 minutes and a session was cut off (expired token, dead process, a question left
    unanswered), it resumes that session by itself in the background, with the whole
    conversation, under the name "relay · <name>" (`claude agents`, claude.ai/code). Log:
    `~/dev/_relay/log.md`.
  - If, at startup, a message says THIS session was relayed: tell the user and do not resume the
    task here without their approval, otherwise it would be done twice.
  - The Remote Control server (`devbox-rc`) hosts the sessions the user starts from claude.ai/code
    or the Claude app on the environment named after this host: they run here and keep going
    without the user's computer.
  - To hand a task off to the background on purpose: `claude --resume <id> --fork-session
    --bg --remote-control "<name>" --permission-mode auto "<prompt>"`, or a new session with
    `claude --bg --remote-control "<name>" ...`. `claude-task` is still available (tmux).
    Never with an API key.
- sudo works without a password: ask the user before any system change (global packages,
  services, firewall, sshd, users).

---

