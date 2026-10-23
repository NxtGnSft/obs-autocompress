# Compresses OBS recordings with HandBrakeCLI.
# Called by obs-autocompress.lua after a recording stops; the Lua script drops
# the recording path into queue\ and starts this worker. Can also be run by hand:
#   powershell -ExecutionPolicy Bypass -File compress.ps1 "$HOME\Videos\meeting.mp4" ...
param([string[]]$Path)

# ---- settings ----------------------------------------------------------------
$OutDir         = Join-Path $env:USERPROFILE 'Videos\compressed'
$Quality        = 24       # lower = better picture and bigger file (QSV ICQ, 1-51)
$Fps            = 15       # meetings do not need 30 fps
$AudioKbps      = 64       # mono AAC, plenty for speech / Whisper
$DeleteOriginal = $false   # $true deletes the source after a successful compress
# ------------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$Root     = $PSScriptRoot
$QueueDir = Join-Path $Root 'queue'
$FailDir  = Join-Path $Root 'failed'
$LogFile  = Join-Path $Root 'compress.log'
foreach ($d in $QueueDir, $FailDir, $OutDir) { New-Item -ItemType Directory -Force $d | Out-Null }

function Log($msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Notify($title, $text) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Information
        $n.Visible = $true
        $n.ShowBalloonTip(10000, $title, $text, 'Info')
        Start-Sleep -Seconds 10
        $n.Dispose()
    } catch { }
}

function Find-HandBrakeCli {
    $cmd = Get-Command HandBrakeCLI -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $hit = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter HandBrakeCLI.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($hit) { return $hit.FullName }
    throw 'HandBrakeCLI.exe not found (winget install HandBrake.HandBrake.CLI)'
}

# OBS may still be finalizing the file for a few seconds after the stop event.
# FileShare.None failed on long recordings (Defender / indexer / a browser upload can hold a read handle
# for many minutes, 15.10 and 20.10). HandBrake only reads, so shared access is enough; we just need the
# file to stop growing and to be openable.
function Wait-Unlocked($file, $timeoutSec = 3600) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $lastSize = -1
    while ((Get-Date) -lt $deadline) {
        try {
            $s = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite, Delete')
            $size = $s.Length
            $s.Close()
            if ($size -eq $lastSize -and $size -gt 0) { return $true }
            $lastSize = $size
        } catch { $lastSize = -1 }
        Start-Sleep -Seconds 5
    }
    return $false
}
function Compress($cli, $src) {
    if (-not (Test-Path -LiteralPath $src)) { throw "file not found: $src" }
    if (-not (Wait-Unlocked $src)) { throw "file still locked after 60 min: $src" }

    $name = [IO.Path]::GetFileNameWithoutExtension($src)
    $dst  = Join-Path $OutDir "$name.mp4"
    $part = Join-Path $OutDir "$name.part.mp4"
    if (Test-Path -LiteralPath $dst) { Log "skip, already compressed: $dst"; return }

    $srcMb = (Get-Item -LiteralPath $src).Length / 1MB
    Log ('start {0} ({1:N0} MB)' -f $src, $srcMb)
    $hbArgs = @(
        '-i', "`"$src`"", '-o', "`"$part`"",
        '-e', 'qsv_h265', '--encoder-preset', 'balanced', '--enable-qsv-decoding', '-q', $Quality,
        '--rate', $Fps, '--pfr',
        '-E', 'av_aac', '-B', $AudioKbps, '--mixdown', 'mono',
        '--optimize'
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # OBS can still be finalizing the mp4 (writing moov) after the lock is released and the stop event
    # has fired: HandBrake then answers "unrecognized file type" (exit 2). Retry for up to ~10 min.
    for ($try = 1; $try -le 20; $try++) {
        $p = Start-Process -FilePath $cli -ArgumentList $hbArgs -WindowStyle Hidden -PassThru `
            -RedirectStandardError (Join-Path $Root 'handbrake-last.log') -RedirectStandardOutput (Join-Path $Root 'handbrake-progress.log')
        $null = $p.Handle  # PS 5.1: without touching Handle early, ExitCode comes back empty
        try { $p.PriorityClass = 'BelowNormal' } catch { }
        $p.WaitForExit()
        if ($p.ExitCode -eq 0) { break }
        $notReady = Select-String -Path (Join-Path $Root 'handbrake-last.log') -SimpleMatch 'unrecognized file type' -Quiet
        if (-not $notReady -or $try -eq 20) { break }
        Log "file not ready yet (attempt $try), waiting 30 s: $src"
        Start-Sleep -Seconds 30
    }

    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $part) -or (Get-Item -LiteralPath $part).Length -lt 10KB) {
        Remove-Item -LiteralPath $part -ErrorAction SilentlyContinue
        throw "HandBrakeCLI exit code $($p.ExitCode), see handbrake-last.log"
    }
    Move-Item -LiteralPath $part -Destination $dst
    $dstMb = (Get-Item -LiteralPath $dst).Length / 1MB
    Log ('done  {0} -> {1:N1} MB in {2:N0} min' -f $dst, $dstMb, $sw.Elapsed.TotalMinutes)

    if ($DeleteOriginal) { Remove-Item -LiteralPath $src; Log "deleted original: $src" }
    # Ask (detached, so the queue is not blocked by an open dialog) whether to send it to Whisperwise.
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'ask-upload.ps1')`"",
        '-File', "`"$dst`"", '-Title', "`"$name`"")
}

# Re-ask about recordings whose upload question was never answered (reboot, closed session).
if (Get-ChildItem (Join-Path $Root 'pending') -Filter *.json -ErrorAction SilentlyContinue) {
    Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'ask-upload.ps1')`"")
}

# Manual run: put the given files into the queue.
foreach ($f in $Path) {
    $full = (Resolve-Path -LiteralPath $f).Path
    $q = Join-Path $QueueDir ('{0:yyyyMMdd-HHmmss-fff}-{1}.txt' -f (Get-Date), [guid]::NewGuid().ToString('N').Substring(0, 6))
    [IO.File]::WriteAllText($q, $full, (New-Object Text.UTF8Encoding $false))
}

# One worker at a time; a second worker waits and then drains whatever is left.
$mutex = New-Object Threading.Mutex($false, 'Global\OBSAutoCompress')
try { [void]$mutex.WaitOne() } catch [Threading.AbandonedMutexException] { }
try {
    $cli = Find-HandBrakeCli
    while ($item = Get-ChildItem $QueueDir -Filter *.txt | Sort-Object Name | Select-Object -First 1) {
        $src = ([IO.File]::ReadAllText($item.FullName, [Text.Encoding]::UTF8)).Trim()
        try {
            Compress $cli $src
            Remove-Item -LiteralPath $item.FullName
        } catch {
            Log "FAIL  $src : $($_.Exception.Message)"
            Move-Item -LiteralPath $item.FullName -Destination $FailDir -Force
            $lang = try { (Get-Content (Join-Path $Root 'whisperwise.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).lang } catch { $null }
            Notify $(if ($lang -eq 'ru') { 'Сжатие не удалось' } else { 'Compression failed' }) "$([IO.Path]::GetFileName($src)): $($_.Exception.Message)"
        }
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
