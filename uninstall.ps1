<#
.SYNOPSIS
  Удаляет то, что поставил install.ps1: службу, правило брандмауэра, ярлык.
  Файлы (сайт, caddy.exe, панель) остаются, если не указать -RemoveFiles. TorrServer не трогается.
#>
param(
    [int]$Port = 8095,
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'LampaWeb'),
    [string]$CaddyDir = (Join-Path $env:USERPROFILE 'Caddy'),
    [string]$ServiceName = 'LampaWeb',
    [switch]$RemoveFiles,
    [switch]$Elevated
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
if (-not (Test-Admin)) {
    Invoke-SelfElevate $PSCommandPath @{ Port = $Port; InstallDir = $InstallDir; CaddyDir = $CaddyDir; ServiceName = $ServiceName; RemoveFiles = $RemoveFiles }
}

$exitCode = 0
try {
    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
        Stop-Service $ServiceName -ErrorAction SilentlyContinue
        & sc.exe delete $ServiceName | Out-Null
        Ok "Служба $ServiceName удалена"
    } else { Ok "Службы $ServiceName нет" }

    Get-NetFirewallRule -DisplayName "$ServiceName Caddy TCP $Port" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Ok 'Правило брандмауэра удалено'

    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lampa сервер.lnk'
    if (Test-Path $lnk) { Remove-Item $lnk; Ok 'Ярлык удалён' }

    if ($RemoveFiles) {
        foreach ($d in $InstallDir, $CaddyDir) { if (Test-Path $d) { Remove-Item $d -Recurse -Force; Ok "Удалено: $d" } }
    } else { Ok "Файлы оставлены: $InstallDir, $CaddyDir" }
} catch {
    Write-Host "ОШИБКА: $_" -ForegroundColor Red; $exitCode = 1
}
if ($Elevated) { Write-Host ''; Read-Host 'Нажмите Enter, чтобы закрыть окно' | Out-Null }
exit $exitCode
