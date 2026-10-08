# restore_wallpaper.ps1 - 立即还原被监控改写的桌面壁纸
#
# 场景：网络曾失败 -> 桌面被换成红色提示壁纸；即使随后网络恢复，若监控未走到恢复分支，
#       红色壁纸会一直留在桌面上。本脚本读取 config\wallpaper_orig.txt 中记录的原始壁纸
#       并立即还原，同时清除失败标记。
#
# 用法：restore_wallpaper.ps1 [-Path "D:\xxx\wall.jpg"]
#       未指定 -Path 时，读取 config\wallpaper_orig.txt；该文件缺失则报错退出。

param(
    [string]$Path = ""
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir   = Split-Path -Parent $scriptDir
$configDir = Join-Path $rootDir "config"
$logDir    = Join-Path $rootDir "logs"

$origFile = Join-Path $configDir "wallpaper_orig.txt"
$stateFile= Join-Path $configDir "wallpaper_state.txt"

function Log($m) {
    $line = (Get-Date -Format "yyyy/MM/dd HH:mm:ss") + " [INFO] RESTORE: " + $m
    try { Add-Content -Path (Join-Path $logDir "monitor.log") -Value $line -Encoding UTF8 } catch {}
    Write-Host $line
}

function Get-WallpaperFromCache {
    try {
        $b = (Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name TranscodedImageCache -ErrorAction Stop).TranscodedImageCache
        if ($b -eq $null -or $b.Length -lt 32) { return "" }
        $s = [System.Text.Encoding]::Unicode.GetString($b, 24, $b.Length - 24)
        $i = $s.IndexOf([char]0)
        if ($i -ge 0) { $s = $s.Substring(0, $i) }
        $s = $s.Trim().Trim([char]0xFEFF)
        if ($s -and (Test-Path -LiteralPath $s)) { return $s }
    } catch {}
    return ""
}

if (-not $Path) {
    if (Test-Path $origFile) {
        # 去掉可能存在的 UTF-8 BOM，否则路径比对与 Test-Path 都会失败
        $Path = [System.IO.File]::ReadAllText($origFile).Trim().Trim([char]0xFEFF)
    }
}
if (-not $Path) {
    $Path = Get-WallpaperFromCache
    if ($Path) { Write-Host ("记录文件缺失，已从系统缓存取回壁纸: " + $Path) -ForegroundColor Yellow }
}
if (-not $Path) {
    Write-Host "未记录原始壁纸（config\wallpaper_orig.txt 不存在），无法还原。" -ForegroundColor Yellow
    Write-Host "可手动指定：restore_wallpaper.ps1 -Path `"你的壁纸路径`"" -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host ("原始壁纸文件已不存在: " + $Path) -ForegroundColor Red
    exit 1
}

try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class NetWinRestorer {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@ -ErrorAction Stop
    $ok = [NetWinRestorer]::SystemParametersInfo(20, 0, $Path, 3)
} catch {
    Write-Host ("Win32 接口不可用，改用注册表: " + $_.Exception.Message) -ForegroundColor Yellow
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -Value $Path
    $ok = $true
}

if ($ok) {
    Log ("已还原壁纸 -> " + $Path)
    foreach ($f in @($stateFile, $origFile)) {
        if (Test-Path $f) { try { [System.IO.File]::Delete($f) } catch {} }
    }
    Write-Host "完成：壁纸已还原，失败标记已清除。" -ForegroundColor Green
} else {
    Write-Host "还原失败（SystemParametersInfo 返回 false）。" -ForegroundColor Red
    exit 1
}
