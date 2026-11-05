# Byte Windows: audio evidence on the runner (Windows PowerShell 5.1, WinRT MediaPlayer).
# The app's audio engine on Windows (just_audio_windows) plays through the same WinRT MediaPlayer.
param([Parameter(Mandatory=$true)][string]$Out)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
function Log([string]$m) { $lines.Add($m); Write-Host $m }
$utf8 = New-Object System.Text.UTF8Encoding($false)
Log ("audio endpoints (Win32_SoundDevice): " + @(Get-CimInstance Win32_SoundDevice).Count)
Log ("Audiosrv: " + (Get-Service Audiosrv).Status)
$sr = 44100; $secs = 6; $n = $sr * $secs
$pcm = New-Object byte[] ($n * 2)
for ($i = 0; $i -lt $n; $i++) {
  $v = [int](12000 * [math]::Sin(2 * [math]::PI * 440 * $i / $sr))
  $pcm[2 * $i] = [byte]($v -band 0xFF); $pcm[2 * $i + 1] = [byte](($v -shr 8) -band 0xFF)
}
$wav = Join-Path $Out 'tone.wav'
$fs = [IO.File]::Create($wav)
$bw = New-Object IO.BinaryWriter($fs)
$bw.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $bw.Write([int](36 + $pcm.Length)); $bw.Write([Text.Encoding]::ASCII.GetBytes('WAVE'))
$bw.Write([Text.Encoding]::ASCII.GetBytes('fmt ')); $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1)
$bw.Write([int]$sr); $bw.Write([int]($sr * 2)); $bw.Write([int16]2); $bw.Write([int16]16)
$bw.Write([Text.Encoding]::ASCII.GetBytes('data')); $bw.Write([int]$pcm.Length); $bw.Write($pcm)
$bw.Flush(); $bw.Close(); $fs.Close()
Log ("tone written: " + (Get-Item $wav).Length + " bytes, 440 Hz, 6 s, 16-bit mono 44.1 kHz")
try {
  [void][Windows.Media.Playback.MediaPlayer, Windows.Media.Playback, ContentType = WindowsRuntime]
  [void][Windows.Media.Core.MediaSource, Windows.Media.Core, ContentType = WindowsRuntime]
  $mp = New-Object Windows.Media.Playback.MediaPlayer
  $mp.Volume = 1.0
  $uri = New-Object System.Uri(('file:///' + $wav.Replace('\', '/')))
  $mp.Source = [Windows.Media.Core.MediaSource]::CreateFromUri($uri)
  $mp.Play()
  $peak = 0.0
  for ($t = 0; $t -lt 16; $t++) {
    Start-Sleep -Milliseconds 500
    $s = $mp.PlaybackSession
    Log ("t=" + ($t / 2) + " state=" + $s.PlaybackState + " position=" + [math]::Round($s.Position.TotalSeconds, 2) + " duration=" + [math]::Round($s.NaturalDuration.TotalSeconds, 2) + " volume=" + $mp.Volume + " muted=" + $mp.IsMuted)
  }
  $mp.Pause()
  $mp.Dispose()
  Log "player disposed"
} catch {
  Log ("WinRT MediaPlayer error: " + $_.Exception.Message)
}
[IO.File]::WriteAllLines((Join-Path $Out 'audio.txt'), $lines, $utf8)
