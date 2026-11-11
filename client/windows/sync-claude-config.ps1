<#
.SYNOPSIS
  Copies your global CLAUDE.md and skills from Windows to the "devbox" server.

.DESCRIPTION
  - ~/.claude/CLAUDE.md: copied with a header (templates/host-header.md) that
    explains the machine's differences to Claude (Linux paths, Playwright MCP,
    no Browser pane). The server's original CLAUDE.md is kept as CLAUDE.md.bak
    (only once).
  - ~/.claude/skills: merged on the server (files are overwritten, skills
    installed only on the server stay). .venv, node_modules, __pycache__ and
    .git are not copied: recreate Python environments on the server if a skill
    needs one.
  - With -Memory, the auto-memory folder of the local project whose path is
    -LocalDevDir is merged into the server's ~/dev memory (nothing is deleted).
  Plugins are copied by the desktop app itself. Other auto-memory
  (~/.claude/projects) is not copied.

.PARAMETER Alias
  SSH alias of the server (default: devbox).

.PARAMETER SkipSkills
  Do not copy the skills.

.PARAMETER LocalDevDir
  Your local projects folder; a path under it in your CLAUDE.md maps to
  ~/dev/<x> on the server. Default: ~\Documents\dev if it exists, else ~.

.PARAMETER Memory
  Also copy the auto-memory of the project at LocalDevDir. Local path:
  ~/.claude/projects/<key>/memory where <key> is the full path with every
  character other than A-Z a-z 0-9 replaced by '-'. Server path:
  ~/.claude/projects/-home-<devuser>-dev/memory/

.PARAMETER ShareRoot
  Where this computer mounts the server's home folder (host/40-file-share.sh), so that
  sessions on the server write file links that open here. 'auto' (default) uses the
  drive letter mapped to \\<alias>\..., 'none' leaves the rule out, or give it, e.g. Z:

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\client\windows\sync-claude-config.ps1 -Memory
#>
[CmdletBinding()]
param(
  [string]$Alias = 'devbox',
  [switch]$SkipSkills,
  [string]$LocalDevDir = $(if (Test-Path (Join-Path $env:USERPROFILE 'Documents\dev')) { Join-Path $env:USERPROFILE 'Documents\dev' } else { $env:USERPROFILE }),
  [switch]$Memory,
  [string]$ShareRoot = 'auto'
)

$ErrorActionPreference = 'Stop'
$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir   = Split-Path -Parent (Split-Path -Parent $here)
$sshDir    = Join-Path $env:WINDIR 'System32\OpenSSH'
$ssh       = Join-Path $sshDir 'ssh.exe'
$scp       = Join-Path $sshDir 'scp.exe'
$tar       = Join-Path $env:WINDIR 'System32\tar.exe'
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$tmp       = Join-Path $env:TEMP "devbox-sync-$PID"

function Fail([string]$m) { Write-Host "[error] $m" -ForegroundColor Red; exit 1 }
function Run([string]$exe, [string[]]$argList, [string]$what) {
  & $exe @argList
  if ($LASTEXITCODE -ne 0) { Fail "$what (code $LASTEXITCODE)" }
}

