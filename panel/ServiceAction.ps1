# Вызывается панелью с правами администратора (UAC).
#   -Target Lampa : служба Lampa (Start / Stop / Restart)
#   -Target Torr  : TorrServer = задание Планировщика со сторожем <torrDir>\run.ps1 + TorrServer.exe
param(
    [ValidateSet('Lampa', 'Torr')][string]$Target = 'Lampa',
    [ValidateSet('Start', 'Stop', 'Restart')][string]$Action,
    [string]$ResultFile
)

$cfg = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Svc        = $cfg.serviceName
$RunPs1Re   = [regex]::Escape((Join-Path $cfg.torrDir 'run.ps1'))
$TorrExe    = Join-Path $cfg.torrDir 'TorrServer.exe'

function Get-TorrTask {
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match $RunPs1Re
    }
}
function Stop-Torr {
    Get-TorrTask | Where-Object State -eq 'Running' | Stop-ScheduledTask
    # сторож (powershell с run.ps1) и сам TorrServer.exe
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match $RunPs1Re } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-Process TorrServer -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $TorrExe } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}
function Start-Torr {
    $t = @(Get-TorrTask)
    if ($t.Count -eq 0) { throw "Не найдено задание Планировщика, которое запускает $($cfg.torrDir)\run.ps1 (см. torrserver\install-torrserver.ps1)." }
    $t | ForEach-Object { Start-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName }
}

$out = try {
    $ErrorActionPreference = 'Stop'
    if ($Target -eq 'Lampa') {
        if (-not (Get-Service $Svc -ErrorAction SilentlyContinue)) { throw "Служба $Svc не найдена." }
        switch ($Action) {
            'Start'   { Start-Service $Svc }
            'Stop'    { Stop-Service $Svc }
            'Restart' { Restart-Service $Svc }
        }
    } else {
        switch ($Action) {
            'Start'   { Start-Torr }
            'Stop'    { Stop-Torr }
            'Restart' { Stop-Torr; Start-Sleep 2; Start-Torr }
        }
    }
    'OK'
} catch { $_.Exception.Message }
Set-Content -Path $ResultFile -Value $out -Encoding UTF8
