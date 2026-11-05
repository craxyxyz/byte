# Byte Windows: launch the built app on the runner, read its window title, take a screenshot.
param([Parameter(Mandatory=$true)][string]$Stage, [Parameter(Mandatory=$true)][string]$Out, [int]$Seconds = 35)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
function Log([string]$m) { $lines.Add($m); Write-Host $m }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$exe = Join-Path $Stage 'Byte.exe'
$p = Start-Process -FilePath $exe -WorkingDirectory $Stage -PassThru
Log ("started Byte.exe pid " + $p.Id)
$title = ''
for ($t = 0; $t -lt $Seconds; $t += 2) {
  Start-Sleep -Seconds 2
  $p.Refresh()
  if ($p.HasExited) { Log ("exited early with code " + $p.ExitCode); break }
  if ($p.MainWindowTitle) { $title = $p.MainWindowTitle }
}
$p.Refresh()
Log ("still running after $Seconds s: " + (-not $p.HasExited))
Log ("main window title: '" + $title + "'")
try {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $shot = Join-Path $Out 'screen.png'
  $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
  Log ("screenshot " + $b.Width + "x" + $b.Height + " saved")
  $g.Dispose(); $bmp.Dispose()
} catch { Log ("screenshot failed: " + $_.Exception.Message) }
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Log "stopped Byte.exe" }
$logDir = Join-Path $env:APPDATA 'com.apurbalaskar\byte'
Log ("app data folder present: " + (Test-Path $logDir))
[IO.File]::WriteAllLines((Join-Path $Out 'smoke.txt'), $lines, $utf8)
