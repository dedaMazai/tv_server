# Общие функции для install.ps1 / uninstall.ps1 / torrserver\install-torrserver.ps1

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Перезапускает скрипт с правами администратора (окно UAC), передавая параметры, и ждёт его завершения.
function Invoke-SelfElevate([string]$ScriptPath, [hashtable]$Params) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")
    foreach ($k in $Params.Keys) {
        $v = $Params[$k]
        if ($null -eq $v -or "$v" -eq '') { continue }
        if ($v -is [switch] -or $v -is [bool]) { if ($v) { $a += "-$k" } }
        else { $a += "-$k"; $a += "`"$v`"" }
    }
    $a += '-Elevated'
    Write-Host 'Нужны права администратора: подтвердите окно UAC...'
    $p = Start-Process powershell -Verb RunAs -ArgumentList ($a -join ' ') -PassThru -Wait
    exit $p.ExitCode
}

# IPv4 этого ПК в локальной сети: интерфейс с основным шлюзом, частный диапазон, маска не /32 (отсекает VPN).
function Get-LanAddress([string]$Ip) {
    if ($Ip) {
        $a = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Ip -ErrorAction SilentlyContinue
        if (-not $a) { throw "Адрес $Ip не найден на этом ПК." }
        return [pscustomobject]@{ IP = $Ip; Prefix = [int]$a.PrefixLength; Alias = $a.InterfaceAlias }
    }
    $c = @(Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        ForEach-Object { $_.IPv4Address } |
        Where-Object { $_.PrefixLength -lt 32 -and $_.IPAddress -match '^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)' })
    if ($c.Count -eq 0) { throw 'Не удалось определить адрес в локальной сети. Укажите его вручную: -Ip 192.168.x.x' }
    if ($c.Count -gt 1) { throw ('Найдено несколько адресов: ' + (($c | ForEach-Object IPAddress) -join ', ') + '. Укажите нужный: -Ip ...') }
    return [pscustomobject]@{ IP = $c[0].IPAddress; Prefix = [int]$c[0].PrefixLength; Alias = $c[0].InterfaceAlias }
}

# "192.168.31.251", 24 -> "192.168.31.0/24"
function Get-Subnet([string]$Ip, [int]$Prefix) {
    $b = [Net.IPAddress]::Parse($Ip).GetAddressBytes(); [Array]::Reverse($b)
    $n = [BitConverter]::ToUInt32($b, 0)
    $mask = if ($Prefix -eq 0) { [uint32]0 } else { [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $Prefix)) }
    $nb = [BitConverter]::GetBytes([uint32]($n -band $mask)); [Array]::Reverse($nb)
    '{0}/{1}' -f ([Net.IPAddress]::new($nb)).ToString(), $Prefix
}

# HTTP GET без прокси (VPN/прокси не мешают проверке локальных адресов)
function Invoke-HttpGet([string]$Url, [int]$TimeoutMs = 3000) {
    try {
        $r = [Net.HttpWebRequest]::Create($Url); $r.Proxy = $null; $r.Timeout = $TimeoutMs
        $resp = $r.GetResponse(); $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        $o = [pscustomobject]@{ Ok = $true; Code = [int]$resp.StatusCode; Type = $resp.ContentType; Body = $sr.ReadToEnd() }
        $resp.Close(); return $o
    } catch {
        $code = $null; if ($_.Exception.InnerException.Response) { $code = [int]$_.Exception.InnerException.Response.StatusCode }
        return [pscustomobject]@{ Ok = $false; Code = $code; Type = $null; Body = $null }
    }
}

# Скачивание через PowerShell (curl.exe на некоторых ПК не может проверить отзыв сертификата при VPN)
function Get-File([string]$Url, [string]$OutFile) {
    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile } finally { $ProgressPreference = $old }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

function Step([string]$m) { Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "   OK  $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "   !!  $m" -ForegroundColor Yellow }
