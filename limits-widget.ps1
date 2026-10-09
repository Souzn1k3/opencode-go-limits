#requires -version 5.1
param(
    [switch]$Test,
    [switch]$Smoke,
    [string]$ExePath
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try { [System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::SystemAware) } catch { }

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]'Tls13'
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
}

$script:AppName    = 'OpenCode Go Limits'
$script:AppDir     = Join-Path $env:APPDATA 'opencode-limits-widget'
$script:ConfigPath = Join-Path $script:AppDir 'config.json'
$script:LogPath    = Join-Path $script:AppDir 'widget.log'
$script:AuthPath   = Join-Path $env:USERPROFILE '.local\share\opencode\auth.json'
$script:UsageUrl   = 'https://opencode.ai/zen/go/v1/usage'
$script:RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunValue   = 'OpenCodeLimitsWidget'
$script:Launcher   = if ($ExePath -and (Test-Path -LiteralPath $ExePath)) { $ExePath } else { Join-Path $PSScriptRoot 'OpenCode Limits.exe' }

if (-not (Test-Path -LiteralPath $script:AppDir)) {
    New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
}

$script:C_Bg     = [Drawing.Color]::FromArgb(24, 26, 30)
$script:C_BgAlt  = [Drawing.Color]::FromArgb(33, 36, 42)
$script:C_Track  = [Drawing.Color]::FromArgb(52, 56, 63)
$script:C_Text   = [Drawing.Color]::FromArgb(232, 234, 237)
$script:C_Muted  = [Drawing.Color]::FromArgb(140, 146, 155)
$script:C_Green  = [Drawing.Color]::FromArgb(64, 191, 108)
$script:C_Yellow = [Drawing.Color]::FromArgb(229, 172, 66)
$script:C_Red    = [Drawing.Color]::FromArgb(233, 90, 80)
$script:C_Border = [Drawing.Color]::FromArgb(58, 62, 70)

$script:rows = @(
    @{ key = 'rolling'; title = '5 часов' },
    @{ key = 'weekly';  title = 'неделя'  },
    @{ key = 'monthly'; title = 'месяц'   }
)

function Write-Log {
    param([string]$Message)
    try {
        $line = '[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        $fi = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 262144) {
            $tail = Get-Content -LiteralPath $script:LogPath -Tail 200
            Set-Content -LiteralPath $script:LogPath -Value $tail -Encoding UTF8
        }
    } catch { }
}

function New-DefaultConfig {
    return [pscustomobject]@{
        refreshMinutes  = 5
        notify          = $true
        notifyThreshold = 85
        autostart       = $true
        topMost         = $true
        uiScale         = 1.0
        windowX         = $null
        windowY         = $null
    }
}

function Load-Config {
    $cfg = New-DefaultConfig
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $saved = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) {
                if ($null -ne $cfg.PSObject.Properties[$p.Name]) {
                    $cfg.($p.Name) = $p.Value
                }
            }
        } catch {
            Write-Log "config read error: $($_.Exception.Message)"
        }
    }
    return $cfg
}

function Save-Config {
    try {
        $script:cfg | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    } catch {
        Write-Log "config save error: $($_.Exception.Message)"
    }
}

function Get-ApiKey {
    if (-not (Test-Path -LiteralPath $script:AuthPath)) {
        throw 'OpenCode не настроен. Установите opencode и войдите: opencode auth login'
    }
    $json = Get-Content -LiteralPath $script:AuthPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $entry = $json.PSObject.Properties['opencode-go']
    if ($entry -and $entry.Value.key) { return [string]$entry.Value.key }
    $zen = $json.PSObject.Properties['opencode']
    if ($zen -and $zen.Value.key) {
        throw 'Нужна подписка OpenCode Go: найден только ключ Zen, а лимиты доступны на тарифе Go'
    }
    throw 'Нужна подписка OpenCode Go: ключ opencode-go не найден в auth.json'
}

function Get-Usage {
    param([string]$Key)
    $headers = @{
        Authorization = 'Bearer ' + $Key
        'User-Agent'  = 'opencode-limits-widget/1.2'
    }
    $resp = Invoke-RestMethod -Uri $script:UsageUrl -Headers $headers -Method Get -TimeoutSec 20
    if (-not $resp.usage) { throw 'неожиданный ответ API' }
    return $resp.usage
}

function Get-BarColor {
    param([double]$Percent)
    if ($Percent -ge 85) { return $script:C_Red }
    if ($Percent -ge 60) { return $script:C_Yellow }
    return $script:C_Green
}

