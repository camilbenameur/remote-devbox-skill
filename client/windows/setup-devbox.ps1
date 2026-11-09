<#
.SYNOPSIS
  Prepares a fresh Ubuntu 24.04 server for Claude desktop app SSH sessions.

.DESCRIPTION
  1. Creates the SSH key ~/.ssh/devbox_ed25519 (empty passphrase: the desktop
     app must be able to connect without prompting).
  2. Has you verify the server host key fingerprint, then authorizes the key
     for the server's initial user (root or ubuntu).
  3. Runs host/10-root-bootstrap.sh (system, security, tools).
  4. Adds the "devbox" alias to ~/.ssh/config, tests the connection, then
     restricts SSH to the dev user (root login disabled).
  5. Runs host/20-user-setup.sh (uv, Claude Code, gh, Playwright MCP, and
     gatehaul with -Gatehaul).
  6. Copies your global CLAUDE.md and your skills (sync-claude-config.ps1).
  If "ssh <alias>" already works, the script resumes from there: it can be
  re-run after a failure, even once SSH is locked down.

.PARAMETER HostAddress
  IP or DNS name of the server.

.PARAMETER InitialUser
  Account you can log in to at first (root or ubuntu).

.PARAMETER DevUser
  Linux user to create for development. Default: your Windows user name,
  lowercased, with characters other than a-z 0-9 _ - removed.

.PARAMETER Alias
  Host alias written to ~/.ssh/config (default: devbox).

.PARAMETER KeyPath
  Private key to create or use (default: ~/.ssh/devbox_ed25519).

.PARAMETER ShowKey
  Only print the public key (to paste into the hosting provider), then exit.

.PARAMETER SkipConfigSync
  Do not copy CLAUDE.md and skills at the end.

.PARAMETER Gatehaul
  Also install the optional gatehaul CLI on the server (INSTALL_GATEHAUL=1).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\client\windows\setup-devbox.ps1 -ShowKey
  Prints the public key to paste at your hosting provider when ordering the server.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\client\windows\setup-devbox.ps1 -HostAddress 203.0.113.10 -InitialUser ubuntu
#>
[CmdletBinding()]
param(
  [string]$HostAddress,
  [string]$InitialUser = 'root',
  [string]$DevUser = (($env:USERNAME).ToLower() -replace '[^a-z0-9_-]', ''),
  [string]$Alias = 'devbox',
  [string]$KeyPath = (Join-Path $env:USERPROFILE '.ssh\devbox_ed25519'),
  [switch]$ShowKey,
  [switch]$SkipConfigSync,
  [switch]$Gatehaul
)

$ErrorActionPreference = 'Stop'
if (-not $DevUser) { $DevUser = 'dev' }
if ($DevUser -notmatch '^[a-z_][a-z0-9_-]*$') { Write-Host "[error] Invalid -DevUser '$DevUser' (use lowercase letters, digits, _ and -)." -ForegroundColor Red; exit 1 }
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent (Split-Path -Parent $here)
$hostDir = Join-Path $repoDir 'host'
$sshDir  = Join-Path $env:WINDIR 'System32\OpenSSH'
$ssh     = Join-Path $sshDir 'ssh.exe'
$scp     = Join-Path $sshDir 'scp.exe'
$keygen  = Join-Path $sshDir 'ssh-keygen.exe'
$userSsh = Join-Path $env:USERPROFILE '.ssh'
$cfgPath = Join-Path $userSsh 'config'
$knownHosts = Join-Path $userSsh 'known_hosts'
$utf8 = New-Object Text.UTF8Encoding $false

function Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Warn([string]$m) { Write-Host "[warning] $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host "[error] $m" -ForegroundColor Red; exit 1 }
function Run([string]$exe, [string[]]$argList, [string]$what) {
  & $exe @argList
  if ($LASTEXITCODE -ne 0) { Fail "$what (code $LASTEXITCODE). You can re-run this script." }
}
function Test-Ssh([string[]]$argList) {
  # Options must come before the destination (the last element of $argList).
  & $ssh -o BatchMode=yes -o ConnectTimeout=20 @argList 'true'
  return ($LASTEXITCODE -eq 0)
}
if (-not (Test-Path $hostDir)) { Fail "Folder not found: $hostDir (run this script from a full copy of the repo)." }
foreach ($d in @($userSsh, (Split-Path -Parent $KeyPath))) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ------------------------------------------------------------ SSH client
Step 'Windows OpenSSH client (the desktop app needs 9.4 or newer)'
if (-not (Test-Path $ssh)) { Fail "OpenSSH not found in $sshDir. Settings > System > Optional features > OpenSSH Client." }
# ssh -V writes to stderr: go through cmd to avoid a PowerShell error.
$ver = cmd /c "`"$ssh`" -V 2>&1"
Write-Host $ver
if ($ver -match 'OpenSSH_for_Windows_(\d+)\.(\d+)') {
  if ([int]$Matches[1] -lt 9 -or ([int]$Matches[1] -eq 9 -and [int]$Matches[2] -lt 4)) {
    Fail 'OpenSSH is too old: install the latest version (winget install Microsoft.OpenSSH.Preview).'
  }
} else { Warn 'Unrecognized OpenSSH version, continuing.' }

# ------------------------------------------------------------ key
Step "SSH key $KeyPath"
if (-not (Test-Path $KeyPath)) {
  # '""' is how to pass an empty passphrase under PowerShell 5.1.
  Run $keygen @('-t', 'ed25519', '-f', $KeyPath, '-N', '""', '-C', 'devbox') 'ssh-keygen failed'
}
$pub = (Get-Content "$KeyPath.pub" -Raw).Trim()
if ($pub -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+( [A-Za-z0-9@._-]+)?$') {
  Fail "Unexpected public key in $KeyPath.pub (comment with special characters?)."
}
if ($ShowKey) {
  Write-Host "`nPublic key to paste at your hosting provider (the 'SSH key' field):`n" -ForegroundColor Green
  Write-Host $pub
  exit 0
}
$keyCore = ($pub -split ' ')[0..1] -join ' '

$cfgText = if (Test-Path $cfgPath) { Get-Content $cfgPath -Raw } else { '' }
$aliasDefined = $cfgText -match "(?m)^\s*Host\s+$([regex]::Escape($Alias))\s*$"
$aliasOk = $aliasDefined -and (Test-Ssh @($Alias))

if ($aliasOk) {
  Step "'ssh $Alias' already works: resuming from there"
  $bootTarget = $Alias
  $bootOpts = @()
} else {
  if (-not $HostAddress) { Fail 'Pass -HostAddress <server ip> (or -ShowKey to print the key).' }
  $target = "$InitialUser@$HostAddress"
  $keyOpts = @('-i', $KeyPath, '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes')

  # ---------------------------------------------------------- server fingerprint
  Step "Fingerprint of server $HostAddress"
  # Windows ssh-keyscan (9.5) cannot handle the sntrup761 key exchange of recent
  # servers: let ssh itself print the fingerprint and ask yes/no.
  & $keygen -F $HostAddress | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Write-Host 'Server already known: ssh will check that its key has not changed.'
  } else {
    Write-Host @"
ssh will print the server's ED25519 fingerprint and ask yes/no.
To be sure, compare it with one seen outside this connection: the hosting
provider's web console (VNC), command  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
Type "yes" if it is identical. The "Permission denied" that follows is expected.
"@
    & $ssh -o StrictHostKeyChecking=ask -o PreferredAuthentications=none -o ConnectTimeout=20 "$InitialUser@$HostAddress" 'true'
    & $keygen -F $HostAddress | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'Stopped: fingerprint not accepted (or server unreachable).' }
  }

  # ---------------------------------------------------------- initial access
  Step "Access to $target"
  if (-not (Test-Ssh ($keyOpts + @($target)))) {
    Write-Host "The key is not authorized yet: enter the password of $InitialUser (given by the hosting provider)."
    $remote = "umask 077; mkdir -p ~/.ssh; grep -qF '$keyCore' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys"
    Run $ssh @('-o', 'StrictHostKeyChecking=yes', $target, $remote) 'Could not authorize the key'
    if (-not (Test-Ssh ($keyOpts + @($target)))) { Fail "Key-based login still does not work for $target." }
  }
  $bootTarget = $target
  $bootOpts = $keyOpts
}

# ------------------------------------------------------------ root bootstrap
Step 'Copying the scripts to the server'
Run $ssh ($bootOpts + @($bootTarget, 'rm -rf /tmp/devbox-setup')) 'remote cleanup'
Run $scp ($bootOpts + @('-r', $hostDir, "${bootTarget}:/tmp/devbox-setup")) 'scp of the host folder'
# In case a Windows editor introduced CRLF line endings.
Run $ssh ($bootOpts + @($bootTarget, "chmod -R go-rwx /tmp/devbox-setup && find /tmp/devbox-setup -type f -exec sed -i 's/\r$//' {} +")) 'line-ending conversion'

Step 'System preparation (10-root-bootstrap.sh, takes 5 to 10 minutes)'
Run $ssh (@('-t') + $bootOpts + @($bootTarget, "sudo bash /tmp/devbox-setup/10-root-bootstrap.sh $DevUser '$pub' $InitialUser")) '10-root-bootstrap.sh failed'

# ------------------------------------------------------------ ~/.ssh/config
Step "Alias '$Alias' in $cfgPath"
if ($aliasDefined) {
  Write-Host "Block 'Host $Alias' already present: leaving it alone."
} else {
  $block = @(
    '',
    "Host $Alias",
    "  HostName $HostAddress",
    "  User $DevUser",
    "  IdentityFile ~/.ssh/$(Split-Path -Leaf $KeyPath)",
    '  IdentitiesOnly yes',
    '  ServerAliveInterval 30',
    '  ServerAliveCountMax 6',
    ''
  ) -join "`r`n"
  [IO.File]::AppendAllText($cfgPath, $block, $utf8)
}
if (-not (Test-Ssh @('-o', 'StrictHostKeyChecking=yes', $Alias))) {
  Fail "Cannot connect with 'ssh $Alias'. SSH is not locked down: $InitialUser keeps access so you can fix it."
}
Write-Host "ssh ${Alias}: OK"

# ------------------------------------------------------------ SSH lockdown
Step "SSH restricted to $DevUser (root and $InitialUser can no longer log in)"
Run $ssh @($Alias, 'rm -rf ~/devbox-setup') 'cleanup of ~/devbox-setup'
Run $scp @('-r', $hostDir, "${Alias}:devbox-setup") 'scp to ~/devbox-setup'
Run $ssh @($Alias, "chmod -R go-rwx ~/devbox-setup && find ~/devbox-setup -type f -exec sed -i 's/\r$//' {} + && sudo rm -rf /tmp/devbox-setup") 'cleanup'
Run $ssh @('-t', $Alias, "sudo bash ~/devbox-setup/10-root-bootstrap.sh --lock-ssh $DevUser") 'SSH lockdown'
if (-not (Test-Ssh @($Alias))) { Fail "ssh $Alias no longer works after the lockdown: use the hosting provider's web console." }

# ------------------------------------------------------------ user tools
Step 'User tools (20-user-setup.sh)'
$gitName = ''; $gitEmail = ''
if (Get-Command git -ErrorAction SilentlyContinue) {
  $gitName  = ((& git config --global user.name)  -replace "[^\p{L}\p{N} ._@+-]", '')
  $gitEmail = ((& git config --global user.email) -replace "[^A-Za-z0-9._@+-]", '')
}
$gh = if ($Gatehaul) { '1' } else { '0' }
Run $ssh @('-t', $Alias, "GIT_NAME='$gitName' GIT_EMAIL='$gitEmail' INSTALL_GATEHAUL=$gh bash ~/devbox-setup/20-user-setup.sh") '20-user-setup.sh failed'

# ------------------------------------------------------------ Claude config
if (-not $SkipConfigSync) {
  Step 'Copying your global CLAUDE.md and your skills'
  $global:LASTEXITCODE = 0
  & (Join-Path $here 'sync-claude-config.ps1') -Alias $Alias
  if ($LASTEXITCODE -ne 0) { Fail 'Copying CLAUDE.md or skills failed: re-run client\windows\sync-claude-config.ps1.' }
}

Step 'Done'
Write-Host @"
What is left (see README.md):
  1. Tailscale: install it on this PC, then  ssh $Alias  and  sudo tailscale up --hostname=$Alias
     Tailscale admin console > Machines > $Alias > Disable key expiry.
     Set HostName = $Alias (the Tailscale name) in ~/.ssh/config, reconnect, then
     bash ~/devbox-setup/30-root-lockdown.sh  to close the public port 22.
  2. Reboot the server if the script advised it:  ssh $Alias sudo reboot
  3. Claude desktop app > Code > environment > New environment > SSH:
     host "$Alias", empty key (taken from ~/.ssh/config), worktrees ~/worktrees, folder ~/dev/<project>
"@
