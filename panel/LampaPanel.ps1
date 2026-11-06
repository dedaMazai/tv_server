# Панель управления: Lampa (служба Caddy) + TorrServer. Настройки: config.json рядом (создаёт install.ps1).
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$cfgPath = Join-Path $PSScriptRoot 'config.json'
if (-not (Test-Path $cfgPath)) {
    [Windows.Forms.MessageBox]::Show("Нет файла настроек:`n$cfgPath`n`nЗапустите install.ps1.", 'Lampa сервер', 'OK', 'Error') | Out-Null
    exit 1
}
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

$IP       = $cfg.ip
$LampaUrl = "http://${IP}:$($cfg.lampaPort)/"
$MsxUrl   = "http://${IP}:$($cfg.lampaPort)/msx/start.json"
$TorrUrl  = "http://${IP}:$($cfg.torrPort)/"
$Site     = $cfg.siteDir
$TorrDir  = $cfg.torrDir
$Svc      = $cfg.serviceName
$script:Jackett = if ($cfg.PSObject.Properties['jackettUrl'] -and $cfg.jackettUrl) { [string]$cfg.jackettUrl } else { 'https://jr.maxvol.pro' }
. (Join-Path $PSScriptRoot 'TvDefaults.ps1')

# Проверка парсера идёт асинхронно (публичный Jackett отвечает 5-15 с), окно не подвисает
Add-Type -AssemblyName System.Net.Http
$script:http = New-Object System.Net.Http.HttpClient
$script:http.Timeout = [TimeSpan]::FromSeconds(40)
$script:pTask = $null; $script:pSw = $null; $script:pTicks = 0

function Test-Http([string]$url) {
    try {
        $req = [Net.HttpWebRequest]::Create($url)
        $req.Timeout = 1000; $req.ReadWriteTimeout = 1000; $req.Proxy = $null
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd(); $code = [int]$resp.StatusCode; $resp.Close()
        return @{ ok = $true; code = $code; body = $body }
    } catch { return @{ ok = $false } }
}

function Get-ServiceText {
    $sv = Get-Service $Svc -ErrorAction SilentlyContinue
    if (-not $sv) { return "Служба ${Svc}: не установлена" }
    $s = switch ([string]$sv.Status) { 'Running' {'работает'} 'Stopped' {'остановлена'} 'StartPending' {'запускается'} 'StopPending' {'останавливается'} default {[string]$sv.Status} }
    $a = switch ([string]$sv.StartType) { 'Automatic' {'автозапуск вкл.'} 'Disabled' {'автозапуск ОТКЛЮЧЁН'} default {"запуск: $($sv.StartType)"} }
    return "Служба ${Svc}: $s, $a"
}

# Действия со службой/TorrServer требуют прав администратора: ServiceAction.ps1 запускается через UAC
function Invoke-Elevated([string]$target, [string]$action) {
    $res = Join-Path $env:TEMP 'LampaPanel_result.txt'
    Remove-Item $res -ErrorAction SilentlyContinue
    $script = Join-Path $PSScriptRoot 'ServiceAction.ps1'
    try {
        Start-Process powershell -Verb RunAs -WindowStyle Hidden -Wait -ErrorAction Stop `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Target $target -Action $action -ResultFile `"$res`""
        $out = if (Test-Path $res) { (Get-Content $res -Raw -Encoding UTF8).Trim() } else { 'Нет результата' }
        if ($out -ne 'OK') { [Windows.Forms.MessageBox]::Show("Не получилось:`n$out", 'Lampa сервер', 'OK', 'Warning') | Out-Null }
        else { Start-Sleep 2 }
    } catch {
        [Windows.Forms.MessageBox]::Show('Действие отменено (нужны права администратора).', 'Lampa сервер') | Out-Null
    }
    Update-Status
}

# ---------- UI ----------
$form = New-Object Windows.Forms.Form
$form.Text = 'Lampa сервер для ТВ'
$form.Size = New-Object Drawing.Size(470, 565)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$ico = Join-Path $PSScriptRoot 'lampa.ico'
if (Test-Path $ico) { $form.Icon = New-Object Drawing.Icon($ico) }