function Format-Reset {
    param([string]$Iso)
    if (-not $Iso) { return '' }
    try {
        $dt = [datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
        $d = $dt - [datetime]::Now
        if ($d.TotalSeconds -le 0) { return 'сброс сейчас' }
        if ($d.TotalDays -ge 1) { $rel = '{0} д {1} ч' -f [int]$d.TotalDays, $d.Hours }
        elseif ($d.TotalHours -ge 1) { $rel = '{0} ч {1} мин' -f [int]$d.TotalHours, $d.Minutes }
        else { $rel = '{0} мин' -f [Math]::Max(1, [int]$d.TotalMinutes) }
        return 'сброс через {0} · {1:dd.MM HH:mm}' -f $rel, $dt
    } catch {
        return ''
    }
}

function Format-ResetFull {
    param([string]$Iso)
    if (-not $Iso) { return '' }
    try {
        $dt = [datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
        return 'точное время сброса: ' + $dt.ToString('dd.MM.yyyy HH:mm:ss')
    } catch {
        return ''
    }
}

function Set-Autostart {
    param([bool]$Enabled)
    try {
        if ($Enabled) {
            $cmd = '"{0}"' -f $script:Launcher
            Set-ItemProperty -Path $script:RunKey -Name $script:RunValue -Value $cmd
        } else {
            Remove-ItemProperty -Path $script:RunKey -Name $script:RunValue -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "autostart error: $($_.Exception.Message)"
    }
}

function Test-Autostart {
    try {
        $v = Get-ItemProperty -Path $script:RunKey -Name $script:RunValue -ErrorAction SilentlyContinue
        return [bool]$v
    } catch {
        return $false
    }
}

function Show-PopupNotification {
    param([string]$Title, [string]$Text)
    try {
        if ($script:toastForm -and -not $script:toastForm.IsDisposed) { $script:toastForm.Close() }
        $f = New-Object Windows.Forms.Form
        $f.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
        $f.StartPosition = [Windows.Forms.FormStartPosition]::Manual
        $f.ClientSize = New-Object Drawing.Size 344, 98
        $f.BackColor = $script:C_Bg
        $f.ForeColor = $script:C_Text
        $f.TopMost = $true
        $f.ShowInTaskbar = $false

        $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $f.Location = New-Object Drawing.Point ($wa.Right - $f.Width - 16), ($wa.Bottom - $f.Height - 16)

        $lblTitle = New-Object Windows.Forms.Label
        $lblTitle.Text = $Title
        $lblTitle.Font = New-Object Drawing.Font 'Segoe UI', 9.5, ([Drawing.FontStyle]::Bold)
        $lblTitle.ForeColor = $script:C_Red
        $lblTitle.Location = New-Object Drawing.Point 14, 12
        $lblTitle.AutoSize = $true
        $lblTitle.BackColor = [Drawing.Color]::Transparent

        $lblText = New-Object Windows.Forms.Label
        $lblText.Text = $Text
        $lblText.Font = New-Object Drawing.Font 'Segoe UI', 9
        $lblText.ForeColor = $script:C_Text
        $lblText.Location = New-Object Drawing.Point 14, 36
        $lblText.Size = New-Object Drawing.Size 316, 52
        $lblText.BackColor = [Drawing.Color]::Transparent

        $f.Controls.AddRange(@($lblTitle, $lblText))
        $f.Add_Paint({
            param($s, $e)
            $pen = New-Object Drawing.Pen $script:C_Red, 2
            $e.Graphics.DrawRectangle($pen, 1, 1, $s.ClientSize.Width - 3, $s.ClientSize.Height - 3)
            $pen.Dispose()
        })

        $script:toastForm = $f
        foreach ($c in @($f, $lblTitle, $lblText)) {
            $c.Add_Click({
                if ($script:toastTimer) { $script:toastTimer.Stop() }
                if ($script:toastForm) { $script:toastForm.Close() }
            })
        }

        $t = New-Object Windows.Forms.Timer
        $t.Interval = 10000
        $t.Add_Tick({
            $script:toastTimer.Stop()
            if ($script:toastForm) { $script:toastForm.Close() }
        })
        $script:toastTimer = $t
        $t.Start()
        $f.Show()
    } catch {
        Write-Log "popup error: $($_.Exception.Message)"
    }
}

function Show-Toast {
    param([string]$Title, [string]$Text)
    $shown = $false
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $template.GetElementsByTagName('text')
        [void]$nodes.Item(0).AppendChild($template.CreateTextNode($Title))
        [void]$nodes.Item(1).AppendChild($template.CreateTextNode($Text))
        $toast = New-Object Windows.UI.Notifications.ToastNotification $template
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        $shown = $true
    } catch {
        Write-Log "toast error: $($_.Exception.Message)"
    }
    if (-not $shown) { Show-PopupNotification -Title $Title -Text $Text }
}

function New-IconButton {
    param(
        [string]$Glyph,
        [int]$X,
        [int]$Y,
        [string]$Tip
    )
    $b = New-Object Windows.Forms.Button
    $b.Text = $Glyph
    $b.Font = New-Object Drawing.Font 'Segoe MDL2 Assets', 10
    $b.Size = New-Object Drawing.Size 24, 24
    $b.Location = New-Object Drawing.Point $X, $Y
    $b.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $script:C_BgAlt
    $b.FlatAppearance.MouseDownBackColor = $script:C_Track
    $b.BackColor = $script:C_Bg
    $b.ForeColor = $script:C_Muted
    $b.TabStop = $false
    if ($Tip) { $script:tip.SetToolTip($b, $Tip) }
    return $b
}

function Update-UI {
    if ($script:lastUsage) {
        foreach ($row in $script:rows) {
            $u = $script:lastUsage.PSObject.Properties[$row.key].Value
            if ($u) {
                $pct = [double]$u.percent
                $row.pct.Text = '{0:N0}%' -f $pct
                $row.pct.ForeColor = Get-BarColor -Percent $pct
                $row.fill.Width = [int][Math]::Max(0, [Math]::Min($row.track.Width, [Math]::Round($row.track.Width * $pct / 100)))
                $row.fill.BackColor = Get-BarColor -Percent $pct
                $reset = Format-Reset -Iso $u.resetsAt
                if ($u.status -and $u.status -notin @('ok', 'active')) { $reset = 'лимит исчерпан · ' + $reset }
                $row.reset.Text = $reset
                if ($script:tip) { $script:tip.SetToolTip($row.reset, (Format-ResetFull -Iso $u.resetsAt)) }
            } else {
                $row.pct.Text = '—'
                $row.pct.ForeColor = $script:C_Muted
                $row.fill.Width = 0
                $row.reset.Text = ''
            }
        }
    }

    if ($script:lastError) {
        $text = 'ошибка: ' + $script:lastError
        if ($text.Length -gt 62) {
            $script:status.Text = $text.Substring(0, 60) + '...'
        } else {
            $script:status.Text = $text
        }
        $script:status.ForeColor = $script:C_Red
        if ($script:tip) { $script:tip.SetToolTip($script:status, $script:lastError) }
    } else {
        $script:status.Text = 'обновлено ' + (Get-Date).ToString('HH:mm:ss')
        $script:status.ForeColor = $script:C_Muted
        if ($script:tip) { $script:tip.SetToolTip($script:status, '') }
    }
}

function Update-Data {
    try {
        if (-not $script:apiKey) { $script:apiKey = Get-ApiKey }
        $usage = Get-Usage -Key $script:apiKey
        $script:lastUsage = $usage
        $script:lastError = $null

        $r = $usage.PSObject.Properties['rolling'].Value
        if ($script:cfg.notify -and $r) {
            $pct = [double]$r.percent
            $key = '{0}|{1}' -f $r.resetsAt, $script:cfg.notifyThreshold
            if ($pct -ge [double]$script:cfg.notifyThreshold) {
                if ($script:notifiedKey -ne $key) {
                    $script:notifiedKey = $key
                    Show-Toast -Title 'OpenCode Go — 5-часовой лимит' -Text ('Использовано {0:N0}% (порог {1}%). {2}. Отключить можно в настройках.' -f $pct, $script:cfg.notifyThreshold, (Format-Reset -Iso $r.resetsAt))
                }
            } else {
                $script:notifiedKey = $null
            }
        }
    } catch {
        $msg = $_.Exception.Message
        try {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) {
                $script:apiKey = $null
                $msg = 'ключ отклонён (401) — проверьте auth.json'
            } elseif ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
                $msg = 'сервис лимитов недоступен (404) — возможно, изменился API'
            }
        } catch { }
        if ($msg -match '401') { $script:apiKey = $null }
        $script:lastError = $msg
        Write-Log "update error: $msg"
    }
    Update-UI
}

