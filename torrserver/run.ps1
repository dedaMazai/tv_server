# TorrServer watchdog: держит TorrServer.exe запущенным, перезапускает его через 60 с после выхода.
# Лежит в одной папке с TorrServer.exe; запускается заданием Планировщика (см. install-torrserver.ps1).
$dir = $PSScriptRoot
$exe = Join-Path $dir 'TorrServer.exe'
$log = Join-Path $dir 'watchdog.log'

function Write-Log($msg) {
    try { Add-Content -Path $log -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

while ($true) {
    $p = Get-Process -Name TorrServer -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) {
        try {
            $p = Start-Process -FilePath $exe -ArgumentList '-d', "`"$dir`"" -WorkingDirectory $dir -WindowStyle Hidden -PassThru
            Write-Log "started PID $($p.Id)"
        } catch {
            Write-Log "start failed: $_"
            Start-Sleep -Seconds 60
            continue
        }
    } else {
        Write-Log "attached to running PID $($p.Id)"
    }
    $p.WaitForExit()
    Write-Log "TorrServer exited (code $($p.ExitCode)); restarting in 60 s"
    Start-Sleep -Seconds 60
}
