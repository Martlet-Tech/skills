<#
.SYNOPSIS
  Collect the on-machine evidence needed to diagnose a Windows Electron desktop
  app that no longer opens (usually right after a self-update).

.DESCRIPTION
  Gathers, in one pass:
    1. Uninstall registry entries  -> real install dirs, version, perMachine/perUser
    2. Shortcut targets            -> which exe a double-click actually runs, alive or dead
    3. Install dirs on disk        -> missing exes, stale .update-installing markers
    4. Updater cache               -> the pending installer that may be blocking startup
    5. App logs                    -> startup / update / installer / register tails + keyword hits
    6. Windows event log           -> 1002 hang, 1000 crash, 1001 WER for the app
    7. Live processes              -> did it start, does it own a window

.PARAMETER AppName
  Product name fragment to look for, e.g. WorkBuddy, CodeBuddy. Matched
  case-insensitively against registry, shortcuts, processes and event log text.

.PARAMETER Hours
  How far back to read the Windows event log. Default 24.

.PARAMETER LogTail
  Lines to tail from each app log file. Default 12.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\triage.ps1 -AppName WorkBuddy

.EXAMPLE
  .\triage.ps1 -AppName WorkBuddy -Hours 72 -LogTail 25
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$AppName,
  [int]$Hours    = 24,
  [int]$LogTail  = 12
)

$ErrorActionPreference = 'SilentlyContinue'

function Section([string]$t) { Write-Output "`n==================== $t ====================" }
function Hint([string]$t)    { Write-Output "  (none found) $t" }