function New-Label($text, $x, $y, $w = 420, $bold = $false) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, 22)
    if ($bold) { $l.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold) }
    $form.Controls.Add($l); return $l
}
function New-Button($text, $x, $y, $w, $onClick) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, 30)
    $b.Add_Click($onClick); $form.Controls.Add($b); return $b
}

# Lampa
New-Label "Lampa (веб-сервер Caddy, порт $($cfg.lampaPort))" 15 12 420 $true | Out-Null
$lblLampa = New-Label '...' 15 36
$lblSvc   = New-Label '...' 15 58
New-Button 'Запустить'     15  85 135 { Invoke-Elevated 'Lampa' 'Start' } | Out-Null
New-Button 'Остановить'   160  85 135 { Invoke-Elevated 'Lampa' 'Stop' } | Out-Null
New-Button 'Перезапустить' 305 85 135 { Invoke-Elevated 'Lampa' 'Restart' } | Out-Null
New-Button 'Открыть Lampa'   15 120 135 { Start-Process $LampaUrl } | Out-Null
New-Button 'Папка сайта'    160 120 135 { Start-Process explorer.exe $Site } | Out-Null
New-Button 'Адрес для MSX' 305 120 135 {
    [Windows.Forms.Clipboard]::SetText($MsxUrl)
    [Windows.Forms.MessageBox]::Show("Скопировано:`n$MsxUrl`n`nВ MSX на телевизоре: Settings -> Start Parameter.", 'Lampa сервер') | Out-Null
} | Out-Null

# TorrServer
New-Label "TorrServer (порт $($cfg.torrPort))" 15 172 420 $true | Out-Null
$lblTorr = New-Label '...' 15 196
New-Button 'Запустить'     15 223 135 { Invoke-Elevated 'Torr' 'Start' } | Out-Null
New-Button 'Остановить'   160 223 135 { Invoke-Elevated 'Torr' 'Stop' } | Out-Null
New-Button 'Перезапустить' 305 223 135 { Invoke-Elevated 'Torr' 'Restart' } | Out-Null
New-Button 'Открыть TorrServer' 15 258 205 { Start-Process $TorrUrl } | Out-Null
New-Button 'Папка TorrServer'  235 258 205 { Start-Process explorer.exe $TorrDir } | Out-Null