function Exit-App {
    if ($script:exiting) { return }
    Write-Log 'exit-app called'
    $script:exiting = $true
    try {
        $script:cfg.windowX = $script:form.Location.X
        $script:cfg.windowY = $script:form.Location.Y
        Save-Config
    } catch { }
    try { $script:timer.Stop() } catch { }
    try { $script:uiTimer.Stop() } catch { }
    try { if ($script:toastTimer) { $script:toastTimer.Stop() } } catch { }
    [Windows.Forms.Application]::Exit()
}

function Show-Settings {
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Настройки'
    $dlg.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.StartPosition = [Windows.Forms.FormStartPosition]::CenterParent
    $dlg.BackColor = $script:C_Bg
    $dlg.ForeColor = $script:C_Text
    $dlg.TopMost = $true
    $dlg.ClientSize = New-Object Drawing.Size 322, 250
    $dlg.Font = New-Object Drawing.Font 'Segoe UI', 9

    $lbl1 = New-Object Windows.Forms.Label
    $lbl1.Text = 'Интервал обновления (мин):'
    $lbl1.Location = New-Object Drawing.Point 14, 19
    $lbl1.AutoSize = $true
    $lbl1.ForeColor = $script:C_Text

    $numInterval = New-Object Windows.Forms.NumericUpDown
    $numInterval.Location = New-Object Drawing.Point 232, 16
    $numInterval.Size = New-Object Drawing.Size 76, 24
    $numInterval.Minimum = 1
    $numInterval.Maximum = 120
    $numInterval.Value = [decimal][Math]::Min(120, [Math]::Max(1, [int]$script:cfg.refreshMinutes))
    $numInterval.BackColor = $script:C_BgAlt
    $numInterval.ForeColor = $script:C_Text
    $numInterval.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle

    $cbNotify = New-Object Windows.Forms.CheckBox
    $cbNotify.Text = 'Уведомлять о 5-часовом лимите при превышении порога'
    $cbNotify.Location = New-Object Drawing.Point 14, 50
    $cbNotify.Width = 294
    $cbNotify.Checked = [bool]$script:cfg.notify
    $cbNotify.ForeColor = $script:C_Text
    $cbNotify.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $cbNotify.UseVisualStyleBackColor = $false

    $lbl2 = New-Object Windows.Forms.Label
    $lbl2.Text = 'Порог, %:'
    $lbl2.Location = New-Object Drawing.Point 32, 82
    $lbl2.AutoSize = $true
    $lbl2.ForeColor = $script:C_Muted

    $numThreshold = New-Object Windows.Forms.NumericUpDown
    $numThreshold.Location = New-Object Drawing.Point 232, 79
    $numThreshold.Size = New-Object Drawing.Size 76, 24
    $numThreshold.Minimum = 50
    $numThreshold.Maximum = 100
    $numThreshold.Value = [decimal][Math]::Min(100, [Math]::Max(50, [int]$script:cfg.notifyThreshold))
    $numThreshold.BackColor = $script:C_BgAlt
    $numThreshold.ForeColor = $script:C_Text
    $numThreshold.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle

    $cbAutostart = New-Object Windows.Forms.CheckBox
    $cbAutostart.Text = 'Запускать при входе в Windows'
    $cbAutostart.Location = New-Object Drawing.Point 14, 114
    $cbAutostart.Width = 294
    $cbAutostart.Checked = (Test-Autostart)
    $cbAutostart.ForeColor = $script:C_Text
    $cbAutostart.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $cbAutostart.UseVisualStyleBackColor = $false

    $cbTopMost = New-Object Windows.Forms.CheckBox
    $cbTopMost.Text = 'Окно всегда поверх других окон'
    $cbTopMost.Location = New-Object Drawing.Point 14, 142
    $cbTopMost.Width = 294
    $cbTopMost.Checked = [bool]$script:cfg.topMost
    $cbTopMost.ForeColor = $script:C_Text
    $cbTopMost.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $cbTopMost.UseVisualStyleBackColor = $false

    $btnSave = New-Object Windows.Forms.Button
    $btnSave.Text = 'Сохранить'
    $btnSave.Size = New-Object Drawing.Size 88, 28
    $btnSave.Location = New-Object Drawing.Point 220, 208
    $btnSave.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $btnSave.BackColor = $script:C_BgAlt
    $btnSave.ForeColor = $script:C_Text
    $btnSave.FlatAppearance.BorderColor = $script:C_Border

    $btnCancel = New-Object Windows.Forms.Button
    $btnCancel.Text = 'Отмена'
    $btnCancel.Size = New-Object Drawing.Size 88, 28
    $btnCancel.Location = New-Object Drawing.Point 124, 208
    $btnCancel.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $btnCancel.BackColor = $script:C_BgAlt
    $btnCancel.ForeColor = $script:C_Text
    $btnCancel.FlatAppearance.BorderColor = $script:C_Border

    $btnCancel.Add_Click({ $dlg.Close() })
    $btnSave.Add_Click({
        $script:cfg.refreshMinutes = [int]$numInterval.Value
        $script:cfg.notify = [bool]$cbNotify.Checked
        $script:cfg.notifyThreshold = [int]$numThreshold.Value
        $script:cfg.autostart = [bool]$cbAutostart.Checked
        $script:cfg.topMost = [bool]$cbTopMost.Checked
        $script:timer.Interval = [Math]::Max(1, [int]$script:cfg.refreshMinutes) * 60000
        $script:form.TopMost = [bool]$script:cfg.topMost
        Set-Autostart -Enabled ([bool]$script:cfg.autostart)
        $script:notifiedKey = $null
        Save-Config
        Write-Log 'settings saved'
        $dlg.Close()
    })

    $dlg.Controls.AddRange(@($lbl1, $numInterval, $cbNotify, $lbl2, $numThreshold, $cbAutostart, $cbTopMost, $btnSave, $btnCancel))
    $dlg.AcceptButton = $btnSave
    $dlg.CancelButton = $btnCancel
    [void]$dlg.ShowDialog($script:form)
}

