# reconnect.ps1 - 立即重连（X-file）
# 写 reconnect.flag，监控进程会在 10 秒内发现并立刻登录；若监控未运行则直接拉起它。
$ErrorActionPreference = "SilentlyContinue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # X-file\scripts
$rootDir   = Split-Path -Parent $scriptDir                     # X-file 根目录
$binDir    = Join-Path $rootDir "bin"        # 登录程序与其配置（必须同目录）
$configDir = Join-Path $rootDir "config"     # 监控设置与运行标志
$logDir    = Join-Path $rootDir "logs"       # 日志
$shotDir   = Join-Path $rootDir "shots"      # 截图

$flag  = Join-Path $configDir "reconnect.flag"
$mon   = Join-Path $scriptDir "monitor.ps1"

$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*monitor.ps1*" })

if ($procs.Count -ge 1) {
    Set-Content -Path $flag -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8
    Write-Host "已发送重连请求，监控将在 10 秒内响应（结果见 monitor.log）。" -ForegroundColor Green
} else {
    Write-Host "监控进程未运行，正在启动..." -ForegroundColor Yellow
    if (Test-Path $mon) {
        Start-Process -FilePath "powershell.exe" -ArgumentList @("-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$mon`"") -WorkingDirectory $rootDir | Out-Null
        Start-Sleep -Seconds 2
        Write-Host "监控已启动，它会立即开始检测并在需要时登录。" -ForegroundColor Green
    } else {
        Write-Host "[失败] 未找到 monitor.ps1" -ForegroundColor Red
    }
}
Write-Host ""
