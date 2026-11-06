<#
.SYNOPSIS
  Необязательно. Настраивает автозапуск TorrServer: сторож run.ps1 + задание Планировщика при старте Windows
  (от SYSTEM) + правило брандмауэра только для локальной сети.

  Перед запуском положите TorrServer.exe в папку -TorrDir (по умолчанию %USERPROFILE%\TorrServer):
  https://github.com/YouROK/TorrServer/releases -> TorrServer-windows-amd64.exe, переименуйте в TorrServer.exe.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\torrserver\install-torrserver.ps1
#>
param(
    [string]$Ip,
    [int]$TorrPort = 8090,
    [string]$TorrDir = (Join-Path $env:USERPROFILE 'TorrServer'),
    [string]$TaskName = 'TorrServer',
    [switch]$Elevated
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\Common.ps1')

if (-not (Test-Admin)) {
    Invoke-SelfElevate $PSCommandPath @{ Ip = $Ip; TorrPort = $TorrPort; TorrDir = $TorrDir; TaskName = $TaskName }
}

$exitCode = 0
try {
    $exe = Join-Path $TorrDir 'TorrServer.exe'
    if (-not (Test-Path $exe)) { throw "Нет $exe. Скачайте TorrServer (см. README) и положите туда." }

    Step 'Сеть'
    $lan = Get-LanAddress $Ip
    $Subnet = Get-Subnet $lan.IP $lan.Prefix
    Ok "Адрес ПК: $($lan.IP), локальная сеть: $Subnet"

    Step 'Сторож run.ps1'
    $run = Join-Path $TorrDir 'run.ps1'
    $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'run.ps1'), [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($run, $src, (New-Object Text.UTF8Encoding $true))
    Ok $run

    Step "Задание Планировщика $TaskName"
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Warn "Задание $TaskName уже есть, не трогаю"
    } else {
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                       -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$run`"" -WorkingDirectory $TorrDir
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
                       -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description 'TorrServer watchdog (run.ps1)' | Out-Null
        Ok 'Создано: при старте Windows, от SYSTEM, без ограничения времени'
    }

    Step 'Брандмауэр'
    $ruleName = "TorrServer TCP $TorrPort"
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Program $exe `
        -Protocol TCP -LocalPort $TorrPort -Profile Any -RemoteAddress $Subnet | Out-Null
    Ok "Входящие на TCP $TorrPort для TorrServer.exe, только из $Subnet"

    Step 'Запуск и проверка'
    Start-ScheduledTask -TaskName $TaskName
    $ok = $false
    for ($i = 0; $i -lt 15; $i++) { Start-Sleep 2; if ((Invoke-HttpGet "http://$($lan.IP):$TorrPort/echo").Ok) { $ok = $true; break } }
    if ($ok) { Ok "TorrServer отвечает: http://$($lan.IP):$TorrPort/" } else { Warn "TorrServer не ответил за 30 с, см. $TorrDir\watchdog.log"; $exitCode = 1 }
} catch {
    Write-Host "ОШИБКА: $_" -ForegroundColor Red
    $exitCode = 1
}
if ($Elevated) { Write-Host ''; Read-Host 'Нажмите Enter, чтобы закрыть окно' | Out-Null }
exit $exitCode
