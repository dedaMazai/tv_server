<#
.SYNOPSIS
  Ставит локальный веб-сервер с Lampa для Media Station X (MSX) на телевизоре.
  Подробности: README.md

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Ip 192.168.1.50 -Port 8095
#>
param(
    [string]$Ip,                                                     # адрес ПК в локальной сети (по умолчанию определяется сам)
    [int]$Port = 8095,                                               # порт веб-сервера Lampa
    [int]$TorrPort = 8090,                                           # порт TorrServer (только для проверки и панели)
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'LampaWeb'),   # site\ и panel\
    [string]$CaddyDir = (Join-Path $env:USERPROFILE 'Caddy'),        # caddy.exe и Caddyfile
    [string]$TorrDir = (Join-Path $env:USERPROFILE 'TorrServer'),    # где лежит TorrServer (для панели)
    [string]$ServiceName = 'LampaWeb',
    [string]$LampaUrl = 'https://github.com/yumata/lampa/releases/download/v1.4.1/lampa_v3.1.7.ipk',
    [string]$LampaSha256 = 'a85a0f009cb64b71b56f72cb82aa6e5c31a5efb60c2556bbe9eca778c0773c3c',
    [string]$JackettUrl = 'https://jr.maxvol.pro',                   # парсер торрентов для Lampa ('' = не прописывать парсер)
    [string]$LampaIpk,        # готовый .ipk вместо скачивания (SHA-256 всё равно сверяется)
    [string]$CaddyZip,        # готовый caddy_*_windows_amd64.zip вместо скачивания
    [string]$CaddyChecksums,  # и его caddy_*_checksums.txt
    [switch]$FilesOnly,       # только файлы, без службы/брандмауэра/ярлыка (права админа не нужны; для проверки)
    [switch]$Elevated         # служебный: скрипт уже перезапущен с правами администратора
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if (-not $FilesOnly -and -not (Test-Admin)) {
    Invoke-SelfElevate $PSCommandPath @{
        Ip = $Ip; Port = $Port; TorrPort = $TorrPort; InstallDir = $InstallDir; CaddyDir = $CaddyDir; TorrDir = $TorrDir
        ServiceName = $ServiceName; LampaUrl = $LampaUrl; LampaSha256 = $LampaSha256; JackettUrl = $JackettUrl
        LampaIpk = $LampaIpk; CaddyZip = $CaddyZip; CaddyChecksums = $CaddyChecksums
    }
}