if ($Test) {
    try {
        $key = Get-ApiKey
        $usage = Get-Usage -Key $key
        foreach ($name in @('rolling', 'weekly', 'monthly')) {
            $u = $usage.PSObject.Properties[$name].Value
            if ($u) {
                '{0,-8} {1,5:N0}%  status={2,-8} resets {3}  ({4})' -f $name, [double]$u.percent, $u.status, $u.resetsAt, (Format-Reset -Iso $u.resetsAt)
            }
        }
        'RAW: ' + ($usage | ConvertTo-Json -Compress -Depth 4)
        exit 0
    } catch {
        'FAIL: ' + $_.Exception.Message
        exit 1
    }
}

$created = $false
$script:mutex = [System.Threading.Mutex]::new($true, 'Local\OpenCodeLimitsWidget', [ref]$created)
if (-not $created) {
    Write-Log 'second instance launched, bringing window to front'
    try {
        $signature = @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
        Add-Type -Name WinApi -Namespace LimitsWidget -MemberDefinition $signature
        $hwnd = [LimitsWidget.WinApi]::FindWindow([NullString]::Value, $script:AppName)
        if ($hwnd -ne [IntPtr]::Zero) {
            [void][LimitsWidget.WinApi]::ShowWindow($hwnd, 9)
            [void][LimitsWidget.WinApi]::SetForegroundWindow($hwnd)
            Write-Log 'window focused'
        } else {
            Write-Log 'window not found'
        }
    } catch {
        Write-Log "focus error: $($_.Exception.Message)"
    }
    exit 0
}