# Парсер
New-Label 'Парсер торрентов (Jackett)' 15 310 420 $true | Out-Null
$lblParser = New-Label '...' 15 334
New-Button 'Проверить'       15 361 135 { Start-ParserCheck } | Out-Null
New-Button 'Сменить парсер…' 160 361 135 {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $v = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Адрес Jackett-парсера для Lampa.`nПо умолчанию: https://jr.maxvol.pro`nПосле смены нажмите «Проверить»: статус покажет, отвечает ли новый адрес.", 'Сменить парсер', $script:Jackett)
    $v = $v.Trim().TrimEnd('/')
    if (-not $v -or $v -eq $script:Jackett) { return }
    if ($v -notmatch '^https?://') { $v = 'http://' + $v }
    try {
        $c = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $c | Add-Member -NotePropertyName jackettUrl -NotePropertyValue $v -Force
        [IO.File]::WriteAllText($cfgPath, ($c | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
        $script:Jackett = $v
        Write-TvServerJs $Site $IP $cfg.torrPort $v ((Get-TvServerJsVersion $Site) + 1)
        Start-ParserCheck
        [Windows.Forms.MessageBox]::Show("Парсер: $v`n`nНа телевизоре закройте и снова откройте MSX — Lampa возьмёт новый адрес.", 'Lampa сервер') | Out-Null
    } catch { [Windows.Forms.MessageBox]::Show("Не получилось: $_", 'Lampa сервер', 'OK', 'Warning') | Out-Null }
} | Out-Null
New-Button 'Обновить на ТВ' 305 361 135 {
    try {
        Write-TvServerJs $Site $IP $cfg.torrPort $script:Jackett ((Get-TvServerJsVersion $Site) + 1)
        [Windows.Forms.MessageBox]::Show("При следующем запуске MSX на телевизоре Lampa заново пропишет:`n• TorrServer: $TorrUrl`n• парсер: $($script:Jackett)`n`nЗакройте и снова откройте MSX на ТВ.", 'Lampa сервер') | Out-Null
    } catch { [Windows.Forms.MessageBox]::Show("Не получилось: $_", 'Lampa сервер', 'OK', 'Warning') | Out-Null }
} | Out-Null

# Общее
New-Label 'Адреса в локальной сети' 15 410 420 $true | Out-Null
New-Label "Lampa:  $LampaUrl" 15 434 | Out-Null
New-Label "MSX:    $MsxUrl" 15 456 | Out-Null
New-Button 'Обновить статус' 15 485 205 { Update-Status; Start-ParserCheck } | Out-Null
$lblTime = New-Label '' 235 491 205

function Set-State($label, [bool]$ok, [string]$text) {
    $label.Text = $text
    $label.ForeColor = if ($ok) { [Drawing.Color]::ForestGreen } else { [Drawing.Color]::Firebrick }
}

function Update-Status {
    $form.Cursor = 'WaitCursor'
    $r = Test-Http $MsxUrl
    if ($r.ok) { Set-State $lblLampa $true  "● Работает — $LampaUrl" }
    else       { Set-State $lblLampa $false '● Не отвечает' }
    $lblSvc.Text = Get-ServiceText

    $t = Test-Http "${TorrUrl}echo"
    if ($t.ok) { Set-State $lblTorr $true  ("● Работает — версия " + $t.body.Trim()) }
    else       { Set-State $lblTorr $false '● Не отвечает' }
    $lblTime.Text = 'Проверено: ' + (Get-Date -Format 'HH:mm:ss')
    $form.Cursor = 'Default'
}

function Start-ParserCheck {
    if ($script:pTask -and -not $script:pTask.IsCompleted) { return }
    $url = $script:Jackett.TrimEnd('/') + '/api/v2.0/indexers/all/results?apikey=&Query=' + [uri]::EscapeDataString('Матрица')
    $lblParser.Text = "● Проверка… — $($script:Jackett)"
    $lblParser.ForeColor = [Drawing.Color]::DimGray
    $script:pSw = [Diagnostics.Stopwatch]::StartNew()
    $script:pTask = $script:http.GetStringAsync($url)
}

function Update-ParserResult {
    if (-not $script:pTask -or -not $script:pTask.IsCompleted) { return }
    $sec = '{0:N1}' -f $script:pSw.Elapsed.TotalSeconds
    if ($script:pTask.Status -eq 'RanToCompletion') {
        $n = $null
        try { $n = @(($script:pTask.Result | ConvertFrom-Json).Results).Count } catch {}
        if ($null -ne $n) { Set-State $lblParser $true "● Отвечает: $n раздач за $sec с — $($script:Jackett)" }
        else              { Set-State $lblParser $false "● Ответ не похож на Jackett — $($script:Jackett)" }
    } else {
        Set-State $lblParser $false "● Не отвечает ($sec с) — $($script:Jackett)"
    }
    $script:pTask = $null
}

$timer = New-Object Windows.Forms.Timer          # статус Lampa/TorrServer каждые 10 с, парсер каждые 2 мин
$timer.Interval = 10000
$timer.Add_Tick({
    Update-Status
    $script:pTicks++
    if ($script:pTicks -ge 12) { $script:pTicks = 0; Start-ParserCheck }
})
$pollTimer = New-Object Windows.Forms.Timer      # забирает результат асинхронной проверки парсера
$pollTimer.Interval = 500
$pollTimer.Add_Tick({ Update-ParserResult })
$form.Add_Shown({ Update-Status; Start-ParserCheck; $timer.Start(); $pollTimer.Start() })
$form.Add_FormClosed({ $timer.Stop(); $pollTimer.Stop(); $script:http.Dispose() })
[void]$form.ShowDialog()
