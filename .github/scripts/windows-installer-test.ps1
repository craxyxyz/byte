# Byte Windows setup program, checked on the runner like a user would meet it:
#   1. silent install of an older build, then a silent install of this build over it (upgrade in place)
#   2. the uninstall entry under the current user's Uninstall key (what Installed apps lists), the Start menu entry
#   3. the installed files match the release folder; no forbidden names or secret-like files
#   4. launch the installed Byte.exe, it stays up 30 s with the window title 'Byte', screenshot
#   5. silent uninstall, then the entry, the Start menu item and the program files are gone
param(
  [Parameter(Mandatory=$true)][string]$Setup,
  [Parameter(Mandatory=$true)][string]$OldSetup,
  [Parameter(Mandatory=$true)][string]$Release,
  [Parameter(Mandatory=$true)][string]$Out,
  [string]$Version = '2.0.0.2008',
  [string]$OldVersion = '2.0.0.2007',
  [string]$Publisher = 'Apurba Laskar',
  [string]$AppId = '{A3967736-04A6-40BC-9D80-86F101275C9D}'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$OutAbs = (Resolve-Path $Out).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)
$lines = New-Object System.Collections.Generic.List[string]
$fails = New-Object System.Collections.Generic.List[string]
function Log([string]$m) { $lines.Add($m); Write-Host $m }
function Check([bool]$ok, [string]$what) {
  if ($ok) { Log ("PASS  " + $what) } else { Log ("FAIL  " + $what); $fails.Add($what) }
}
$SetupAbs = (Resolve-Path $Setup).Path
$OldAbs = (Resolve-Path $OldSetup).Path
$ReleaseAbs = (Resolve-Path $Release).Path
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\Byte'
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Byte.lnk'
$uninstKeyRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
$exactKey = "$uninstKeyRoot\$($AppId)_is1"

function Byte-Keys {
  # every uninstall entry whose display name is Byte, under the current user (what Installed apps lists)
  @(Get-ChildItem $uninstKeyRoot -ErrorAction SilentlyContinue | Where-Object {
    try { (Get-ItemProperty $_.PSPath -ErrorAction Stop).DisplayName -eq 'Byte' } catch { $false } })
}
function Key-Value([string]$name) {
  try { (Get-ItemProperty -LiteralPath $exactKey -Name $name -ErrorAction Stop).$name } catch { $null }
}
function Run-Silent([string]$exePath, [string]$logName) {
  $log = Join-Path $OutAbs $logName
  $p = Start-Process -FilePath $exePath -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/LOG=`"$log`"") -PassThru -Wait
  return $p.ExitCode
}
function Wait-Until([scriptblock]$cond, [int]$secs) {
  for ($t = 0; $t -lt $secs; $t += 2) { if (& $cond) { return $true }; Start-Sleep -Seconds 2 }
  return $false
}
function Scan-Forbidden([string]$dir) {
  $bad = @()
  foreach ($f in Get-ChildItem -Recurse -File $dir) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    $u16 = [Text.Encoding]::Unicode.GetString($bytes)
    foreach ($p in @('bitchord', 'mochy')) {
      if ($ascii -match "(?i)$p" -or $u16 -match "(?i)$p") { $bad += "$p in $($f.Name)" }
    }
    if ($f.Name -match '(?i)\.(jks|keystore)$|dist_key|key\.properties|^\.env|secret') { $bad += "secret-like file $($f.Name)" }
  }
  return $bad
}

# --- 0. start clean
if (Test-Path -LiteralPath $exactKey) { Log 'a previous test left an entry; removing it first' }
if (Test-Path $installDir) {
  $u = Join-Path $installDir 'unins000.exe'
  if (Test-Path $u) { Run-Silent $u 'pre-clean-uninstall.log' | Out-Null; Wait-Until { -not (Test-Path (Join-Path $installDir 'Byte.exe')) } 120 | Out-Null }
}
Remove-Item -Force $lnk -ErrorAction SilentlyContinue

# --- 1. upgrade test: older build first
Log ("1. silent install of the older test build " + $OldVersion)
$code = Run-Silent $OldAbs 'install-old.log'
Check ($code -eq 0) ("older build installs silently (exit $code)")
Check (Test-Path (Join-Path $installDir 'Byte.exe')) 'older build put Byte.exe under the per-user programs folder'
Check ((Byte-Keys).Count -eq 1) ("one Installed-apps entry after the older install (found " + (Byte-Keys).Count + ")")
Check ((Key-Value 'DisplayVersion') -eq $OldVersion) ("older entry reads version $OldVersion (reads: " + (Key-Value 'DisplayVersion') + ")")

