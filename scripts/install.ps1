# install.ps1 - 注册校园网守护任务计划（X-file）v2.0
#   Xfile_CampusNetGuard : 登录时运行(At logon, 当前用户) -> 后台保活 + 自动登录
# 需要管理员权限。用 Register-ScheduledTask，不依赖 schtasks，免密码交互。
#
# v2.0 改动：
#   [修复] 提权后的窗口用 -NoExit 保持打开，安装结果不再一闪而过
#   [新增] 提权前在原窗口给出明确提示，避免误判为安装失败
#   [新增] 显式设置 MultipleInstances=IgnoreNew 与失败自动重启
#   [新增] 安装后校验任务路径与当前文件夹是否一致

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # X-file\scripts
$rootDir   = Split-Path -Parent $scriptDir                     # X-file 根目录
$binDir    = Join-Path $rootDir "bin"        # 登录程序与其配置（必须同目录）
$configDir = Join-Path $rootDir "config"     # 监控设置与运行标志
$logDir    = Join-Path $rootDir "logs"       # 日志
$shotDir   = Join-Path $rootDir "shots"      # 截图

$mon = Join-Path $scriptDir "monitor.ps1"

# 管理员自检 + 自动提权
$id    = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
# 监控本身不需要管理员权限，只有注册 RunLevel=Highest 的任务才需要。
# 提权被取消时退回到 Limited 注册，避免双击安装却因 UAC 取消而完全失败。
$runLevel = "Highest"
if (-not $admin) {
    Write-Host ""
    Write-Host "  正在请求提权，请在弹出的 UAC 窗口中点击「是」。" -ForegroundColor Yellow
    Write-Host "  安装结果会显示在那个新打开的窗口里，请在其中查看。" -ForegroundColor Yellow
    Write-Host ""
    try {
        Start-Process powershell -Verb RunAs -ArgumentList (
            "-ExecutionPolicy Bypass -NoExit -File `"" + $PSCommandPath + "`"") -ErrorAction Stop
        exit
    } catch {
        Write-Host "  提权未成功，改为以当前用户权限注册（不会弹 UAC）。" -ForegroundColor Yellow
        $runLevel = "Limited"
    }
}

if (-not (Test-Path $mon)) {
    Write-Host "[失败] 未找到 monitor.ps1" -ForegroundColor Red
    exit 1
}
$exe = Join-Path $binDir "CampusNetLogin.exe"
$cfg = Join-Path $binDir "campus_net_config.json"
if (-not (Test-Path $exe)) { Write-Host ("[警告] 未找到登录程序: " + $exe) -ForegroundColor Yellow }
if (-not (Test-Path $cfg)) { Write-Host ("[警告] 未找到配置文件: " + $cfg) -ForegroundColor Yellow }

$psArgs = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"" + $mon + "`""

# ExecutionTimeLimit 设为 0（无限制），否则默认上限会杀掉永久循环的监控
$setting = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0) -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 10)

Write-Host "正在注册 Xfile_CampusNetGuard (登录时运行) ..."
$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs -WorkingDirectory $rootDir
$trigger   = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel $runLevel
try {
    Register-ScheduledTask -TaskName "Xfile_CampusNetGuard" -Action $action -Trigger $trigger -Principal $principal -Settings $setting -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Host ""
    Write-Host ("[失败] 注册计划任务出错: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host "  常见原因：当前账户无权创建任务。请右键 安装.bat 选择「以管理员身份运行」。" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# 先停任务：任务仍标记为 Running 时，后面的 Start-ScheduledTask 会被 MultipleInstances=IgnoreNew 忽略
Stop-ScheduledTask -TaskName "Xfile_CampusNetGuard" -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Seconds 1

# 清理可能卡住的旧监控实例：
#   通道1 心跳文件记录的 PID（最可靠，提权/隐藏进程也能定位）
#   通道2 命令行扫描（PS5.1 的 Get-Process 无 CommandLine 属性，必须用 CIM）
# 提权进程的命令行常常读不到，所以两条路都要走；结束后删除心跳，避免新实例被陈旧心跳挡住。
$hbFile  = Join-Path $configDir "monitor_heartbeat.json"
$stopped = @()
if (Test-Path $hbFile) {
    try {
        $hb = (Get-Content -LiteralPath $hbFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
        if ($hb -and $hb.pid) {
            try { Stop-Process -Id ([int]$hb.pid) -Force -ErrorAction Stop; $stopped += ("PID=" + $hb.pid + "(心跳)") } catch {}
        }
    } catch {}
    try { [System.IO.File]::Delete($hbFile) } catch {}
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*monitor.ps1*"
} | ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $stopped += ("PID=" + $_.ProcessId) } catch {}
}
if ($stopped.Count -gt 0) { Write-Host ("  已结束旧监控实例: " + ($stopped -join ", ")) -ForegroundColor Yellow }
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName "Xfile_CampusNetGuard" -ErrorAction SilentlyContinue | Out-Null

# ---- 安装结果校验 ----
Write-Host ""
Write-Host "===== 安装结果校验 ====="
$t = Get-ScheduledTask -TaskName "Xfile_CampusNetGuard" -ErrorAction SilentlyContinue
if ($t) {
    Write-Host ("  [成功] Xfile_CampusNetGuard 已注册 (状态=" + $t.State + ", 身份=" + $t.Principal.UserId + ")") -ForegroundColor Green
    Write-Host ("  监控脚本: " + $mon)
    Start-Sleep -Seconds 3
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*monitor.ps1*" })
    if ($procs.Count -ge 1) { Write-Host ("  监控已启动，进程数=" + $procs.Count) -ForegroundColor Green }
    else { Write-Host "  监控进程暂未启动，可稍后运行 检查状态.bat 复核" -ForegroundColor Yellow }
} else {
    Write-Host "  [失败] 未注册 <-- 请右键 安装.bat 选择「以管理员身份运行」" -ForegroundColor Red
}
Write-Host ""
Write-Host "  说明："
Write-Host "  - 后台时段（默认 7:00-23:00）静默运行；网络与会话均正常时会跳过无谓的重登。"
Write-Host "  - 失败换红色壁纸并弹通知；恢复后自动还原你原本的壁纸并清除失败标记。"
Write-Host "  - 若红色壁纸因异常未自动还原，可运行 还原壁纸.bat 立即恢复。"
Write-Host "  - 新增：暂停监控.bat / 恢复监控.bat / 立即重连.bat / 清理维护.bat"
Write-Host "  - 单实例判定改用心跳文件 config\monitor_heartbeat.json：重复启动会安全退出，"
Write-Host "    而上次异常退出留下的死锁会在下次启动被自动接管，不会永久卡住。"
Write-Host "  - 可随时运行 检查状态.bat 复核。"
Write-Host ""
