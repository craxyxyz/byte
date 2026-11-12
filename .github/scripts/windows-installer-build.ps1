# Byte Windows setup program: compile the per-user installer with the Inno Setup compiler on the runner.
# Also compiles a second copy labelled with the previous build number (2.0.0.2009), used by the
# upgrade test (install old, then install new over it). Run from the repository root.
param(
  [Parameter(Mandatory=$true)][string]$Release,
  [Parameter(Mandatory=$true)][string]$Out,
  [string]$Version = '2.0.0.2010',
  [string]$OldVersion = '2.0.0.2009'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$lines = New-Object System.Collections.Generic.List[string]
function Log([string]$m) { $lines.Add($m); Write-Host $m }

function Find-Iscc {
  foreach ($p in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}
$iscc = Find-Iscc
if (-not $iscc) {
  Log 'compiler not preinstalled; installing it from the package feed'
  choco install innosetup -y --no-progress --limit-output | Out-Host
  $iscc = Find-Iscc
}
if (-not $iscc) { throw 'Inno Setup compiler not found' }
Log ("compiler: " + $iscc + " version " + (Get-Item $iscc).VersionInfo.ProductVersion)

$relAbs = (Resolve-Path $Release).Path
$exe = Join-Path $relAbs 'Byte.exe'
if (-not (Test-Path $exe)) { throw "Byte.exe missing in $relAbs" }
Log ("release files: " + @(Get-ChildItem -Recurse -File $relAbs).Count + ", Byte.exe " + (Get-Item $exe).Length + " bytes, file version " + (Get-Item $exe).VersionInfo.FileVersion)
$script = (Resolve-Path 'installer/byte-setup.iss').Path
$outAbs = (New-Item -ItemType Directory -Force -Path $Out).FullName

function Build-Setup([string]$ver, [string]$name, [string]$dir, [bool]$fast) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $dirAbs = (Resolve-Path $dir).Path
  $defs = @("/DSourceDir=$relAbs", "/DMyAppVersion=$ver", "/DMyOutputName=$name", "/DOutputDirPath=$dirAbs")
  if ($fast) { $defs += '/DFastBuild' }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & $iscc '/Qp' @defs $script | Out-Host
  $code = $LASTEXITCODE
  Log ("compile " + $name + " exit " + $code + " in " + [int]$sw.Elapsed.TotalSeconds + " s")
  if ($code -ne 0) { throw "compile of $name failed with exit $code" }
  $f = Join-Path $dirAbs ($name + '.exe')
  if (-not (Test-Path $f)) { throw "$f was not written" }
  $h = (Get-FileHash -Algorithm SHA256 $f).Hash.ToLower()
  Log ($name + ".exe bytes: " + (Get-Item $f).Length + " sha256: " + $h)
  return $f
}

$main = Build-Setup $Version ('Byte-' + $Version + '-setup') $outAbs $false
$old = Build-Setup $OldVersion ('Byte-' + $OldVersion + '-setup-test') (Join-Path $outAbs 'old') $true

# Name and version of the main setup, for the workflow's report
Log ("main setup: " + $main)
Log ("old setup (upgrade test): " + $old)
[IO.File]::WriteAllLines((Join-Path $outAbs 'build.txt'), $lines, $utf8)
