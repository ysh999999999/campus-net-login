# restore_wallpaper.ps1 - 立即还原被监控改写的桌面壁纸
#
# 场景：网络曾失败 -> 桌面被换成红色提示壁纸；即使随后网络恢复，若监控未走到恢复分支，
#       红色壁纸会一直留在桌面上。本脚本读取 config\wallpaper_orig.txt 中记录的原始壁纸
#       并立即还原，同时清除失败标记。
#
# 用法：restore_wallpaper.ps1 [-Path "D:\xxx\wall.jpg"]
#       未指定 -Path 时，读取 config\wallpaper_orig.txt；该文件缺失则报错退出。
#
# [v2.9.6] 新增：识别并排除 Windows 系统主题缓存。幻灯片 / 聚焦 / 动态壁纸的注册表
#          Wallpaper 值指向 %APPDATA%\Microsoft\Windows\Themes\TranscodedWallpaper，
#          其内容会被"切失败壁纸"那一下覆盖成红图 —— 按它还原等于把红图再设一遍。
#          现在优先改用监控留下的 config\wallpaper_backup.* 副本还原。

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
$themesDir = Join-Path $env:APPDATA "Microsoft\Windows\Themes"   # [v2.9.6] Windows 主题缓存目录

function Log($m) {
    $line = (Get-Date -Format "yyyy/MM/dd HH:mm:ss") + " [INFO] RESTORE: " + $m
    try { Add-Content -Path (Join-Path $logDir "monitor.log") -Value $line -Encoding UTF8 } catch {}
    Write-Host $line
}

# [v2.9.6] Windows 系统主题缓存目录内的路径一律不作为"用户的原始壁纸"
function Test-SystemWallCache([string]$p) {
    if (-not $p) { return $false }
    try { $p = [System.IO.Path]::GetFullPath($p) } catch {}
    $p = ([string]$p).Trim().TrimEnd('\')
    if (-not $p) { return $false }
    if (($p -like "*\Microsoft\Windows\Themes\TranscodedWallpaper") -or
        ($p -like "*\Microsoft\Windows\Themes\Transcoded_*")) { return $true }
    $th = ""
    try { $th = [System.IO.Path]::GetFullPath($themesDir).TrimEnd('\') } catch {}
    if (-not $th) {
        try { $th = [System.IO.Path]::GetFullPath((Join-Path $env:APPDATA "Microsoft\Windows\Themes")).TrimEnd('\') } catch {}
    }
    if ($th -and $p.Length -gt $th.Length) {
        if ($p.Substring(0, $th.Length).ToLower() -eq $th.ToLower() -and $p[$th.Length] -eq '\') { return $true }
    }
    return $false
}

function Get-WallpaperFromCache {
    try {
        $b = (Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name TranscodedImageCache -ErrorAction Stop).TranscodedImageCache
        if ($b -eq $null -or $b.Length -lt 32) { return "" }
        $s = [System.Text.Encoding]::Unicode.GetString($b, 24, $b.Length - 24)
        $i = $s.IndexOf([char]0)
        if ($i -ge 0) { $s = $s.Substring(0, $i) }
        $s = $s.Trim().Trim([char]0xFEFF)
        if ($s -and (-not (Test-SystemWallCache $s)) -and (Test-Path -LiteralPath $s)) { return $s }
    } catch {}
    return ""
}

if (-not $Path) {
    if (Test-Path $origFile) {
        # 去掉可能存在的 UTF-8 BOM，否则路径比对与 Test-Path 都会失败
        $Path = [System.IO.File]::ReadAllText($origFile).Trim().Trim([char]0xFEFF)
    }
}
# [v2.9.6] 记录里若写的是系统主题缓存，按它"还原"只会把失败壁纸再设一遍（桌面永久红屏）
if ($Path -and (Test-SystemWallCache $Path)) {
    Write-Host "记录的原始壁纸是系统主题缓存（内容已被失败壁纸覆盖），不能据此还原。" -ForegroundColor Yellow
    Write-Host "请在 桌面右键 -> 个性化 -> 背景 中重新选择一次壁纸。" -ForegroundColor Yellow
    $Path = ""
}
# [v2.9.6] 其次用监控在切失败壁纸【之前】留下的缓存内容备份（那时内容还是用户那张图）
if (-not $Path) {
    $bak = @(Get-ChildItem -LiteralPath $configDir -Filter "wallpaper_backup.*" -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending)
    if ($bak.Count -ge 1) {
        $Path = $bak[0].FullName
        Write-Host ("已改用监控备份的原始壁纸副本: " + $Path) -ForegroundColor Yellow
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
    # [v2.9.6] 若用的是监控留下的缓存备份，把内容写回系统主题缓存并让桌面指回它，
    # 否则注册表指向的备份一旦被清理，重启后桌面会变成默认壁纸。
    try {
        $cdir = [System.IO.Path]::GetFullPath($configDir).TrimEnd('\')
        $fdir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path)).TrimEnd('\')
        $fnam = [System.IO.Path]::GetFileName($Path)
        if (($fdir.ToLower() -eq $cdir.ToLower()) -and $fnam.ToLower().StartsWith("wallpaper_backup.")) {
            $srcFile = Join-Path $configDir "wallpaper_backup.src"
            if (Test-Path -LiteralPath $srcFile) {
                $src = [System.IO.File]::ReadAllText($srcFile, [System.Text.Encoding]::UTF8).Trim().Trim([char]0xFEFF)
                $sdir = ""
                if ($src) { try { $sdir = Split-Path -Parent $src } catch {} }
                if ($src -and $sdir -and (Test-Path -LiteralPath $sdir)) {
                    [System.IO.File]::WriteAllBytes($src, [System.IO.File]::ReadAllBytes($Path))
                    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -Value $src
                    Write-Host ("已把原图写回系统主题缓存并让桌面指回它: " + $src) -ForegroundColor Yellow
                }
            }
        }
    } catch {
        Write-Host "写回系统主题缓存失败；若重启后壁纸不对，到 个性化->背景 重选一次即可。" -ForegroundColor Yellow
    }
    foreach ($f in @($stateFile, $origFile)) {
        if (Test-Path $f) { try { [System.IO.File]::Delete($f) } catch {} }
    }
    # [v2.9.6] 一并清掉监控留下的缓存备份
    try {
        Get-ChildItem -LiteralPath $configDir -Filter "wallpaper_backup.*" -File -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    } catch {}
    Write-Host "完成：壁纸已还原，失败标记已清除。" -ForegroundColor Green
} else {
    Write-Host "还原失败（SystemParametersInfo 返回 false）。" -ForegroundColor Red
    exit 1
}