New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  # ---------------------------------------------------------- CLAUDE.md
  $src = Join-Path $claudeDir 'CLAUDE.md'
  if (Test-Path $src) {
    $tplPath = Join-Path $repoDir 'templates\host-header.md'
    if (-not (Test-Path $tplPath)) { Fail "Template not found: $tplPath" }
    $localDev = ($LocalDevDir.TrimEnd('\', '/')) -replace '\\', '/'
    $header = ([IO.File]::ReadAllText($tplPath)).Replace('@ALIAS@', $Alias).Replace('@LOCAL_DEV_DIR@', $localDev)
    # File-share links: auto = the drive letter mapped to \\<alias>\..., none = leave the rule out.
    $share = $ShareRoot
    if ($share -eq 'auto') {
      $drive = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.DisplayRoot -like "\\$Alias\*" } | Select-Object -First 1
      $share = if ($drive) { "$($drive.Name):" } else { 'none' }
    }
    if ($share -eq 'none') {
      $header = [regex]::Replace($header, '(?ms)^@SHARE_BEGIN@\r?\n.*?^@SHARE_END@\r?\n', '')
      Write-Host 'No mapped drive for the server share: file links rule left out.'
    } else {
      $share = $share.TrimEnd('\', '/')
      $header = [regex]::Replace($header, '(?m)^@SHARE_(BEGIN|END)@\r?\n', '')
      $header = $header.Replace('@SHARE_URL@', 'file:///' + ($share -replace '\\', '/')).Replace('@SHARE_ROOT@', $share)
      Write-Host "File links will point to $share"
    }
    $body = [IO.File]::ReadAllText($src)
    $text = ($header + $body) -replace "`r`n", "`n"
    $out = Join-Path $tmp 'CLAUDE.md'
    [IO.File]::WriteAllText($out, $text, (New-Object Text.UTF8Encoding $false))
    Run $ssh @($Alias, 'mkdir -p ~/.claude && if [ -f ~/.claude/CLAUDE.md ] && [ ! -f ~/.claude/CLAUDE.md.bak ]; then cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.bak; fi') 'preparing ~/.claude'
    Run $scp @($out, "${Alias}:.claude/CLAUDE.md") 'copying CLAUDE.md'
    Write-Host 'CLAUDE.md copied.'
  } else {
    Write-Host "No $src : nothing to copy."
  }

  # ---------------------------------------------------------- skills
  $skills = Join-Path $claudeDir 'skills'
  if (-not $SkipSkills -and (Test-Path $skills)) {
    $archive = Join-Path $tmp 'skills.tgz'
    Run $tar @('-czf', $archive, '--exclude', '.venv', '--exclude', 'node_modules', '--exclude', '__pycache__', '--exclude', '.git', '-C', $claudeDir, 'skills') 'skills archive'
    $sizeMb = [math]::Round((Get-Item $archive).Length / 1MB, 1)
    Write-Host "Skills archive: $sizeMb MB"
    Run $scp @($archive, "${Alias}:.claude/skills-sync.tgz") 'copying skills'
    Run $ssh @($Alias, 'cd ~/.claude && tar -xzf skills-sync.tgz && rm -f skills-sync.tgz && ls skills') 'extracting skills'
    Write-Host 'Skills merged into ~/.claude/skills on the server.'
  }

  # ---------------------------------------------------------- auto-memory
  if ($Memory) {
    $full = [IO.Path]::GetFullPath($LocalDevDir).TrimEnd('\', '/')
    $key  = $full -replace '[^A-Za-z0-9]', '-'
    $memDir = Join-Path $claudeDir "projects\$key\memory"
    if (-not (Test-Path $memDir)) {
      Write-Host "No auto-memory at $memDir : nothing to copy."
    } else {
      $devUser = (& $ssh $Alias 'whoami' | Select-Object -First 1)
      if ($LASTEXITCODE -ne 0 -or -not $devUser -or $devUser -notmatch '^[a-z_][a-z0-9_-]*$') { Fail 'Could not read the server user name (ssh whoami).' }
      $devUser = $devUser.Trim()
      $remoteDir = ".claude/projects/-home-$devUser-dev/memory"
      $mArchive = Join-Path $tmp 'memory.tgz'
      Run $tar @('-czf', $mArchive, '-C', $memDir, '.') 'memory archive'
      Run $ssh @($Alias, "mkdir -p ~/$remoteDir") 'creating the memory folder'
      Run $scp @($mArchive, "${Alias}:.claude/memory-sync.tgz") 'copying memory'
      Run $ssh @($Alias, "tar -xzf ~/.claude/memory-sync.tgz -C ~/$remoteDir && rm -f ~/.claude/memory-sync.tgz") 'extracting memory'
      $files = @(Get-ChildItem -Path $memDir -Recurse -File)
      Write-Host "Memory merged: $($files.Count) file(s) from $memDir"
      Write-Host "  -> ~/$remoteDir on the server"
      foreach ($f in $files) { Write-Host ('  ' + $f.FullName.Substring($memDir.Length + 1)) }
    }
  }
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
