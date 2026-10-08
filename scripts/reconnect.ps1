# reconnect.ps1 - 立即重连（X-file）
#
# [v2.9.4] 无论监控是否在运行，都【先写 reconnect.flag】再判定。
#   旧写法是先判定监控在不在跑、只在"在跑"时才写标志文件。判定读的是
#   Win32_Process.CommandLine，监控若以更高权限（计划任务最高权限）运行，
#   普通权限进程读不到它的 CommandLine，就会被误判成"未运行"：
#   于是既不写标志、又去启动一个会被单实例锁立刻挡回来的新进程 ——
#   表现出来就是「点了 立即重连.bat，什么也没发生」。
#   现在改成：先落标志（请求绝不丢失），再用【心跳 + 进程】双重判定决定要不要顺手拉起监控。
$ErrorActionPreference = "SilentlyContinue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # X-file\scripts
$rootDir   = Split-Path -Parent $scriptDir                     # X-file 根目录
$binDir    = Join-Path $rootDir "bin"        # 登录程序与其配置（必须同目录）
$configDir = Join-Path $rootDir "config"     # 监控设置与运行标志
$logDir    = Join-Path $rootDir "logs"       # 日志
$shotDir   = Join-Path $rootDir "shots"      # 截图

$flag = Join-Path $configDir "reconnect.flag"
$hb   = Join-Path $configDir "monitor_heartbeat.json"
$mon  = Join-Path $scriptDir "monitor.ps1"

# 1) 无条件落标志：这是"现在就用最新配置试一次"的唯一凭据，绝不能因为判定失误而丢掉
if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
Set-Content -LiteralPath $flag -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8

# 2) 判定监控是否在运行：心跳优先（不受权限影响），进程表兜底
$running = $false
if (Test-Path $hb) {
    try {
        $j = Get-Content -LiteralPath $hb -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.ts) {
            $age = ((Get-Date) - [datetime]$j.ts).TotalSeconds
            if ($age -ge 0 -and $age -le 300) { $running = $true }
        }
    } catch {}
}
if (-not $running) {
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
                   Where-Object { $_.CommandLine -like "*monitor.ps1*" })
        if ($procs.Count -ge 1) { $running = $true }
    } catch { $running = $false }
}

if ($running) {
    Write-Host "已发送重连请求，监控将在 10 秒内响应（结果见 logs\monitor.log）。" -ForegroundColor Green
} else {
    # 没在跑（或判定不了）：拉起监控。就算其实是在跑，新实例也会被单实例锁挡回，无害；
    # 而标志文件已经落好，无论谁在跑都会在 10 秒内消费它。
    Write-Host "监控进程未运行，正在启动..." -ForegroundColor Yellow
    if (Test-Path $mon) {
        Start-Process -FilePath "powershell.exe" -ArgumentList @("-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$mon`"") -WorkingDirectory $rootDir | Out-Null
        Start-Sleep -Seconds 2
        Write-Host "监控已启动，它会立刻读取重连请求并用最新配置登录。" -ForegroundColor Green
    } else {
        Write-Host "[失败] 未找到 monitor.ps1" -ForegroundColor Red
    }
}
Write-Host ""
