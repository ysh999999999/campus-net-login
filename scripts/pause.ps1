# pause.ps1 - 暂停 / 恢复 自动登录（X-file）
# 用法：pause.ps1 -Action pause | resume | status
param(
    [string]$Action = "status"
)

$ErrorActionPreference = "SilentlyContinue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # X-file\scripts
$rootDir   = Split-Path -Parent $scriptDir                     # X-file 根目录
$binDir    = Join-Path $rootDir "bin"        # 登录程序与其配置（必须同目录）
$configDir = Join-Path $rootDir "config"     # 监控设置与运行标志
$logDir    = Join-Path $rootDir "logs"       # 日志
$shotDir   = Join-Path $rootDir "shots"      # 截图

$flag = Join-Path $configDir "pause.flag"

switch ($Action.ToLower()) {
    "pause" {
        Set-Content -Path $flag -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8
        Write-Host "已暂停自动登录。监控仍在运行检测，但不会再自动拉起登录。" -ForegroundColor Yellow
        Write-Host "恢复：双击 恢复监控.bat" -ForegroundColor Yellow
    }
    "resume" {
        if (Test-Path $flag) {
            Remove-Item $flag -Force
            Write-Host "已恢复自动登录。" -ForegroundColor Green
        } else {
            Write-Host "当前未处于暂停状态。" -ForegroundColor Green
        }
    }
    default {
        if (Test-Path $flag) {
            Write-Host ("状态：已暂停（自 " + (Get-Content $flag -Raw).Trim() + "）") -ForegroundColor Yellow
        } else {
            Write-Host "状态：自动登录运行中" -ForegroundColor Green
        }
    }
}
Write-Host ""
