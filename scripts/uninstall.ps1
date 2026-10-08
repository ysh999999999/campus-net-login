# uninstall.ps1 - 移除校园网守护任务计划（X-file，需管理员）v2.0
# v2.0 改动：删除前二次确认；提权窗口保持打开；卸载后回显校验结果

$id    = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host ""
    Write-Host "  正在请求管理员权限，请在弹出的 UAC 窗口中点击「是」。" -ForegroundColor Yellow
    Write-Host ""
    Start-Process powershell -Verb RunAs -ArgumentList (
        "-ExecutionPolicy Bypass -NoExit -File `"" + $PSCommandPath + "`"")
    exit
}

Write-Host ""
Write-Host "即将移除校园网守护任务「Xfile_CampusNetGuard」，之后将不再自动登录。"
$ans = Read-Host "确认卸载请输入 Y（其它任意键取消）"
if ($ans -ne "Y" -and $ans -ne "y") {
    Write-Host "已取消，未做任何改动。" -ForegroundColor Yellow
    exit 0
}

Unregister-ScheduledTask -TaskName "Xfile_CampusNetGuard" -Confirm:$false -ErrorAction SilentlyContinue
schtasks /Delete /TN "Xfile_CampusNetGuard" /F 2>$null

# 结束残留监控进程（PS5.1 的 Get-Process 无 CommandLine 属性，必须用 CIM）
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*monitor.ps1*"
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 清理暂停/重连标志，避免下次安装后误处于暂停状态
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # X-file\scripts
$rootDir   = Split-Path -Parent $scriptDir                     # X-file 根目录
$binDir    = Join-Path $rootDir "bin"        # 登录程序与其配置（必须同目录）
$configDir = Join-Path $rootDir "config"     # 监控设置与运行标志
$logDir    = Join-Path $rootDir "logs"       # 日志
$shotDir   = Join-Path $rootDir "shots"      # 截图

foreach ($f in @("pause.flag", "reconnect.flag")) {
    $p = Join-Path $configDir $f
    if (Test-Path $p) { try { Remove-Item $p -Force } catch {} }
}

Start-Sleep -Seconds 1
$t = Get-ScheduledTask -TaskName "Xfile_CampusNetGuard" -ErrorAction SilentlyContinue
Write-Host ""
if ($t) { Write-Host "[未完成] 任务仍存在，请手动检查" -ForegroundColor Red }
else { Write-Host "已卸载校园网守护（X-file）。" -ForegroundColor Green }
Write-Host ""
