# reset.ps1 - 让 X-file 回到「刚拿到、还没安装启动过」的状态
#
# 三种力度：
#   1) 恢复初始未安装状态（推荐）：停监控 -> 移除计划任务 -> 还原壁纸 ->
#      删掉全部日志 / 截图 / 运行状态 / TEMP 残留。保留程序本体、账号、设置、源码、文档。
#   2) 只清垃圾不卸载：计划任务与监控照常跑，只把日志截图等产物清掉。
#   3) 彻底重置：在 1 的基础上连账号（campus_net_config.json）与监控设置一起删掉，
#      等同于刚解压的状态，需要重新 设置账号.bat + 安装.bat。
#
# 需要管理员权限（要停计划任务、结束由任务以高权限启动的监控进程）。

$id    = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
           [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host ""
    Write-Host "  需要管理员权限（停止计划任务 / 结束监控进程）。" -ForegroundColor Yellow
    Write-Host "  请在弹出的 UAC 窗口中点击「是」。" -ForegroundColor Yellow
    Write-Host ""
    Start-Process powershell -Verb RunAs -ArgumentList (
        "-ExecutionPolicy Bypass -NoExit -File `"" + $PSCommandPath + "`"")
    exit
}

$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # X-file\scripts
$rootDir   = Split-Path -Parent $scriptDir
$binDir    = Join-Path $rootDir "bin"
$configDir = Join-Path $rootDir "config"
$logDir    = Join-Path $rootDir "logs"
$shotDir   = Join-Path $rootDir "shots"
$taskName  = "Xfile_CampusNetGuard"

function Say($m, $c)  {
    if ($c) { Write-Host $m -ForegroundColor $c } else { Write-Host $m }
}
function SizeMB($bytes) { return [math]::Round(([double]$bytes / 1MB), 2) }
function GetDirSize($d) {
    if (-not (Test-Path -LiteralPath $d)) { return 0 }
    $s = (Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    if ($s -eq $null) { return 0 }
    return [double]$s
}
function Remove-Globed($dir, $pattern, $label) {
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $items = @(Get-ChildItem -LiteralPath $dir -Filter $pattern -File -Force -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) { return }
    $tot = ($items | Measure-Object -Property Length -Sum).Sum
    $n = 0
    foreach ($f in $items) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++ } catch {}
    }
    $script:freed += $tot
    Say ("    " + $label + "：" + $n + " 个，" + (SizeMB $tot) + " MB")
}
function Remove-FileIfExists($p, $label) {
    if (-not (Test-Path -LiteralPath $p)) { return }
    try {
        $sz = (Get-Item -LiteralPath $p -Force).Length
        Remove-Item -LiteralPath $p -Force -ErrorAction Stop
        $script:freed += $sz
        Say ("    " + $label + "：已删除")
    } catch {
        Say ("    " + $label + "：删除失败（可能被占用）") "Yellow"
    }
}

$script:freed = 0.0

# ---------- 菜单 ----------
Say ""
Say "========================================"
Say "  X-file 恢复初始状态"
Say "========================================"
Say ("  当前占用：日志 " + (SizeMB (GetDirSize $logDir)) + " MB / 截图 " + (SizeMB (GetDirSize $shotDir)) + " MB")
Say ""
Say "  1. 恢复初始未安装状态（推荐）"
Say "     停监控 + 移除计划任务 + 还原壁纸 + 清空日志/截图/运行状态/TEMP 残留"
Say "     保留：程序本体、账号、监控设置、源码、文档"
Say ""
Say "  2. 只清垃圾，不卸载"
Say "     监控照常运行，只清日志、截图、临时残留"
Say ""
Say "  3. 彻底重置"
Say "     在 1 的基础上，连账号与监控设置一起删掉（需重新设置账号并安装）"
Say ""
Say "  0. 取消"
Say ""
$choice = (Read-Host "  请选择 (1/2/3/0)").Trim()
if ($choice -ne "1" -and $choice -ne "2" -and $choice -ne "3") {
    Say ""
    Say "  已取消，未做任何改动。" "Yellow"
    exit 0
}

if ($choice -eq "1" -or $choice -eq "3") {
    Say ""
    Say "----- 停止监控 -----"
    try { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop; Say "    已停止计划任务" }
    catch { Say ("    停止任务失败或任务不存在: " + $_.Exception.Message) "Yellow" }
    Start-Sleep -Seconds 2

    # 结束监控进程：心跳 PID + 进程命令行双通道（提权进程的命令行常常读不到）
    $hbFile = Join-Path $configDir "monitor_heartbeat.json"
    if (Test-Path $hbFile) {
        try {
            $hb = Get-Content $hbFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($hb -and $hb.pid) {
                try { Stop-Process -Id ([int]$hb.pid) -Force -ErrorAction Stop; Say ("    已结束监控进程 PID=" + $hb.pid) } catch {}
            }
        } catch {}
    }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*monitor.ps1*" } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Say ("    已结束监控进程 PID=" + $_.ProcessId) } catch {} }
    Get-Process CampusNetLogin -ErrorAction SilentlyContinue |
        ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; Say ("    已结束登录程序 PID=" + $_.Id) } catch {} }
    Start-Sleep -Seconds 1

    Say ""
    Say "----- 移除计划任务 -----"
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Say "    已移除 Xfile_CampusNetGuard" "Green"
    } catch {
        & schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null
        $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($t) { Say "    移除失败，请到任务计划程序里手动删除" "Red" }
        else    { Say "    已移除 Xfile_CampusNetGuard" "Green" }
    }
}

# ---------- 壁纸还原 ----------
$stateFile = Join-Path $configDir "wallpaper_state.txt"
$origFile  = Join-Path $configDir "wallpaper_orig.txt"
if ((Test-Path $stateFile) -or (Test-Path $origFile)) {
    Say ""
    Say "----- 桌面壁纸 -----"
    $rp = Join-Path $scriptDir "restore_wallpaper.ps1"
    if (Test-Path $rp) {
        & $rp | Out-Null
        Say "    已调用 还原壁纸.bat 的脚本还原桌面壁纸"
    } else {
        Say "    未找到 restore_wallpaper.ps1，请手动还原壁纸" "Yellow"
    }
}

# ---------- 清空运行产物 ----------
Say ""
Say "----- 清空运行产物 -----"
Remove-Globed $logDir  "*.log*" "logs\ 日志"
Remove-Globed $logDir  "*"      "logs\ 其它"
Remove-Globed $shotDir "*.png"  "shots\ 截图"
Remove-Globed $binDir  "*.png"  "bin\ 未归档截图"
Remove-Globed $binDir  "*.log"  "bin\ 日志"
Remove-FileIfExists (Join-Path $binDir "last_run_time.json") "bin\last_run_time.json"
foreach ($f in @("monitor_heartbeat.json", "wallpaper_state.txt", "wallpaper_orig.txt",
                 "last_retention.txt", "pause.flag", "reconnect.flag")) {
    Remove-FileIfExists (Join-Path $configDir $f) ("config\" + $f)
}
Remove-Globed $configDir "wallpaper_backup.*" "config\ 壁纸缓存备份"   # [v2.9.6]
Remove-FileIfExists (Join-Path $rootDir "monitor.log") "根目录遗留 monitor.log"
Say "    已保留：bin\ 程序本体与账号、config\monitor_settings.json、scripts\、src\、docs\"

# ---------- TEMP 残留 ----------
Say ""
Say "----- 临时目录残留 -----"
$mei = @(Get-ChildItem -Path $env:TEMP -Directory -Force -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -like "_MEI*" -or $_.Name -like "_MEI_delete_me_*" })
$cnt = 0
foreach ($d in $mei) {
    $isOurs = (Test-Path (Join-Path $d.FullName "ddddocr")) -or (Test-Path (Join-Path $d.FullName "playwright"))
    if (-not $isOurs) { continue }
    $sz = GetDirSize $d.FullName
    try {
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop
        $script:freed += $sz; $cnt++
        Say ("    已清理 " + $d.Name + "  " + (SizeMB $sz) + " MB")
    } catch {
        try {
            $newName = "_MEI_delete_me_" + (Get-Date -Format "yyyyMMdd_HHmmss")
            Rename-Item -LiteralPath $d.FullName -NewName $newName -ErrorAction Stop
            Say ("    " + $d.Name + " 被占用，已改名隔离（重启后自动清理）") "Yellow"
        } catch {
            Say ("    " + $d.Name + " 清理失败") "Yellow"
        }
    }
}
if ($cnt -eq 0) { Say "    无残留" }
$bmp = @(Get-ChildItem -Path $env:TEMP -Filter "campus_*.bmp" -File -Force -ErrorAction SilentlyContinue)
if ($bmp.Count -gt 0) {
    $tot = ($bmp | Measure-Object -Property Length -Sum).Sum
    foreach ($f in $bmp) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch {} }
    $script:freed += $tot
    Say ("    清理临时壁纸位图 " + $bmp.Count + " 个，" + (SizeMB $tot) + " MB")
}

# ---------- 旧备份目录（可选）----------
$backups = @(Get-ChildItem -LiteralPath $rootDir -Directory -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like "_backup_*" })
if ($backups.Count -gt 0) {
    $bsz = 0
    foreach ($b in $backups) { $bsz += GetDirSize $b.FullName }
    Say ""
    Say ("----- 旧备份目录 " + $backups.Count + " 个，共 " + (SizeMB $bsz) + " MB -----")
    foreach ($b in $backups) { Say ("    " + $b.Name) }
    $ans = (Read-Host "  一并删除这些备份？（Y=删除，其它=保留）").Trim()
    if ($ans -eq "Y" -or $ans -eq "y") {
        foreach ($b in $backups) {
            try { Remove-Item -LiteralPath $b.FullName -Recurse -Force -ErrorAction Stop; $script:freed += (GetDirSize $b.FullName) }
            catch { Say ("    " + $b.Name + " 删除失败") "Yellow" }
        }
        Say "    已删除旧备份目录（注意：单文件版 exe 回滚包也不在了）" "Green"
    } else {
        Say "    已保留备份目录"
    }
}

# ---------- 彻底重置：账号与设置 ----------
if ($choice -eq "3") {
    Say ""
    Say "----- 彻底重置 -----"
    $ans = (Read-Host "  确认删除账号与监控设置？此操作不可撤销，输入 DELETE 继续").Trim()
    if ($ans -eq "DELETE") {
        Remove-FileIfExists (Join-Path $binDir "campus_net_config.json") "账号配置"
        Remove-FileIfExists (Join-Path $configDir "monitor_settings.json") "监控设置"
        Say "    已删除账号与设置（监控设置会在下次启动时用内置默认值重建）" "Green"
    } else {
        Say "    未删除，账号与设置保留" "Yellow"
    }
}

# ---------- 汇总 ----------
Say ""
Say "========================================"
Say ("  完成，累计释放约 " + (SizeMB $script:freed) + " MB") "Green"
Say ("  剩余占用：日志 " + (SizeMB (GetDirSize $logDir)) + " MB / 截图 " + (SizeMB (GetDirSize $shotDir)) + " MB")
if ($choice -eq "1" -or $choice -eq "3") {
    Say ""
    Say "  现在已回到未安装状态：开机不会再自动登录。" "Yellow"
    Say "  要重新启用：右键 安装.bat -> 以管理员身份运行。"
    if ($choice -eq "3") { Say "  （账号已清空，请先运行 设置账号.bat）" "Yellow" }
} else {
    Say ""
    Say "  监控仍在运行，只是清掉了历史产物。"
}
Say "========================================"
Say ""
