# Backup of the devbox

A devbox quickly holds work that exists nowhere else: unpushed commits, repositories without a
remote, data written by scheduled jobs, the signed-in Chrome profile, Claude memory and session
history, keys and tokens. `host/50-backup.sh` sets up a nightly backup of it with
[restic](https://restic.net): encrypted before it leaves the server, incremental and
deduplicated, with a history of snapshots and file-by-file restore.

| | |
|---|---|
| What | the dev user's home (without caches, virtual environments, `node_modules`, Claude CLI binaries, Chrome caches), `/etc`, `/root`, `/usr/local`, `/usr/share/keyrings`, `/var/lib/tailscale`, `/var/lib/samba`, `/var/spool/cron`, `/var/backups` (with a rebuild manifest: packages, enabled services, crontab, user ids, state of every repository in `~/dev`) |
| When | every night around 04:30 (`devbox-backup.timer`), at the next boot if the machine was off |
| History | one snapshot per day for 14 days, per week for 8 weeks, per month for 12 months |
| Checks | on Sundays, prune and `restic check` reading back 2% of the data |
| Alerts | ntfy and/or a command, when a run fails or when the last success is older than 30 h (checked daily at 13:00) |
| Size | on a well-used devbox: about 13 GB read, 5 GB stored after deduplication and compression, then a few tens of MB per night |

**Before setting it up, tell the user what leaves the server**: the signed-in Chrome profile
(cookies, saved passwords), SSH keys, tokens in `~/.claude`, `~/.config` and project `.env`
files, the Tailscale identity, `/etc`. It is encrypted, but see [Limits and
security](#limits-and-security). Anything can be left out (section 4, `excludes.local`). Ask which
cloud account to use: a personal one, not a shared or work account. It is also a system change
(packages, root services): get the user's yes. Sign-in and consent screens are the user's.

## 1. Choose the destination

The repository must be off the server's provider: a backup that disappears with the server, or
with the provider account, is not one. Check current prices on the provider's page.

| Destination | restic repository | Notes |
|---|---|---|
| **Google Drive** (tested end to end) | `rclone:gdrive:devbox-restic` | Uses the account's storage (15 GB shared with Gmail and Photos on a free account, more with Google One). Needs a **dedicated OAuth client** and a site the user owns for its home page (section 2). |
| S3-compatible: Cloudflare R2, Backblaze B2, Wasabi, Scaleway, AWS... | `s3:https://<endpoint>/<bucket>/devbox` | Keys in `credentials.env` (section 3). R2 and B2 have a small free tier. Not tested end to end with this skill. |
| SFTP: Hetzner Storage Box, a NAS, another server | `sftp:<user>@<host>:devbox` | A key for root (`/root/.ssh`) and the host in `/root/.ssh/known_hosts`. Not tested end to end. |
| A separate disk mounted on the devbox | `/mnt/<disk>/devbox-restic` | Not off the provider: only against mistakes, not against losing the server. |

The provider's own snapshot or "auto backup" option is a fine complement (whole-machine rollback),
not a replacement: same provider, whole disk only.

## 2. Google Drive with a dedicated OAuth client

rclone's built-in Google client is shared by every rclone user and is often throttled
(`rateLimitExceeded`): in November 2026, a 5 GB first upload with it stalled for minutes at a time
and failed. A client of the user's own has its own quota (the same upload took 16
minutes, without a single error) and is free.

**The user must own a website** (any page on a domain they control, e.g. their personal site):
Google asks for an app home page and a privacy policy link on an authorized domain before it lets an
app be published, and an unpublished app ("Testing") loses its sign-in after 7 days. Without a
site, choose another destination (section 1). As of November 2026, `drive.file` is a
non-sensitive scope ([Google's scope list](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)):
the app could be published without submitting it for review, the consent screen showed no
"unverified app" warning, and the client sees and changes only the files it created, not the rest
of the Drive.

In the user's Google account, through the shared Chrome (`chrome` MCP) with the user watching the
screen, or by the user:

1. console.cloud.google.com: new project (for example `devbox-backup`, no organization).
2. APIs & Services, Library: **Google Drive API**, Enable.
3. Google Auth Platform, Get started: app name, the user's email as support and contact address,
   audience **External**, accept the API Services User Data Policy (the user's call), Create.
4. Data access: Add or remove scopes, paste `https://www.googleapis.com/auth/drive.file`, Add to
   table, Update, **Save**. A cookie banner at the bottom of the console can swallow the Save
   click: dismiss it first.
5. Branding: app home page and privacy policy link on the user's site; the authorized domain is
   added from the error the form shows. Save. The links are reviewed only if the app is submitted
   for verification.
6. Audience: **Publish app**, confirm. The status must read **In production**.
7. Clients, Create client: type **Desktop app**, any name, Create, **Download JSON**. In the shared
   Chrome it lands in `~/Downloads` on the devbox. Do not read it into the chat. Google shows the
   secret only now; later, "Add secret" on the same client makes a new one.

Then sign rclone in with that client, as root, with `host/backup/devbox-gdrive-auth` (it never
prints the token or the secret, and it deletes the downloaded file):

```bash
ssh devbox 'sudo bash ~/devbox-setup/backup/devbox-gdrive-auth start ~/Downloads/client_secret_*.json'
```

It installs rclone if needed and prints a link `http://127.0.0.1:53682/auth?state=...`, valid for
15 minutes (`start` again, without argument, makes a new one). Open it in the shared Chrome (same host);
without it, run `ssh -N -L 53682:localhost:53682 devbox` on the computer and open the link there.
The user picks the account and approves "see, edit, create and delete only the specific Google
Drive files you use with this app". Then:

```bash
ssh devbox 'sudo bash ~/devbox-setup/backup/devbox-gdrive-auth finish'
```

It waits up to two minutes for the consent (exit code 3: not given yet, run it again), writes
`/etc/devbox-backup/rclone.conf` (remote `gdrive`, scope `drive.file`, `use_trash=false` so that
pruned files do not pile up in the Drive trash) and shows the account's quota.

With `drive.file`, **only this client sees the backup**: keep the Cloud project. If it is lost, sign
in with the full `drive` scope instead (any client sees every file), or download the
`devbox-restic` folder from drive.google.com and restore from the local copy.

## 3. Other backends: credentials.env

The keys go into `/etc/devbox-backup/credentials.env`, root 600, typed by the user so that they
never pass through the chat:

```bash
ssh -t devbox "sudo install -d -m 700 /etc/devbox-backup && sudo sh -c 'umask 077; cat > /etc/devbox-backup/credentials.env'"
```

The user pastes the lines, then Enter and Ctrl-D. restic reads the usual variables; they reach
restic only, not the commands the backup runs as the dev user.

**Cloudflare R2** (not tested end to end): in the Cloudflare dashboard, R2, create a bucket (for
example `devbox`), then Manage R2 API tokens, Create API token, permission **Object Read & Write**,
applied to that bucket only. Note the access key ID, the secret access key (shown once) and the
account ID. `credentials.env`:

```bash
AWS_ACCESS_KEY_ID=<access key id>
AWS_SECRET_ACCESS_KEY=<secret access key>
AWS_DEFAULT_REGION=auto
```

Repository: `s3:https://<account id>.r2.cloudflarestorage.com/devbox/restic` (for a bucket created
in the EU jurisdiction: `https://<account id>.eu.r2.cloudflarestorage.com`).

**Backblaze B2** (native API, `b2:<bucket>:devbox`): `B2_ACCOUNT_ID=<key id>` and
`B2_ACCOUNT_KEY=<application key>`, with an application key restricted to the bucket. Other
S3-compatible providers: the R2 variables with their endpoint and region.

A key restricted to one bucket limits the damage if the devbox is taken over; a key that cannot
delete would also protect the history, but then pruning has to run elsewhere.

## 4. Install and first backup

On a devbox set up before this feature, send the host folder again first (as the setup does):

```bash
ssh devbox 'rm -rf ~/devbox-setup' && scp -r <skill>/host devbox:devbox-setup
ssh devbox "chmod -R go-rwx ~/devbox-setup && find ~/devbox-setup -type f -exec sed -i 's/\r\$//' {} +"
```

Then, once:

```bash
ssh -t devbox 'sudo INIT=1 bash ~/devbox-setup/50-backup.sh <user> rclone:gdrive:devbox-restic'
ssh devbox 'sudo systemctl start --no-block devbox-backup'
```

`INIT=1` generates the restic password and creates the repository, for the very first install
only: without it the script refuses both, so that a rebuilt host whose sign-in does not see the old
repository cannot start a new one beside it. Follow the first backup (15 to 30 minutes for about
5 GB stored) without blocking:

```bash
ssh devbox 'sleep 5; systemctl show devbox-backup -p ActiveState -p Result'   # activating while it runs
ssh devbox 'sudo journalctl -u devbox-backup -n 30 --no-pager'
```

Done when `ActiveState=inactive` and `Result=success`, and `sudo devbox-backup status` shows a
snapshot from today. `Result=exit-code` is a failure: the journal says why.

**The restic password** is in `/etc/devbox-backup/restic-password`. Without it the backup cannot be
read and nobody can recover it. The user prints it themselves and saves it in a password manager,
off the devbox: `ssh -t devbox sudo cat /etc/devbox-backup/restic-password`. Do not copy it into the
chat or into a file the dev user can read. Once saved: `sudo rm /var/lib/devbox-backup/password-unsaved`
(until then, `devbox-backup status` and `50-backup.sh` remind it).

**Options** in `/etc/devbox-backup/backup.env` (literal values; `50-backup.sh` never overwrites it).
The user edits it with `ssh -t devbox sudoedit /etc/devbox-backup/backup.env`, so that an ntfy topic
does not pass through the chat:

| Variable | Use |
|---|---|
| `NOTIFY_URL` | an [ntfy](https://ntfy.sh) topic URL (free; the ntfy app on the phone subscribes to the topic, keep the name long and random) |
| `NOTIFY_CMD` | a shell command run as the dev user, the message appended as its last argument, e.g. `NOTIFY_CMD="/home/<user>/.local/bin/my-notify --title Backup"` |
| `BACKUP_PATHS` | the paths to back up, space-separated (default above) |
| `KEEP_DAILY`, `KEEP_WEEKLY`, `KEEP_MONTHLY` | retention |
| `MAX_AGE_HOURS` | the watchdog alerts beyond this age of the last success (30) |
| `TOOL_REMOTE` | rclone repositories only: a folder, e.g. `gdrive:devbox-backup-tools`, that receives after each run a plain-text copy of this runbook and the scripts (no secrets), readable when the devbox is gone |

Set an alert: without one, a failing backup shows only in the journal. Test it:
`sudo ALERT_RETRY_DELAY=1 devbox-backup alert`.

**Your own exclusions**: `/etc/devbox-backup/excludes.local` (same syntax as
`host/backup/excludes`, which the script overwrites), or an empty `.nobackup` file in a folder.

## 5. Daily use

```bash
sudo devbox-backup status                                     # last success, snapshots, next runs
sudo systemctl start --no-block devbox-backup                 # back up now (with the service limits)
sudo devbox-backup restic snapshots
sudo devbox-backup restic ls latest /home/<user>/dev/<project> | head
sudo devbox-backup restic restore latest --target /tmp/restore --include /home/<user>/dev/<project>
sudo devbox-backup restic dump latest /home/<user>/.claude/CLAUDE.md > /tmp/CLAUDE.md
sudo mkdir -p /mnt/restic && sudo devbox-backup restic mount /mnt/restic   # every date as folders
```

Restore next to the live files (`--target /tmp/...`; the files land under
`<target>/<absolute path>`), then copy back what is needed. restic 0.16 does not accept `--include`
and `--exclude` in the same restore: use several `--include`. Replace `latest` with a snapshot ID
to go back to a date. While a restore or mount holds the repository, the nightly run waits up to
30 minutes for it.

## 6. Rebuild after losing the devbox

The runbook is in this public repository, and with `TOOL_REMOTE` also next to the backup.

1. **New server**: SKILL.md phases 1 to 3, with the **same dev user name** as before. The setup
   leaves the host folder in `~/devbox-setup`.
2. **Access to the repository**: Google Drive, the rclone part of section 2 with the **same client**
   (Cloud console, Clients: "Add secret", download the JSON again). The shared Chrome is not set
   up yet: use the SSH tunnel for the consent link. Other backends: section 3 again, or the SFTP
   key.
3. **Password**: `ssh -t devbox "sudo install -d -m 700 /etc/devbox-backup && sudo sh -c 'umask 077; cat > /etc/devbox-backup/restic-password'"`,
   the user pastes it, Enter, Ctrl-D.
4. **Tool**: `sudo bash ~/devbox-setup/50-backup.sh <user> <repository>` (no `INIT`: it must find
   the existing repository), then right away `sudo systemctl stop devbox-backup.timer` (do not back
   up a half-restored machine). Check the user ids:
   `sudo devbox-backup restic dump latest /var/backups/devbox-staging/manifest/user-ids.txt` against
   `id <user>`.
5. **Home folder**. The restore overwrites the new home's files with the old ones, including
   `~/.ssh/authorized_keys`: keep the new key, then restore, then merge it back:
   ```bash
   cp ~/.ssh/authorized_keys /tmp/new_authorized_keys
   sudo devbox-backup restic restore latest --target / --include /home/<user>
   cat /tmp/new_authorized_keys >> ~/.ssh/authorized_keys && sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys
   sudo devbox-backup restic restore latest --target /tmp/r --include /etc --include /var --include /root --include /usr
   ```
   If the ids differed in step 4: `sudo chown -R <user>:<user> /home/<user>`.
6. **System, piece by piece** from `/tmp/r`. Do not copy `/etc` wholesale: `fstab`, `hosts`,
   `netplan` and `cloud` belong to the provider. Take back:
   - `/etc/ssh/ssh_host_*` (same host fingerprint, no warning on the computer), then
     `sudo systemctl restart ssh`;
   - `/etc/sudoers.d`, `/etc/systemd/system/*`, `/etc/apt/sources.list.d`, `/etc/apt/keyrings`,
     `/usr/share/keyrings`;
   - the crontab: `sudo crontab -u <user> /tmp/r/var/spool/cron/crontabs/<user>`;
   - file share: `/etc/samba`, then `sudo systemctl stop smbd`, copy
     `/tmp/r/var/lib/samba/private/*.tdb`, `sudo systemctl start smbd`; or simply
     `sudo smbpasswd -a <user>` again;
   - Tailscale, **only if the old machine is gone for good** (otherwise both claim the same
     identity): `sudo systemctl stop tailscaled`, copy `tailscaled.state` into
     `/var/lib/tailscale/`, `sudo systemctl start tailscaled`. When in doubt,
     `sudo tailscale up --hostname=devbox`.
7. **Project dependencies before the services**: `uv sync` or `pip install -r requirements.txt`,
   `npm ci`, in each project. Missing packages, from the manifest in
   `/tmp/r/var/backups/devbox-staging/manifest/` (root only: read it with `sudo`):
   ```bash
   sudo cat /tmp/r/var/backups/devbox-staging/manifest/apt-manual.txt \
     | grep -Ev '^(base-files|cloud-init|grub|shim|linux-|ubuntu-|login$)' \
     | sudo DEBIAN_FRONTEND=noninteractive xargs apt-get install -y --ignore-missing
   ```
   `git-repos.tsv` lists every repository of `~/dev` with its branch, remote, number of unpushed
   commits and modified files at backup time.
8. **User services**: their units and enable links came back with `~/.config/systemd/user`.
   `sudo loginctl enable-linger <user>`, then as the user
   `systemctl --user daemon-reload && systemctl --user list-timers --all` (compare with
   `systemd-user-timers.txt`). Re-run `20-user-setup.sh` for the Claude CLI and the tools that are
   not backed up, then SKILL.md phases 4 to 7.
9. **Chrome**: the profile `~/.config/devbox-chrome` is back, signed in. If Chrome reports a damaged
   cookie database, stop it, `sudo cp /tmp/r/var/backups/devbox-staging/chrome-sqlite/Cookies
   ~/.config/devbox-chrome/Default/` and `sudo chown <user>:<user> ~/.config/devbox-chrome/Default/Cookies`. The other databases (passwords, history) are locked by Chrome
   during the backup and exist only as the raw copy.
10. **Restart the backup**: `sudo systemctl start devbox-backup.timer devbox-backup-watchdog.timer`,
    and delete `/tmp/r` and `/tmp/new_authorized_keys`.

## Limits and security

- The data is encrypted before it leaves the server, so the storage provider, or someone who takes
  over the **cloud account only**, cannot read it (they can delete it).
- The restic password and the cloud token also sit on the devbox, readable through sudo, which the
  dev user has without a password. Someone who takes over the **devbox** can read every backup and
  delete them. The user's copy of the password is for rebuilding, not a protection. Against
  deletion, copy the repository from time to time to a disk the user owns (it is just files), or
  use a key that cannot delete (section 3).
- restic reads live files. Append-only logs and SQLite databases written during the run are copied
  as they are at that moment; Chrome's cookie database also gets a consistent copy.
- What is not backed up comes back by reinstalling: virtual environments, `node_modules`, caches,
  the Claude CLI and other downloaded binaries, Google Chrome itself (`/opt/google`).