# ---------------------------------------------------------------- 1. registry
Section "1. Uninstall entries / real install dirs"
$regRoots = @(
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$entries = @(Get-ItemProperty $regRoots | Where-Object { $_.DisplayName -like "*$AppName*" })
if ($entries.Count -eq 0) { Hint "no uninstall entry matches '$AppName'" }
foreach ($e in $entries) {
  $exe = ($e.DisplayIcon -split ',')[0].Trim('"')
  $scope = if ($e.UninstallString -match '/currentuser') { 'perUser' }
           elseif ($e.UninstallString -match '/allusers') { 'perMachine' }
           else { '?' }
  $instDir = if ($exe) { Split-Path $exe -Parent } else { '' }
  Write-Output ("  {0}  v{1}  [{2}]" -f $e.DisplayName, $e.DisplayVersion, $scope)
  Write-Output ("      exe      : {0}   exists={1}" -f $exe, (Test-Path $exe))
  Write-Output ("      instdir  : {0}" -f $instDir)
  Write-Output ("      uninstall: {0}" -f $e.UninstallString)
  if ($instDir -and (Test-Path $instDir)) {
    Write-Output ("      files    : {0} entries, version file = '{1}'" -f
      (Get-ChildItem $instDir -Recurse -Force | Measure-Object).Count,
      ((Get-Content (Join-Path $instDir 'version') -Raw) -replace '\s+', ''))
  }
}

# --------------------------------------------------------------- 2. shortcuts
Section "2. Shortcuts -> target alive?"
$roots = @(
  "$env:USERPROFILE\Desktop",
  "$env:PUBLIC\Desktop",
  "$env:USERPROFILE\OneDrive\Desktop",
  'C:\ProgramData\Microsoft\Windows\Start Menu\Programs',
  "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
) | Where-Object { $_ -and (Test-Path $_) }
$shell = New-Object -ComObject WScript.Shell
$links = @(Get-ChildItem $roots -Recurse -Filter *.lnk |
           Where-Object { $_.Name -like "*$AppName*" })
if ($links.Count -eq 0) { Hint "no shortcut matches '$AppName'" }
foreach ($lnk in $links) {
  $t = $shell.CreateShortcut($lnk.FullName).TargetPath
  Write-Output ("  {0,-8} {1}" -f $(if (Test-Path $t) { 'OK' } else { 'DEAD' }), $lnk.FullName)
  Write-Output ("           -> {0}" -f $t)
}

# ------------------------------------------------- 3. install dirs + markers
Section "3. Install dirs on disk + stale .update-installing markers"
$dirs = @($entries | ForEach-Object { Split-Path (($_.DisplayIcon -split ',')[0].Trim('"')) -Parent } |
          Where-Object { $_ } | Select-Object -Unique)
$dirs += @(Get-ChildItem "$env:LOCALAPPDATA\Programs" -Directory -Force |
           Where-Object { $_.Name -like "*$AppName*" } | ForEach-Object { $_.FullName })
$dirs = @($dirs | Where-Object { $_ } | Select-Object -Unique)
if ($dirs.Count -eq 0) { Hint "no install directory located" }
foreach ($d in $dirs) {
  if (-not (Test-Path $d)) { Write-Output "  MISSING  $d"; continue }
  $n  = (Get-ChildItem $d -Recurse -Force | Measure-Object).Count
  $mk = Get-ChildItem $d -Force -Filter '.update-installing'
  Write-Output ("  {0}  ({1} entries)" -f $d, $n)
  if ($mk) { Write-Output ("      STALE MARKER: {0}" -f ((Get-Content $mk.FullName -Raw) -replace '\s+', ' ')) }
  Get-ChildItem $d -Force -File -Filter "*.exe" | Where-Object { $_.Name -like "*$AppName*" } |
    ForEach-Object { Write-Output ("      exe: {0}  {1} bytes  {2}" -f $_.Name, $_.Length, $_.LastWriteTime) }
}

# ------------------------------------------------------------ 4. updater cache
Section "4. Pending update packages (startup blockers)"
$caches = @(Get-ChildItem "$env:LOCALAPPDATA" -Directory -Force |
            Where-Object { $_.Name -like "*updater*" })
$mine   = @($caches | Where-Object { $_.Name -like "*$AppName*" })
$others = @($caches | Where-Object { $_.Name -notlike "*$AppName*" })
$hit = $false

Write-Output "  -- caches belonging to '$AppName' (these are the startup blockers) --"
foreach ($c in $mine) {
  foreach ($f in @(Get-ChildItem $c.FullName -Force -File -Filter 'installer.exe')) {
    $hit = $true
    $v = $f.VersionInfo
    Write-Output ("  PENDING: {0}" -f $f.FullName)
    Write-Output ("      ProductName={0}  FileVersion={1}  Size={2}  Modified={3}" -f
      $v.ProductName, $v.FileVersion, $f.Length, $f.LastWriteTime)
  }
}
foreach ($t in @(Get-ChildItem $env:TEMP -Directory -Force |
                 Where-Object { $_.Name -like "*$AppName*update*" -or $_.Name -like "*update*$AppName*" })) {
  $hit = $true
  Write-Output ("  TEMPDIR: {0}" -f $t.FullName)
  Get-ChildItem $t.FullName -Force -Recurse -File | Select-Object -First 5 |
    ForEach-Object { Write-Output ("      {0}  {1} bytes" -f $_.Name, $_.Length) }
}
if (-not $hit) { Write-Output "  (clean) no pending installer for '$AppName' in updater cache or %TEMP%" }

Write-Output "  -- other Electron updater caches on this machine (context only) --"
foreach ($c in $others) {
  $f = @(Get-ChildItem $c.FullName -Force -File -Filter 'installer.exe' | Select-Object -First 1)
  if ($f) {
    Write-Output ("  {0,-42} {1} {2}" -f $c.Name, $f[0].VersionInfo.ProductName, $f[0].VersionInfo.FileVersion)
  }
}
Write-Output "  NOTE: a stale installer.exe in an updater cache is harmless on its own."
Write-Output "        It only blocks startup when section 5b shows 'ready update restored' / 'skipping window bootstrap'."

# ------------------------------------------------------------------ 5. app logs
Section "5. App logs (startup / update / installer / register)"
$stem = ($AppName -replace '[^a-zA-Z0-9]', '').ToLower()
$ud = @(Get-ChildItem $env:USERPROFILE -Directory -Force |
        Where-Object { $_.Name -match ("^\..*" + [regex]::Escape($stem)) })
if ($ud.Count -eq 0) { Hint "no user-data dir (~/.<app>) under $env:USERPROFILE" }
foreach ($u in $ud) {
  $logRoot = Join-Path $u.FullName 'logs'
  Write-Output ("  user-data: {0}" -f $u.FullName)
  if (-not (Test-Path $logRoot)) { Write-Output "      no logs dir"; continue }

  $startupRoot = Join-Path $logRoot 'startup'
  if (Test-Path $startupRoot) {
    $last = @(Get-ChildItem $startupRoot -Recurse -Filter *.log |
              Sort-Object LastWriteTime | Select-Object -Last 1)
    if ($last) {
      Write-Output ("      --- newest startup log: {0} ---" -f $last[0].Name)
      Get-Content $last[0].FullName -Tail $LogTail | ForEach-Object { Write-Output ("      | " + $_) }
    }
  }
  foreach ($one in @('installer.log', 'register.log', 'main.log')) {
    $p = Join-Path $logRoot $one
    if (Test-Path $p) {
      Write-Output ("      --- {0} (tail {1}) ---" -f $one, $LogTail)
      Get-Content $p -Tail $LogTail | ForEach-Object { Write-Output ("      | " + $_) }
    }
  }
  $updRoot = Join-Path $logRoot 'update'
  if (Test-Path $updRoot) {
    $last = @(Get-ChildItem $updRoot -Filter *.log | Sort-Object LastWriteTime | Select-Object -Last 1)
    if ($last) {
      Write-Output ("      --- newest update log: {0} ---" -f $last[0].Name)
      Get-Content $last[0].FullName -Tail $LogTail | ForEach-Object { Write-Output ("      | " + $_) }
    }
  }

  Section "5b. Keyword hits across app logs (the actual root-cause signals)"
  $patterns = @(
    'skipping window bootstrap',      # mode A: startup never builds a window
    'ready update restored',          # mode A: pending update hijacks startup
    'quitting to install',            # mode A
    'install directory confirmed',    # mode B: install target was redirected
    'install target dir',             # mode B
    'update install mark',            # mode B: where .update-installing was written
    'register FAILED',                # mode C: appx sparse package conflict
    'suspend failed',                 # install preflight failure
    'STARTUP COMPLETE'                # healthy
  )
  $files = @(Get-ChildItem $logRoot -Recurse -File -Filter *.log | Where-Object { $_.Length -lt 30MB })
  foreach ($pat in $patterns) {
    $m = @($files | Select-String -Pattern $pat -List | Select-Object -First 3)
    if ($m.Count -gt 0) {
      Write-Output ("  [{0}]" -f $pat)
      foreach ($x in $m) { Write-Output ("      {0} :: {1}" -f $x.Filename, ($x.Line.Trim() -replace '\s+', ' ')) }
    }
  }
}

# ------------------------------------------------------------- 6. event log
Section "6. Windows event log (hang / crash / WER)"
$ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddHours(-$Hours) } |
        Where-Object { $_.Id -in 1000, 1001, 1002 -and $_.Message -match $AppName })
if ($ev.Count -eq 0) { Hint "no 1000/1001/1002 event mentions '$AppName' in the last $Hours h" }
foreach ($e in ($ev | Select-Object -First 12)) {
  $head = ($e.Message -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' | '
  Write-Output ("  {0}  id={1}  {2}" -f $e.TimeCreated, $e.Id, ($head -replace '\s+', ' '))
}

# --------------------------------------------------------------- 7. processes
Section "7. Live processes / window title"
$procs = @(Get-Process | Where-Object { $_.ProcessName -like "*$AppName*" })
if ($procs.Count -eq 0) { Hint "no '$AppName' process is running" }
$procs | Group-Object ProcessName | ForEach-Object { Write-Output ("  {0}: {1} process(es)" -f $_.Name, $_.Count) }
$procs | Where-Object { $_.MainWindowTitle } |
  ForEach-Object { Write-Output ("  WINDOW  pid={0}  '{1}'" -f $_.Id, $_.MainWindowTitle) }

Write-Output "`n==================== done ===================="
Write-Output "Match the signals above against SKILL.md: A=silent update loop, B=shared install dir, C=appx conflict, D=dead shortcut."
