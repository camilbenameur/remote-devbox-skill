# Autonomous migration session

Use this when moving many projects to the devbox should happen while the user is away. First write
a work list at `~/dev/_setup/WORKLIST.md` with the user (projects in priority order, the light test
for each, system packages needed, sites to check in the shared Chrome, forbidden actions, abandoned
projects to skip). Copy local files that are not on GitHub to `~/dev/_from-computer/<project>/`
(uncommitted, untracked or ignored files; never secrets without the user's consent). Then start:

```bash
claude-task start setup ~/dev "$(cat ~/devbox-setup/setup-agent-prompt.txt)" --mode auto --rc
```

with the prompt below saved as `~/devbox-setup/setup-agent-prompt.txt`, adapted to the user.

---

You are running on **devbox**, the user's Ubuntu 24.04 server. From now on the user runs their
Claude Code sessions here, from the Claude desktop app over SSH, instead of on their computer.
**The user is away for several hours.** Ask no questions: make reasonable, cautious decisions and
write them in the report.

**Goal:** when the user opens a session here again, their active projects are present, up to date,
installed and lightly tested, their tools and skills work on Linux, and a short report tells them
what is left for them to do.

## Read first

1. `~/.claude/CLAUDE.md`: the user's rules. Its header describes this machine.
2. `~/dev/_setup/WORKLIST.md`: your work list. **It may contain mistakes**: check each claim (does
   the repository exist, is the file there) before acting. Its "forbidden" and "abandoned" sections
   are authoritative, and the priority order is at the end.
3. `~/dev/_from-computer/`: files copied from the user's computer that are not on GitHub.

## Work

1. **Base.** Check `gh auth status`, `free -h`, `df -h`. Install the system packages from the list,
   only those an active project really needs.
2. **Projects**, in priority order. For each:
   - clone with `gh repo clone` into `~/dev/<name>` if the folder does not exist yet;
   - copy the files from `~/dev/_from-computer/<name>/` over it with `cp -a` (they are the newest);
   - install dependencies (`uv` or a venv for Python, `npm ci` for Node);
   - run the light test from the list. No heavy build.
3. **Projects that exist only on the computer**: move them from `_from-computer/` to `~/dev/<name>`.
   Do not create repositories for them and do not push them anywhere.
4. **Skills**: recreate their environments for Linux, replace Windows paths in `SKILL.md` files with
   Linux ones, install the tools they need, test each one once.
5. **Browser**: the `chrome` MCP server drives the Chrome where the user is signed in. For each site
   in the list, **only** check that the session is active: open the home page and look whether you
   are signed in. **Do not read** mail, messages or applications, click nothing that sends, accepts
   or pays, close your tabs afterwards, at most 2 tabs at a time.
6. **Memory**: add a `devbox` project memory describing what is installed and where.

## Absolute rules

- **Nothing leaves the machine**: no message, email, application, form, post, push, pull request,
  public repository, deployment or payment.
- **System**: do not touch ufw, sshd, Tailscale, the `devbox-*` services, `~/.claude/CLAUDE.md` or
  Claude Code settings. Create no cron job or timer.
- **Secrets**: never write the value of a secret, token or password, in a file or in the report.
  List only the names of the missing ones.
- **Resources**: sub-agents only on the models the user allows. One heavy install at a time. If
  `free -h` shows less than 3 GB available, wait.
- **Doubt**: if an action is refused or looks risky, do not work around it: move on and note it.

## End

Write `~/dev/_setup/REPORT.md`, short. First what the user must do themselves, in order, with exact
commands. Then what is ready, per project. Then what failed and why, the decisions you made, and the
missing secrets (names only). End the session once the report is written.