$SiteDir  = Join-Path $InstallDir 'site'
$PanelDir = Join-Path $InstallDir 'panel'
$CaddyExe = Join-Path $CaddyDir 'caddy.exe'
$tmp = Join-Path $env:TEMP ('tv_server_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$exitCode = 0

try {
    # ---------------------------------------------------------------- 0. Сеть и порт
    Step 'Сеть'
    $lan = Get-LanAddress $Ip
    $Ip = $lan.IP
    $Subnet = Get-Subnet $lan.IP $lan.Prefix
    Ok "Адрес ПК: $Ip ($($lan.Alias)), локальная сеть: $Subnet"
    $prof = Get-NetConnectionProfile -InterfaceAlias $lan.Alias -ErrorAction SilentlyContinue
    if ($prof) { Ok "Профиль сети: $($prof.NetworkCategory) (правило брандмауэра будет для всех профилей, но только для $Subnet)" }

    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and -not $FilesOnly -and $svc.Status -ne 'Stopped') {
        Stop-Service $ServiceName; Ok "Служба $ServiceName остановлена для обновления"
    }
    $busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($busy) {
        $pn = (Get-Process -Id $busy[0].OwningProcess -ErrorAction SilentlyContinue).ProcessName
        throw "Порт $Port занят (процесс: $pn). Выберите другой: -Port 8096"
    }
    Ok "Порт $Port свободен"

    New-Item -ItemType Directory -Force $tmp | Out-Null

    # ---------------------------------------------------------------- 1. Lampa
    Step 'Lampa: скачивание и проверка'
    if ($LampaIpk) { $ipk = (Resolve-Path $LampaIpk).Path; Ok "Локальный файл: $ipk" }
    else { $ipk = Join-Path $tmp 'lampa.ipk'; Get-File $LampaUrl $ipk; Ok "Скачан $LampaUrl" }
    $h = (Get-FileHash $ipk -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $LampaSha256.ToLower()) { throw "SHA-256 Lampa не совпадает: $h (ожидалось $LampaSha256). Остановлено." }
    Ok "SHA-256 совпадает: $h"

    Step 'Lampa: распаковка'
    $x = Join-Path $tmp 'lampa'; New-Item -ItemType Directory -Force $x | Out-Null
    & tar.exe -xf $ipk -C $x;                         if ($LASTEXITCODE) { throw 'tar: не удалось распаковать .ipk' }
    & tar.exe -xzf (Join-Path $x 'data.tar.gz') -C $x; if ($LASTEXITCODE) { throw 'tar: не удалось распаковать data.tar.gz' }
    $app = Join-Path $x 'usr\palm\applications\lampa.tv'
    if (-not (Test-Path (Join-Path $app 'index.html'))) { throw 'В пакете нет usr\palm\applications\lampa.tv\index.html' }
    New-Item -ItemType Directory -Force $SiteDir | Out-Null
    Copy-Item (Join-Path $app '*') $SiteDir -Recurse -Force
    Ok ("Скопировано в $SiteDir (" + (Get-ChildItem $SiteDir -Recurse -File).Count + ' файлов)')

    Step 'Lampa: включение торрентов (torrents_use: true)'
    $index = Join-Path $SiteDir 'index.html'
    $enc = [Text.Encoding]::GetEncoding(28591)   # побайтово, чтобы не изменить кодировку и переводы строк
    $t = $enc.GetString([IO.File]::ReadAllBytes($index))
    $nFalse = ([regex]::Matches($t, [regex]::Escape('torrents_use: false,'))).Count
    $nTrue  = ([regex]::Matches($t, [regex]::Escape('torrents_use: true,'))).Count
    if ($nFalse -eq 1) {
        [IO.File]::WriteAllBytes($index, $enc.GetBytes($t.Replace('torrents_use: false,', 'torrents_use: true,')))
        Ok 'Заменено ровно одно вхождение'
    } elseif ($nFalse -eq 0 -and $nTrue -eq 1) { Ok 'Уже включено' }
    else { throw "Неожиданное содержимое index.html: 'false' x$nFalse, 'true' x$nTrue" }

    Step 'MSX: start.json'
    New-Item -ItemType Directory -Force (Join-Path $SiteDir 'msx') | Out-Null
    $json = "{`n        `"name`": `"Lampa`",`n        `"version`": `"local`",`n        `"parameter`": `"content:http://${Ip}:$Port/msx/start.json`",`n        `"action`": `"link:http://${Ip}:$Port/`"`n}`n"
    Write-Utf8NoBom (Join-Path $SiteDir 'msx\start.json') $json
    $null = $json | ConvertFrom-Json
    Ok "http://${Ip}:$Port/msx/start.json"

    Step 'Lampa: настройки по умолчанию (tvserver.js)'
    # Один раз на каждом устройстве прописывает адрес TorrServer и парсер; дальше настройки Lampa не трогает.
    # Версия увеличивается при каждой установке, чтобы новые адрес/порт/парсер применились на ТВ.
    . (Join-Path $PSScriptRoot 'panel\TvDefaults.ps1')
    $jsVer = (Get-TvServerJsVersion $SiteDir) + 1
    Write-TvServerJs $SiteDir $Ip $TorrPort $JackettUrl $jsVer
    Add-TvServerJsTag $SiteDir
    Ok ("TorrServer: http://${Ip}:$TorrPort" + $(if ($JackettUrl) { "; парсер Jackett: $JackettUrl" } else { '; парсер не прописан' }))

    # ---------------------------------------------------------------- 2. Caddy
    Step 'Caddy: скачивание и проверка'
    if ($CaddyZip -and $CaddyChecksums) {
        $zip = (Resolve-Path $CaddyZip).Path; $sums = (Resolve-Path $CaddyChecksums).Path; Ok "Локальные файлы: $zip"
    } else {
        $rel = Invoke-RestMethod 'https://api.github.com/repos/caddyserver/caddy/releases/latest'
        $za = $rel.assets | Where-Object { $_.name -match '^caddy_.+_windows_amd64\.zip$' } | Select-Object -First 1
        $sa = $rel.assets | Where-Object { $_.name -match '_checksums\.txt$' } | Select-Object -First 1
        if (-not $za -or -not $sa) { throw "В релизе Caddy $($rel.tag_name) нет windows_amd64.zip или checksums" }
        $zip = Join-Path $tmp $za.name; $sums = Join-Path $tmp $sa.name
        Get-File $sa.browser_download_url $sums; Get-File $za.browser_download_url $zip
        Ok "Скачан Caddy $($rel.tag_name)"
    }
    $zipName = Split-Path $zip -Leaf
    $line = Get-Content $sums | Where-Object { $_ -match ('\s' + [regex]::Escape($zipName) + '$') } | Select-Object -First 1
    if (-not $line) { throw "В checksums нет строки для $zipName" }
    $expected = ($line -split '\s+')[0].ToLower()
    $algo = switch ($expected.Length) { 128 { 'SHA512' } 64 { 'SHA256' } default { throw "Непонятный формат checksums: $line" } }
    $actual = (Get-FileHash $zip -Algorithm $algo).Hash.ToLower()
    if ($actual -ne $expected) { throw "$algo Caddy не совпадает с checksums. Остановлено." }
    Ok "$algo совпадает с checksums"

    Step 'Caddy: установка'
    $cx = Join-Path $tmp 'caddy'; Expand-Archive $zip -DestinationPath $cx -Force
    New-Item -ItemType Directory -Force $CaddyDir | Out-Null
    Copy-Item (Join-Path $cx 'caddy.exe') $CaddyExe -Force
    Ok ((& $CaddyExe version) + " -> $CaddyExe")
    $caddyfile = Join-Path $CaddyDir 'Caddyfile'
    $root = $SiteDir.Replace('\', '/')
    # no-cache для index.html / tvserver.js / msx: ТВ всегда получает свежие настройки (ETag, без лишней загрузки)
    Write-Utf8NoBom $caddyfile ("# Lampa for MSX: static file server, no directory listing (generated by install.ps1)`n{`n`tadmin off`n}`n`n" +
        "http://:$Port {`n`troot * `"$root`"`n`t@fresh path / /index.html /tvserver.js /msx/*`n`theader @fresh Cache-Control `"no-cache`"`n`tfile_server`n}`n")
    # caddy пишет обычные логи в stderr; в PS 5.1 при 'Stop' это стало бы ошибкой, поэтому смотрим только код выхода
    $ErrorActionPreference = 'Continue'
    $v = & $CaddyExe validate --config $caddyfile --adapter caddyfile 2>&1 | ForEach-Object { "$_" }
    $vc = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($vc) { throw "Caddyfile не прошёл проверку: $($v | Select-Object -Last 3)" }
    Ok "Caddyfile: $caddyfile"

    # ---------------------------------------------------------------- 3. Панель
    Step 'Панель управления'
    New-Item -ItemType Directory -Force $PanelDir | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'panel\LampaPanel.ps1'), (Join-Path $PSScriptRoot 'panel\ServiceAction.ps1'), (Join-Path $PSScriptRoot 'panel\TvDefaults.ps1') $PanelDir -Force
    $cfg = [ordered]@{ ip = $Ip; lampaPort = $Port; torrPort = $TorrPort; serviceName = $ServiceName; siteDir = $SiteDir; torrDir = $TorrDir; jackettUrl = $JackettUrl }
    Write-Utf8NoBom (Join-Path $PanelDir 'config.json') ($cfg | ConvertTo-Json)
    # иконка из логотипа Lampa (ICO с PNG внутри)
    Add-Type -AssemblyName System.Drawing
    $img = [Drawing.Image]::FromFile((Join-Path $SiteDir 'icon_large.png'))
    $bmp = New-Object Drawing.Bitmap 128, 128; $g = [Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($img, 0, 0, 128, 128); $g.Dispose(); $img.Dispose()
    $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $png = $ms.ToArray()
    $bw = New-Object IO.BinaryWriter([IO.File]::Create((Join-Path $PanelDir 'lampa.ico')))
    $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1); $bw.Write([byte]128); $bw.Write([byte]128)
    $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$png.Length); $bw.Write([UInt32]22); $bw.Write($png); $bw.Close()
    Ok "Панель: $PanelDir"

    if ($FilesOnly) {
        Warn 'Режим -FilesOnly: служба, брандмауэр и ярлык пропущены'
    } else {
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lampa сервер.lnk'
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $s.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PanelDir\LampaPanel.ps1`""
        $s.WorkingDirectory = $PanelDir; $s.IconLocation = "$PanelDir\lampa.ico,0"
        $s.Description = 'Панель управления сервером Lampa для ТВ'; $s.Save()
        Ok "Ярлык: $lnk"

        # ------------------------------------------------------------ 4. Служба Windows
        Step "Служба $ServiceName"
        $bin = "`"$CaddyExe`" run --config `"$caddyfile`" --adapter caddyfile"
        if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
            $rc = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" |
                Invoke-CimMethod -MethodName Change -Arguments @{ PathName = $bin; StartMode = 'Automatic' }).ReturnValue
            if ($rc) { throw "Не удалось обновить службу (код $rc)" }
            Ok 'Уже была: конфигурация обновлена'
        } else {
            # New-Service, а не sc.exe: корректно передаёт пути с пробелами (LocalSystem по умолчанию)
            New-Service -Name $ServiceName -BinaryPathName $bin -DisplayName "$ServiceName (Caddy, Lampa for MSX)" -StartupType Automatic | Out-Null
            Ok 'Создана: автозапуск при старте Windows, от LocalSystem'
        }
        & sc.exe description $ServiceName "Caddy :$Port - Lampa web для Media Station X. Root: $SiteDir" | Out-Null
        & sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
        & sc.exe failureflag $ServiceName 1 | Out-Null
        Ok 'При сбое: перезапуск через 60 с'
        Start-Service $ServiceName; Start-Sleep 3
        if ((Get-Service $ServiceName).Status -ne 'Running') { throw 'Служба не запустилась' }
        Ok 'Запущена'

        # ------------------------------------------------------------ 5. Брандмауэр
        Step 'Брандмауэр'
        $ruleName = "$ServiceName Caddy TCP $Port"
        Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Program $CaddyExe `
            -Protocol TCP -LocalPort $Port -Profile Any -RemoteAddress $Subnet | Out-Null
        Ok "Входящие на TCP $Port для caddy.exe, только из $Subnet"

        # ------------------------------------------------------------ 6. Проверка
        Step "Проверка по адресу $Ip"
        $r = Invoke-HttpGet "http://${Ip}:$Port/"
        if ($r.Ok -and $r.Body.Contains('torrents_use: true')) { Ok "/ -> $($r.Code), torrents_use: true" } else { Warn "/ -> $($r.Code)"; $exitCode = 1 }
        $r = Invoke-HttpGet "http://${Ip}:$Port/loader.js"
        if ($r.Ok) { Ok "/loader.js -> $($r.Code)" } else { Warn "/loader.js -> $($r.Code)"; $exitCode = 1 }
        $r = Invoke-HttpGet "http://${Ip}:$Port/msx/start.json"
        if ($r.Ok -and $r.Type -like 'application/json*') { $null = $r.Body | ConvertFrom-Json; Ok "/msx/start.json -> $($r.Code), $($r.Type)" } else { Warn "/msx/start.json -> $($r.Code) $($r.Type)"; $exitCode = 1 }
        $r = Invoke-HttpGet "http://${Ip}:$TorrPort/echo"
        if ($r.Ok) { Ok "TorrServer -> $($r.Body.Trim())" } else { Warn "TorrServer на порту $TorrPort не отвечает (его ставят отдельно, см. README)" }
    }

    Write-Host ''
    Write-Host 'ГОТОВО.' -ForegroundColor Green
    Write-Host "  На телевизоре в MSX: Settings -> Start Parameter -> http://${Ip}:$Port/msx/start.json"
    Write-Host "  В Lampa: Настройки -> TorrServer -> http://${Ip}:$TorrPort"
    Write-Host '  Совет: закрепите этот IP за ПК в роутере (DHCP reservation).'
} catch {
    Write-Host ''
    Write-Host "ОШИБКА: $_" -ForegroundColor Red
    $exitCode = 1
} finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($Elevated) { Write-Host ''; Read-Host 'Нажмите Enter, чтобы закрыть окно' | Out-Null }
exit $exitCode
