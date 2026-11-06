# Byte Windows build checks: files, version info, zip integrity, forbidden names, secrets.
param([Parameter(Mandatory=$true)][string]$Release, [Parameter(Mandatory=$true)][string]$Out)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
function Log([string]$m) { $lines.Add($m); Write-Host $m }
$exe = Join-Path $Release 'Byte.exe'
if (-not (Test-Path $exe)) { throw "Byte.exe is missing in $Release" }
$vi = (Get-Item $exe).VersionInfo
Log ("exe bytes: " + (Get-Item $exe).Length)
Log ("FileVersion=" + $vi.FileVersion + " ProductVersion=" + $vi.ProductVersion + " ProductName=" + $vi.ProductName + " CompanyName=" + $vi.CompanyName + " FileDescription=" + $vi.FileDescription + " OriginalFilename=" + $vi.OriginalFilename)
Log ("LegalCopyright=" + $vi.LegalCopyright)
if (-not $vi.ProductVersion.StartsWith('2.0.0')) { throw "unexpected ProductVersion $($vi.ProductVersion)" }
$stage = Join-Path $Out 'Byte'
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
Copy-Item -Recurse -Force $Release $stage
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $stage 'README.txt'), "Byte 2.0.0 (build 2006) for Windows (64-bit)`r`nExtract and run Byte.exe.`r`nIf Windows SmartScreen appears: More info, then Run anyway.`r`n(c) 2026 Apurba Laskar`r`n", $utf8)
# forbidden names and secrets in every shipped file
$bad = @()
$pats = @('bitchord','mochy')
foreach ($f in Get-ChildItem -Recurse -File $stage) {
  $bytes = [IO.File]::ReadAllBytes($f.FullName)
  $ascii = [Text.Encoding]::ASCII.GetString($bytes)
  $u16 = [Text.Encoding]::Unicode.GetString($bytes)
  foreach ($p in $pats) {
    if ($ascii -match "(?i)$p" -or $u16 -match "(?i)$p") { $bad += "$p in $($f.Name)" }
  }
  if ($f.Name -match '(?i)\.(jks|keystore)$|dist_key|key\.properties|^\.env|secret') { $bad += "secret-like file $($f.Name)" }
}
Log ("forbidden or secret-like hits: " + $bad.Count)
foreach ($b in $bad) { Log ("  " + $b) }
if ($bad.Count -gt 0) { throw "forbidden or secret-like content found" }
$zip = Join-Path $Out 'Byte-2.0.0.2006-windows-x64.zip'
Remove-Item -Force $zip -ErrorAction SilentlyContinue
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$arc = [IO.Compression.ZipFile]::OpenRead($zip)
$n = 0; $total = 0
foreach ($e in $arc.Entries) {
  $n++; $total += $e.Length
  if ($e.FullName.EndsWith('/')) { continue }
  $s = $e.Open(); $buf = New-Object byte[] 1048576
  while ($s.Read($buf, 0, $buf.Length) -gt 0) { }
  $s.Close()
}
$hasExe = @($arc.Entries | Where-Object { $_.FullName -eq 'Byte/Byte.exe' }).Count
$arc.Dispose()
Log ("zip entries: $n, uncompressed bytes: $total, Byte/Byte.exe present: $hasExe (every entry read, CRC checked)")
if ($hasExe -ne 1) { throw "zip lacks Byte/Byte.exe" }
$h = Get-FileHash -Algorithm SHA256 $zip
Log ("zip bytes: " + (Get-Item $zip).Length)
Log ("zip sha256: " + $h.Hash.ToLower())
Log "top level in zip folder:"
Get-ChildItem $stage | ForEach-Object { Log ("  " + $_.Name + " " + $_.Length) }
[IO.File]::WriteAllLines((Join-Path $Out 'verify.txt'), $lines, $utf8)