Write-Log 'widget starting'
Write-Log ('params: Test={0} Smoke={1} ExePath={2}' -f [bool]$Test, [bool]$Smoke, $ExePath)

$script:cfg = Load-Config
$script:cfg.uiScale = [double][math]::Max(0.75, [math]::Min(1.6, [double]$script:cfg.uiScale))
$script:lastUsage = $null
$script:lastError = $null
$script:apiKey = $null
$script:notifiedKey = $null
$script:exiting = $false
$script:dragging = $false
$script:resizing = $false
$script:toastForm = $null
$script:toastTimer = $null
$script:uiFonts = @()

$script:tip = New-Object Windows.Forms.ToolTip
$script:tip.OwnerDraw = $false

$menu = New-Object Windows.Forms.ContextMenuStrip
$menu.BackColor = $script:C_BgAlt
$menu.ForeColor = $script:C_Text
$menu.ShowImageMargin = $false

$miRefresh = $menu.Items.Add('Обновить сейчас  (F5)')
[void]$menu.Items.Add('-')
$miNotify = $menu.Items.Add('Уведомления о 5ч-лимите')
$miAutostart = $menu.Items.Add('Автозапуск с Windows')
$miTop = $menu.Items.Add('Поверх всех окон')
$miSettings = $menu.Items.Add('Настройки...')
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Выход')

$menu.Add_Opening({
    $miNotify.Checked = [bool]$script:cfg.notify
    $miAutostart.Checked = [bool]$script:cfg.autostart
    $miTop.Checked = [bool]$script:cfg.topMost
})

$miRefresh.Add_Click({ Update-Data })
$miNotify.Add_Click({
    $script:cfg.notify = -not [bool]$script:cfg.notify
    $script:notifiedKey = $null
    Save-Config
})
$miAutostart.Add_Click({
    $script:cfg.autostart = -not [bool]$script:cfg.autostart
    Set-Autostart -Enabled ([bool]$script:cfg.autostart)
    Save-Config
})
$miTop.Add_Click({
    $script:cfg.topMost = -not [bool]$script:cfg.topMost
    $script:form.TopMost = [bool]$script:cfg.topMost
    Save-Config
})
$miSettings.Add_Click({ Show-Settings })
$miExit.Add_Click({ Exit-App })

$form = New-Object Windows.Forms.Form
$script:form = $form
$form.Text = $script:AppName
$form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
$form.ClientSize = New-Object Drawing.Size 320, 224
$form.BackColor = $script:C_Bg
$form.ForeColor = $script:C_Text
$form.TopMost = [bool]$script:cfg.topMost
$form.ShowInTaskbar = $false
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
$form.ContextMenuStrip = $menu
$form.KeyPreview = $true

if ($null -ne $script:cfg.windowX -and $null -ne $script:cfg.windowY) {
    $x = [int]$script:cfg.windowX
    $y = [int]$script:cfg.windowY
    $vs = [Windows.Forms.SystemInformation]::VirtualScreen
    if ($x -gt $vs.Left - $form.Width -and $x -lt $vs.Right + $form.Width -and $y -gt $vs.Top - $form.Height -and $y -lt $vs.Bottom + $form.Height) {
        $form.Location = New-Object Drawing.Point $x, $y
    } else {
        $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $form.Location = New-Object Drawing.Point ($wa.Right - $form.Width - 24), ($wa.Bottom - $form.Height - 24)
    }
} else {
    $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object Drawing.Point ($wa.Right - $form.Width - 24), ($wa.Bottom - $form.Height - 24)
}

