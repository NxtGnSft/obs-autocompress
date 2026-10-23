# Asks whether a compressed recording should go to Whisperwise (ww.nextgensoft.co), and uploads it.
# Started detached by compress.ps1 after each successful compress. Unanswered questions live in
# pending\ and are asked again the next time this script runs (compress.ps1 does it on every run;
# by hand: powershell -ExecutionPolicy Bypass -File ask-upload.ps1).
param([string]$File, [string]$Title)

$ErrorActionPreference = 'Stop'
$Root       = $PSScriptRoot
$PendingDir = Join-Path $Root 'pending'
$LogFile    = Join-Path $Root 'upload.log'
$ConfigFile = Join-Path $Root 'whisperwise.config.json'
New-Item -ItemType Directory -Force $PendingDir | Out-Null

$Lang = try { (Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json).lang } catch { $null }
$T = @{
    en = @{ Title = 'Whisperwise: send recording?'; Compressed = 'Recording compressed: {0} ({1:N1} MB).'
            Project = 'Project:'; Name = 'Title:'; Send = 'Send'; Keep = 'No, keep it'
            PickProject = 'Choose a project.'; NoProjects = 'Could not fetch projects: '; Sent = 'Sent: ' }
    ru = @{ Title = 'Whisperwise: отправить запись?'; Compressed = 'Запись сжата: {0} ({1:N1} МБ).'
            Project = 'Проект:'; Name = 'Название:'; Send = 'Отправить'; Keep = 'Нет, оставить себе'
            PickProject = 'Выберите проект.'; NoProjects = 'Не удалось получить проекты: '; Sent = 'Отправлено: ' }
}[$(if ($Lang -eq 'ru') { 'ru' } else { 'en' })]

function Log($msg) {
    Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg) -Encoding UTF8
}

# One dialog at a time; the rest wait in pending\ and are drained by the holder.
$mutex = New-Object Threading.Mutex($false, 'Global\OBSAutoUploadAsk')
if ($File) {
    $q = Join-Path $PendingDir ('{0:yyyyMMdd-HHmmss-fff}-{1}.json' -f (Get-Date), [guid]::NewGuid().ToString('N').Substring(0, 6))
    @{ file = $File; title = $Title } | ConvertTo-Json | Set-Content -Path $q -Encoding UTF8
}
try { [void]$mutex.WaitOne() } catch [Threading.AbandonedMutexException] { }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Net.Http

function Read-Config {
    if (-not (Test-Path $ConfigFile)) { throw "missing $ConfigFile" }
    $c = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $c.token) { throw 'token is empty in whisperwise.config.json' }
    return $c
}

function New-Client($cfg) {
    $h = New-Object Net.Http.HttpClientHandler
    $cl = New-Object Net.Http.HttpClient($h)
    $cl.Timeout = [TimeSpan]::FromMinutes(30)
    $cl.DefaultRequestHeaders.Add('Authorization', "Bearer $($cfg.token)")
    return $cl
}

function Get-Projects($cfg) {
    $cl = New-Client $cfg
    try {
        $r = $cl.GetAsync("$($cfg.baseUrl)/api/projects").Result
        $body = [Text.Encoding]::UTF8.GetString($r.Content.ReadAsByteArrayAsync().Result)   # server sends no charset
        if (-not $r.IsSuccessStatusCode) { throw "projects: HTTP $([int]$r.StatusCode) $body" }
        $j = $body | ConvertFrom-Json
        # shape: { teams: [ { name, projects: [ { id, name, state } ] } ] }
        $multi = @($j.teams).Count -gt 1
        $list = foreach ($t in $j.teams) { foreach ($p in $t.projects) {
            [pscustomobject]@{ id = $p.id; name = $(if ($multi) { "$($t.name) / $($p.name.Trim())" } else { $p.name.Trim() }) } } }
        if (-not $list) { throw 'no Whisperwise projects available to you' }
        return @($list | Sort-Object name)
    } finally { $cl.Dispose() }
}

function Send-File($cfg, $file, $title, $projectId) {
    # curl.exe (built into Windows 10/11): the .NET multipart request made the server answer "Internal Server Error".
    $tf = Join-Path $env:TEMP ('ww-title-{0}.txt' -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tf, [string]$title, (New-Object Text.UTF8Encoding $false))
    try {
        $out = & curl.exe -s -m 3600 -H "Authorization: Bearer $($cfg.token)" `
            -F "audio=@$file;type=video/mp4" -F "external_project_id=$projectId" -F "title=<$tf" "$($cfg.baseUrl)/upload"
        $body = ($out -join "`
")
        Log "server response: $($body.Substring(0, [Math]::Min(300, $body.Length)))"
        try { $j = $body | ConvertFrom-Json } catch { throw "upload: unexpected server response: $body" }
        if ($j.error) { throw "upload: $($j.error) $($j.message)" }
        if (-not $j.shareUrl) { throw "upload: no link in response: $body" }
        return $j
    } finally { Remove-Item $tf -ErrorAction SilentlyContinue }
}

Add-Type -Namespace W -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, int flags, int extra);
'@
# A process started hidden inherits SW_HIDE for its first window, so force-show it, and
# tap Alt so Windows lets it take the foreground.
function Show-Front($f) {
    $f.WindowState = 'Normal'
    [void][W.U]::ShowWindow($f.Handle, 5)
    $f.TopMost = $false; $f.TopMost = $true
    [W.U]::keybd_event(0x12, 0, 0, 0); [W.U]::keybd_event(0x12, 0, 2, 0)
    [void][W.U]::SetForegroundWindow($f.Handle)
    $f.Activate()
}