# --- 2. this build over the older one
Log ("2. silent install of " + $Version + " over the older one")
$code = Run-Silent $SetupAbs 'install-new.log'
Check ($code -eq 0) ("upgrade install exits 0 (exit $code)")
$keys = Byte-Keys
Check ($keys.Count -eq 1) ("one Installed-apps entry after the upgrade (found " + $keys.Count + ")")
Check ((Test-Path -LiteralPath $exactKey)) ("entry sits at the stable AppId key ($($AppId)_is1)")
Check ((Key-Value 'DisplayName') -eq 'Byte') ("DisplayName is Byte (reads: " + (Key-Value 'DisplayName') + ")")
Check ((Key-Value 'DisplayVersion') -eq $Version) ("DisplayVersion is $Version (reads: " + (Key-Value 'DisplayVersion') + ")")
Check ((Key-Value 'Publisher') -eq $Publisher) ("Publisher is $Publisher (reads: " + (Key-Value 'Publisher') + ")")
$loc = [string](Key-Value 'InstallLocation')
Check ($loc.TrimEnd('\') -ieq $installDir.TrimEnd('\')) ("InstallLocation is the per-user Byte folder (reads: $loc)")
$us = [string](Key-Value 'UninstallString')
Check ($us.Length -gt 0 -and $us -match 'unins000\.exe') ("UninstallString names the uninstaller (reads: $us)")
Check ((Key-Value 'NoRemove') -ne 1) 'entry is removable (NoRemove not set)'
$inst = Join-Path $installDir 'Byte.exe'
Check (Test-Path $inst) 'Byte.exe present in the install folder'
if (Test-Path $inst) {
  $iv = (Get-Item $inst).VersionInfo
  Log ("installed Byte.exe: FileVersion " + $iv.FileVersion + ", ProductName " + $iv.ProductName + ", CompanyName " + $iv.CompanyName)
  Check ((Get-FileHash $inst).Hash -eq (Get-FileHash (Join-Path $ReleaseAbs 'Byte.exe')).Hash) 'installed Byte.exe is byte-identical to the release Byte.exe'
}
Check (Test-Path $lnk) 'Start menu entry Byte exists (Programs\Byte.lnk)'
if (Test-Path $lnk) {
  $target = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath
  Check ($target -ieq $inst) ("Start menu entry points at the installed Byte.exe (reads: $target)")
}
$relCount = @(Get-ChildItem -Recurse -File $ReleaseAbs).Count
$instFiles = @(Get-ChildItem -Recurse -File $installDir | Where-Object { $_.Name -notmatch '^unins00[01]\.(exe|dat|msg)$' })
Check ($instFiles.Count -eq $relCount) ("installed files match the release folder: $($instFiles.Count) installed, $relCount in the release")
$bad = Scan-Forbidden $installDir
Check ($bad.Count -eq 0) ("no forbidden names or secret-like files in the installed folder (hits: " + $bad.Count + ")")
foreach ($b in $bad) { Log ("  " + $b) }

# --- 3. launch the installed copy: 30 s, title Byte, screenshot
Log '3. launching the installed Byte.exe for 30 s'
& (Join-Path $PSScriptRoot 'windows-smoke.ps1') -Stage $installDir -Out (Join-Path $OutAbs 'launch') -Seconds 30
$smoke = Get-Content (Join-Path $OutAbs 'launch\smoke.txt') -ErrorAction SilentlyContinue
$smoke | ForEach-Object { Log ("  smoke: " + $_) }
Check (($smoke -match 'still running after 30 s: True').Count -eq 1) 'installed Byte.exe still running after 30 s'
Check (($smoke -match "main window title: 'Byte'").Count -eq 1) "installed Byte.exe window title is 'Byte'"

# --- 4. silent uninstall
Log '4. silent uninstall'
$uninst = Join-Path $installDir 'unins000.exe'
Check (Test-Path $uninst) 'uninstaller present in the install folder'
$code = Run-Silent $uninst 'uninstall.log'
Check ($code -eq 0) ("uninstall exits 0 (exit $code)")
$gone = Wait-Until { (Byte-Keys).Count -eq 0 -and -not (Test-Path (Join-Path $installDir 'Byte.exe')) -and -not (Test-Path $lnk) } 120
Check $gone 'after uninstall: no Installed-apps entry, no Byte.exe, no Start menu entry'
Check ((Byte-Keys).Count -eq 0) ("no Installed-apps entry remains (found " + (Byte-Keys).Count + ")")
Check (-not (Test-Path $lnk)) 'Start menu entry removed'
Check (-not (Test-Path (Join-Path $installDir 'Byte.exe'))) 'Byte.exe removed'
$left = @()
if (Test-Path $installDir) { $left = @(Get-ChildItem -Recurse -Force $installDir | ForEach-Object { $_.FullName.Replace($installDir, '') }) }
Log ("left in the install folder after uninstall: " + $left.Count)
foreach ($l in ($left | Select-Object -First 20)) { Log ("  " + $l) }

$summary = if ($fails.Count -eq 0) { 'ALL CHECKS PASSED' } else { 'FAILED: ' + ($fails -join '; ') }
Log $summary
[IO.File]::WriteAllLines((Join-Path $OutAbs 'test.txt'), $lines, $utf8)
if ($fails.Count -gt 0) { exit 1 }