$form.Add_Paint({
    param($s, $e)
    $pen = New-Object Drawing.Pen $script:C_Border
    $e.Graphics.DrawRectangle($pen, 0, 0, $s.ClientSize.Width - 1, $s.ClientSize.Height - 1)
    $pen.Dispose()
})

$lblTitle = New-Object Windows.Forms.Label
$script:lblTitle = $lblTitle
$lblTitle.Text = 'OpenCode Go'
$lblTitle.Font = New-Object Drawing.Font 'Segoe UI', 10, ([Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $script:C_Text
$lblTitle.Location = New-Object Drawing.Point 12, 9
$lblTitle.AutoSize = $true
$lblTitle.BackColor = [Drawing.Color]::Transparent
$form.Controls.Add($lblTitle)

$btnRefresh = New-IconButton -Glyph ([char]0xE72C) -X 228 -Y 6 -Tip 'Обновить сейчас (F5)'
$btnSettings = New-IconButton -Glyph ([char]0xE713) -X 256 -Y 6 -Tip 'Настройки'
$btnClose = New-IconButton -Glyph ([char]0xE8BB) -X 284 -Y 6 -Tip 'Закрыть'
$script:btnRefresh = $btnRefresh
$script:btnSettings = $btnSettings
$script:btnClose = $btnClose
$btnClose.FlatAppearance.MouseOverBackColor = $script:C_Red
$btnClose.FlatAppearance.MouseDownBackColor = $script:C_Red
$btnClose.ForeColor = $script:C_Text
$btnRefresh.Add_Click({ Update-Data })
$btnSettings.Add_Click({ Show-Settings })
$btnClose.Add_Click({ Write-Log 'close button clicked'; $script:form.Close() })
$form.Controls.AddRange(@($btnRefresh, $btnSettings, $btnClose))

$y = 46
$lastBottom = 0
foreach ($row in $script:rows) {
    $lblName = New-Object Windows.Forms.Label
    $lblName.Text = $row.title
    $lblName.Font = New-Object Drawing.Font 'Segoe UI', 8.5
    $lblName.ForeColor = $script:C_Muted
    $lblName.Location = New-Object Drawing.Point 12, $y
    $lblName.AutoSize = $true
    $lblName.BackColor = [Drawing.Color]::Transparent
    $form.Controls.Add($lblName)

    $lblPct = New-Object Windows.Forms.Label
    $lblPct.Text = '—'
    $lblPct.Font = New-Object Drawing.Font 'Segoe UI', 8.5, ([Drawing.FontStyle]::Bold)
    $lblPct.ForeColor = $script:C_Text
    $lblPct.Location = New-Object Drawing.Point 236, ($y - 1)
    $lblPct.Size = New-Object Drawing.Size 72, 15
    $lblPct.TextAlign = [Drawing.ContentAlignment]::MiddleRight
    $lblPct.BackColor = [Drawing.Color]::Transparent
    $form.Controls.Add($lblPct)

    $track = New-Object Windows.Forms.Panel
    $track.Location = New-Object Drawing.Point 12, ($y + 20)
    $track.Size = New-Object Drawing.Size 296, 8
    $track.BackColor = $script:C_Track
    $form.Controls.Add($track)

    $fill = New-Object Windows.Forms.Panel
    $fill.Location = New-Object Drawing.Point 0, 0
    $fill.Size = New-Object Drawing.Size 0, 8
    $fill.BackColor = $script:C_Green
    $track.Controls.Add($fill)

    $lblReset = New-Object Windows.Forms.Label
    $lblReset.Text = ''
    $lblReset.Font = New-Object Drawing.Font 'Segoe UI', 7.5
    $lblReset.ForeColor = $script:C_Muted
    $lblReset.Location = New-Object Drawing.Point 12, ($y + 31)
    $lblReset.Size = New-Object Drawing.Size 296, 14
    $lblReset.BackColor = [Drawing.Color]::Transparent
    $form.Controls.Add($lblReset)

    $row['name'] = $lblName
    $row['pct'] = $lblPct
    $row['track'] = $track
    $row['fill'] = $fill
    $row['reset'] = $lblReset

    $lastBottom = $y + 31 + 14
    $y += 54
}

$status = New-Object Windows.Forms.Label
$status.Text = 'загрузка...'
$status.Font = New-Object Drawing.Font 'Segoe UI', 7.5
$status.ForeColor = $script:C_Muted
$status.Location = New-Object Drawing.Point 12, ($lastBottom + 6)
$status.Size = New-Object Drawing.Size 296, 14
$status.BackColor = [Drawing.Color]::Transparent
$form.Controls.Add($status)
$script:status = $status

function Update-Layout {
    $s = [double]$script:cfg.uiScale
    if ($s -lt 0.75) { $s = 0.75 }
    if ($s -gt 1.6) { $s = 1.6 }

    $dpiF = 1.0
    try { if ($script:form.IsHandleCreated) { $dpiF = $script:form.DeviceDpi / 96.0 } } catch { }
    $eff = $s * $dpiF

    $oldFonts = $script:uiFonts
    $fTitle = New-Object Drawing.Font 'Segoe UI', ([single][math]::Round(10 * $s, 1)), ([Drawing.FontStyle]::Bold)
    $fIcon  = New-Object Drawing.Font 'Segoe MDL2 Assets', ([single][math]::Round(10 * $s, 1))
    $fName  = New-Object Drawing.Font 'Segoe UI', ([single][math]::Round(8.5 * $s, 1))
    $fPct   = New-Object Drawing.Font 'Segoe UI', ([single][math]::Round(8.5 * $s, 1)), ([Drawing.FontStyle]::Bold)
    $fSmall = New-Object Drawing.Font 'Segoe UI', ([single][math]::Round(7.5 * $s, 1))
    $script:uiFonts = @($fTitle, $fIcon, $fName, $fPct, $fSmall)

    $script:lblTitle.Font = $fTitle
    $script:btnRefresh.Font = $fIcon
    $script:btnSettings.Font = $fIcon
    $script:btnClose.Font = $fIcon
    $script:status.Font = $fSmall
    foreach ($row in $script:rows) {
        $row.name.Font = $fName
        $row.pct.Font = $fPct
        $row.reset.Font = $fSmall
    }

    $mx = [int][math]::Round(12 * $eff)
    $width = [int][math]::Round(320 * $eff)
    $gapSmall = [int][math]::Max(3, [int][math]::Round(5 * $eff))
    $gapName = [int][math]::Max(4, [int][math]::Round(7 * $eff))
    $gapReset = [int][math]::Max(3, [int][math]::Round(5 * $eff))
    $rowGap = [int][math]::Max(8, [int][math]::Round(13 * $eff))

    $btnSize = [int][math]::Max(16, [int][math]::Round(22 * $eff))
    $script:btnRefresh.Size = New-Object Drawing.Size $btnSize, $btnSize
    $script:btnSettings.Size = New-Object Drawing.Size $btnSize, $btnSize
    $script:btnClose.Size = New-Object Drawing.Size $btnSize, $btnSize

    $titleH = $script:lblTitle.PreferredHeight
    $headerH = [int][math]::Max($titleH, $btnSize)
    $script:lblTitle.Location = New-Object Drawing.Point $mx, ([int][math]::Round(($headerH - $titleH) / 2))
    $btnY = [int][math]::Round(($headerH - $btnSize) / 2)
    $script:btnClose.Location = New-Object Drawing.Point ($width - $mx - $btnSize), $btnY
    $script:btnSettings.Location = New-Object Drawing.Point ($width - $mx - 2 * $btnSize - $gapSmall), $btnY
    $script:btnRefresh.Location = New-Object Drawing.Point ($width - $mx - 3 * $btnSize - 2 * $gapSmall), $btnY

    $trackW = $width - 2 * $mx
    $barH = [int][math]::Max(5, [int][math]::Round(8 * $eff))

    $y = $headerH + [int][math]::Round(8 * $eff)
    foreach ($row in $script:rows) {
        $nameH = $row.name.PreferredHeight
        $row.name.Location = New-Object Drawing.Point $mx, $y

        $pctW = [int][math]::Round(72 * $eff)
        $row.pct.Size = New-Object Drawing.Size $pctW, $nameH
        $row.pct.Location = New-Object Drawing.Point ($width - $mx - $pctW), $y

        $trackY = $y + $nameH + $gapName
        $row.track.Size = New-Object Drawing.Size $trackW, $barH
        $row.track.Location = New-Object Drawing.Point $mx, $trackY
        $row.fill.Size = New-Object Drawing.Size 0, $barH

        $resetY = $trackY + $barH + $gapReset
        $resetH = $row.reset.PreferredHeight
        $row.reset.Size = New-Object Drawing.Size $trackW, $resetH
        $row.reset.Location = New-Object Drawing.Point $mx, $resetY

        $y = $resetY + $resetH + $rowGap
    }

    $statusH = $script:status.PreferredHeight
    $script:status.Size = New-Object Drawing.Size $trackW, $statusH
    $script:status.Location = New-Object Drawing.Point $mx, $y

    $form.ClientSize = New-Object Drawing.Size $width, ($y + $statusH + [int][math]::Round(6 * $eff))

    $gripSize = [int][math]::Max(12, [int][math]::Round(14 * $eff))
    $script:grip.Size = New-Object Drawing.Size $gripSize, $gripSize
    $script:grip.Location = New-Object Drawing.Point ($form.ClientSize.Width - $gripSize), ($form.ClientSize.Height - $gripSize)

    foreach ($f in $oldFonts) { try { $f.Dispose() } catch { } }

    Update-UI
}

function Add-DragHandlers {
    param([Windows.Forms.Control]$Root)
    $Root.ContextMenuStrip = $menu
    if (-not ($Root -is [Windows.Forms.Button])) {
        $Root.Add_MouseDown({
            param($s, $e)
            if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) {
                $script:dragging = $true
                $script:dragStart = [Windows.Forms.Cursor]::Position
                $script:dragFormStart = $script:form.Location
            }
        })
        $Root.Add_MouseMove({
            param($s, $e)
            if ($script:dragging) {
                $p = [Windows.Forms.Cursor]::Position
                $script:form.Location = New-Object Drawing.Point (($script:dragFormStart.X + $p.X - $script:dragStart.X), ($script:dragFormStart.Y + $p.Y - $script:dragStart.Y))
            }
        })
        $Root.Add_MouseUp({
            param($s, $e)
            if ($script:dragging) {
                $script:dragging = $false
                $script:cfg.windowX = $script:form.Location.X
                $script:cfg.windowY = $script:form.Location.Y
                Save-Config
            }
        })
    }
    foreach ($child in $Root.Controls) { Add-DragHandlers -Root $child }
}

Add-DragHandlers -Root $form

$grip = New-Object Windows.Forms.Panel
$grip.BackColor = $script:C_Bg
$grip.Cursor = [Windows.Forms.Cursors]::SizeNWSE
$grip.Tag = 'grip'
$grip.Add_Paint({
    param($s, $e)
    $pen = New-Object Drawing.Pen $script:C_Muted
    $w = $s.ClientSize.Width
    $h = $s.ClientSize.Height
    for ($i = 1; $i -le 3; $i++) {
        $off = $i * 4
        $e.Graphics.DrawLine($pen, ($w - $off - 1), ($h - 1), ($w - 1), ($h - $off - 1))
    }
    $pen.Dispose()
})
$form.Controls.Add($grip)
$script:grip = $grip
$script:tip.SetToolTip($grip, 'Потяни за уголок, чтобы изменить размер')

$grip.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) {
        $script:resizing = $true
        $script:resizeStartScale = [double]$script:cfg.uiScale
        $script:resizeStart = [Windows.Forms.Cursor]::Position
    }
})
$grip.Add_MouseMove({
    param($s, $e)
    if ($script:resizing) {
        $p = [Windows.Forms.Cursor]::Position
        $dx = $p.X - $script:resizeStart.X
        $dy = $p.Y - $script:resizeStart.Y
        $ns = $script:resizeStartScale + ($dx + $dy) / 800.0
        $ns = [math]::Max(0.75, [math]::Min(1.6, $ns))
        $snapped = [math]::Round($ns * 20) / 20
        if ([math]::Abs($snapped - [double]$script:cfg.uiScale) -gt 0.001) {
            $script:cfg.uiScale = $snapped
            Update-Layout
        }
    }
})
$grip.Add_MouseUp({
    param($s, $e)
    if ($script:resizing) {
        $script:resizing = $false
        Save-Config
        Write-Log ('uiScale saved: ' + $script:cfg.uiScale)
    }
})