# Returns @{ answer = 'send'|'no'; projectId; title }. The window stays until answered.
function Ask($file, $title, $projects, $err) {
    $f = New-Object Windows.Forms.Form
    $f.Text = $T.Title
    $f.TopMost = $true
    $f.StartPosition = 'CenterScreen'
    $f.ControlBox = $false             # no X: only Send or Keep
    $f.FormBorderStyle = 'FixedDialog'
    $f.ClientSize = New-Object Drawing.Size(520, 260)
    $f.Font = New-Object Drawing.Font('Segoe UI', 10)

    $mb = (Get-Item -LiteralPath $file).Length / 1MB
    $l1 = New-Object Windows.Forms.Label
    $l1.Text = ($T.Compressed -f [IO.Path]::GetFileName($file), $mb)
    $l1.SetBounds(16, 14, 488, 44)
    $f.Controls.Add($l1)

    $l2 = New-Object Windows.Forms.Label; $l2.Text = $T.Project; $l2.SetBounds(16, 66, 80, 24); $f.Controls.Add($l2)
    $cb = New-Object Windows.Forms.ComboBox
    $cb.DropDownStyle = 'DropDownList'; $cb.SetBounds(100, 62, 404, 28)
    foreach ($p in $projects) { [void]$cb.Items.Add([string]$p.name) }   # parallel to $projects by index
    if ($projects.Count -eq 1) { $cb.SelectedIndex = 0 }
    $f.Controls.Add($cb)

    $l3 = New-Object Windows.Forms.Label; $l3.Text = $T.Name; $l3.SetBounds(16, 106, 80, 24); $f.Controls.Add($l3)
    $tb = New-Object Windows.Forms.TextBox; $tb.Text = $title; $tb.SetBounds(100, 102, 404, 28); $f.Controls.Add($tb)

    $le = New-Object Windows.Forms.Label
    $le.ForeColor = [Drawing.Color]::Firebrick; $le.Text = $err; $le.SetBounds(16, 140, 488, 50)
    $f.Controls.Add($le)

    $yes = New-Object Windows.Forms.Button; $yes.Text = $T.Send; $yes.SetBounds(100, 205, 190, 40)
    $no  = New-Object Windows.Forms.Button; $no.Text = $T.Keep; $no.SetBounds(310, 205, 194, 40)
    $f.Controls.AddRange(@($yes, $no))
    $res = @{ answer = $null }
    $yes.Add_Click({
        if ($cb.SelectedIndex -ge 0) { $res.answer = 'send'; $f.Close() }
        else { [void][Windows.Forms.MessageBox]::Show($f, $T.PickProject, 'Whisperwise') }
    })
    $no.Add_Click({ $res.answer = 'no'; $f.Close() })
    $f.Add_Shown({ Show-Front $f; [Media.SystemSounds]::Exclamation.Play() })
    # Re-grab attention if the window is left unanswered.
    $t = New-Object Windows.Forms.Timer; $t.Interval = 60000
    $t.Add_Tick({ Show-Front $f; [Media.SystemSounds]::Exclamation.Play() })
    $t.Start()
    [void]$f.ShowDialog()
    $t.Stop(); $t.Dispose()
    $idx = $cb.SelectedIndex
    $f.Dispose()
    return @{ answer = $res.answer; projectId = $(if ($idx -ge 0) { [string]$projects[$idx].id } else { $null }); title = $tb.Text.Trim() }
}

try {
    while ($item = Get-ChildItem $PendingDir -Filter *.json | Sort-Object Name | Select-Object -First 1) {
        $job = Get-Content $item.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not (Test-Path -LiteralPath $job.file)) { Log "skip, file not found: $($job.file)"; Remove-Item $item.FullName; continue }
        $err = ''
        $projects = @()
        $cfg = $null
        try { $cfg = Read-Config; $projects = Get-Projects $cfg } catch { $err = $T.NoProjects + $_.Exception.Message }
        while ($true) {
            $a = Ask $job.file $job.title $projects $err
            if ($a.answer -eq 'no') { Log "declined: $($job.file)"; break }
            if ($err -and -not $projects.Count) {   # config/projects broken: retry fetch instead of failing silently
                try { $cfg = Read-Config; $projects = Get-Projects $cfg; $err = '' } catch { $err = $T.NoProjects + $_.Exception.Message }
                continue
            }
            try {
                $r = Send-File $cfg $job.file $a.title $a.projectId
                Log "sent: $($job.file) -> $($r.shareUrl) status=$($r.status) duplicate=$($r.duplicate)"
                $n = New-Object Windows.Forms.NotifyIcon
                $n.Icon = [Drawing.SystemIcons]::Information; $n.Visible = $true
                $n.ShowBalloonTip(10000, 'Whisperwise', ($T.Sent + $r.shareUrl), 'Info'); Start-Sleep 6; $n.Dispose()
                break
            } catch {
                $err = $_.Exception.Message
                Log "ERROR uploading $($job.file): $err"
            }
        }
        Remove-Item $item.FullName
    }
} finally {
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