[void]$form.Handle
Update-Layout

$timer = New-Object Windows.Forms.Timer
$script:timer = $timer
$timer.Interval = [Math]::Max(1, [int]$script:cfg.refreshMinutes) * 60000
$timer.Add_Tick({ Update-Data })

$uiTimer = New-Object Windows.Forms.Timer
$script:uiTimer = $uiTimer
$uiTimer.Interval = 30000
$uiTimer.Add_Tick({ Update-UI })

$form.Add_Shown({
    Update-Data
    $script:timer.Start()
    $script:uiTimer.Start()
    if ($Smoke) {
        $script:smokeTimer = New-Object Windows.Forms.Timer
        $script:smokeTimer.Interval = 6000
        $script:smokeTimer.Add_Tick({
            $script:smokeTimer.Stop()
            if ($script:lastError) { Write-Log 'SMOKE FAIL: ' + $script:lastError } else { Write-Log 'SMOKE OK' }
            Exit-App
        })
        $script:smokeTimer.Start()
    }
})

$form.Add_FormClosing({
    param($s, $e)
    Write-Log "form closing (exiting=$($script:exiting), reason=$($e.CloseReason))"
    try {
        $script:cfg.windowX = $script:form.Location.X
        $script:cfg.windowY = $script:form.Location.Y
        Save-Config
    } catch { }
})

$form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) { Write-Log 'escape pressed'; $script:form.Close() }
    if ($e.KeyCode -eq [Windows.Forms.Keys]::F5) { Update-Data }
})

$form.Add_FormClosed({ Write-Log 'form closed' })

Set-Autostart -Enabled ([bool]$script:cfg.autostart)

Write-Log 'widget started'
[Windows.Forms.Application]::Run($form)
Write-Log 'widget stopped'
try { $script:mutex.ReleaseMutex() } catch { }
