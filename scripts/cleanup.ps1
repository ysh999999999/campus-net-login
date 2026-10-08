# cleanup.ps1 - 过期文件清理与归档（X-file）
#
# 作用：
#   1) exe 把截图与 login_steps.log 写在 bin\（它的 BASE_DIR），这里归档到 shots\ 与 logs\
#   2) 按保留天数删除过期截图与日志
#   3) 回收 %TEMP% 下本程序 exe 的 PyInstaller 解压残留（_MEI*，单个可达 380+ MB）
#   4) 清理临时壁纸位图
#
# 监控进程会按 cleanup.interval_hours（默认 24 小时）自动执行一次；
# 也可手动运行根目录的「清理维护.bat」立即执行。
#
# 参数：
#   -Force   忽略保留天数，删除全部截图与轮转日志副本（保留当前日志）
#   -DryRun  只报告将要做什么，不实际删除

param(
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # X-file\scripts
$rootDir   = Split-Path -Parent $scriptDir
$binDir    = Join-Path $rootDir "bin"
$configDir = Join-Path $rootDir "config"
$logDir    = Join-Path $rootDir "logs"
$shotDir   = Join-Path $rootDir "shots"

foreach ($d in @($binDir, $configDir, $logDir, $shotDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ---- 读取保留策略 ----
$settingsPath = Join-Path $configDir "monitor_settings.json"
$shotsKeep = 7; $logsKeep = 30; $meiEnabled = $true; $meiMaxAgeH = 6
$shotsMax = 40; $stepsMax = 1048576; $stepsKeepLines = 400
if (Test-Path $settingsPath) {
    try {
        $s = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($s.cleanup -ne $null) {
            if ($s.cleanup.shots_keep_days      -ne $null) { $shotsKeep  = [double]$s.cleanup.shots_keep_days }
            if ($s.cleanup.logs_keep_days       -ne $null) { $logsKeep   = [double]$s.cleanup.logs_keep_days }
            if ($s.cleanup.temp_mei             -ne $null) { $meiEnabled = [bool]$s.cleanup.temp_mei }
            if ($s.cleanup.temp_mei_max_age_hours -ne $null) { $meiMaxAgeH = [double]$s.cleanup.temp_mei_max_age_hours }
            if ($s.cleanup.shots_max_files      -ne $null) { $shotsMax   = [int]$s.cleanup.shots_max_files }
            if ($s.cleanup.login_steps_max_bytes -ne $null) { $stepsMax  = [double]$s.cleanup.login_steps_max_bytes }
            if ($s.cleanup.login_steps_keep_lines -ne $null) { $stepsKeepLines = [int]$s.cleanup.login_steps_keep_lines }
        }
    } catch {}
}
if ($Force) { $shotsKeep = 0; $logsKeep = 0 }

$freed = 0
$now   = Get-Date

function Say($m)  { Write-Host $m }
function SizeMB($bytes) { return [math]::Round(($bytes / 1MB), 1) }

Say "========================================"
Say "  X-file 清理维护"
Say "========================================"
if ($DryRun) { Say "  [演练模式] 不会实际删除任何文件" -ForegroundColor Yellow }
Say ("  保留策略: 截图 " + $shotsKeep + " 天 / 日志 " + $logsKeep + " 天")
Say ""

# ---------- 1. 归档 exe 产出的截图 ----------
Say "----- 截图归档 -----"
$pngs = @(Get-ChildItem -Path $binDir -Filter "*.png" -File -ErrorAction SilentlyContinue)
if ($pngs.Count -eq 0) {
    Say "  bin\ 下无待归档截图"
} else {
    $tot = ($pngs | Measure-Object -Property Length -Sum).Sum
    foreach ($f in $pngs) {
        $dst = Join-Path $shotDir $f.Name
        if ($DryRun) { Say ("  [将移动] " + $f.Name) }
        else { try { Move-Item -Path $f.FullName -Destination $dst -Force -ErrorAction Stop } catch {} }
    }
    Say ("  已归档 " + $pngs.Count + " 张 -> shots\  (" + (SizeMB $tot) + " MB)")
}

# ---------- 2. 归档 exe 写的 login_steps.log ----------
$srcSteps = Join-Path $binDir "login_steps.log"
$dstSteps = Join-Path $logDir "login_steps.log"
if (Test-Path $srcSteps) {
    if ($DryRun) { Say "  [将归档] bin\login_steps.log -> logs\" }
    else {
        try {
            $c = Get-Content -Path $srcSteps -Raw -Encoding UTF8 -ErrorAction Stop
            Add-Content -Path $dstSteps -Value $c -Encoding UTF8 -ErrorAction Stop
            Remove-Item -Path $srcSteps -Force -ErrorAction Stop
            Say "  已归档 bin\login_steps.log -> logs\"
        } catch {}
    }
}

# ---------- 3. 删除过期截图 ----------
Say ""
Say "----- 过期截图 -----"
if ($shotsKeep -le 0) {
    $all = @(Get-ChildItem -Path $shotDir -Filter "*.png" -File -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { Say "  无截图" }
    else {
        $tot = ($all | Measure-Object -Property Length -Sum).Sum
        foreach ($f in $all) {
            if ($DryRun) { Say ("  [将删除] " + $f.Name) }
            else { try { Remove-Item -Path $f.FullName -Force -ErrorAction Stop; $freed += $f.Length } catch {} }
        }
        Say ("  删除全部 " + $all.Count + " 张截图，释放 " + (SizeMB $tot) + " MB")
    }
} else {
    $old = @(Get-ChildItem -Path $shotDir -Filter "*.png" -File -ErrorAction SilentlyContinue |
             Where-Object { ($now - $_.LastWriteTime).TotalDays -gt $shotsKeep })
    if ($old.Count -eq 0) { Say ("  无超过 " + $shotsKeep + " 天的截图") }
    else {
        $tot = ($old | Measure-Object -Property Length -Sum).Sum
        foreach ($f in $old) {
            if ($DryRun) { Say ("  [将删除] " + $f.Name + "  (" + $f.LastWriteTime.ToString("MM-dd HH:mm") + ")") }
            else { try { Remove-Item -Path $f.FullName -Force -ErrorAction Stop; $freed += $f.Length } catch {} }
        }
        Say ("  删除 " + $old.Count + " 张过期截图，释放 " + (SizeMB $tot) + " MB")
    }
}

# ---------- 3b. 截图数量封顶 ----------
if ($shotsMax -gt 0) {
    $all = @(Get-ChildItem -Path $shotDir -Filter "*.png" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    if ($all.Count -gt $shotsMax) {
        $del = @($all[0 .. ($all.Count - $shotsMax - 1)])
        $tot = ($del | Measure-Object -Property Length -Sum).Sum
        foreach ($f in $del) {
            if ($DryRun) { Say ("  [将删除] " + $f.Name + "  (超出 " + $shotsMax + " 张上限)") }
            else { try { Remove-Item -Path $f.FullName -Force -ErrorAction Stop; $freed += $f.Length } catch {} }
        }
        Say ("  截图超出 " + $shotsMax + " 张上限，删除最旧 " + $del.Count + " 张，释放 " + (SizeMB $tot) + " MB")
    }
}

# ---------- 3c. login_steps.log 体积封顶 ----------
# 它每次登录都往末尾追加，mtime 永远最新，只按天数永远删不掉，必须单独截
$dstSteps2 = Join-Path $logDir "login_steps.log"
if ((Test-Path $dstSteps2) -and ((Get-Item $dstSteps2).Length -gt $stepsMax)) {
    $lines = @(Get-Content -Path $dstSteps2 -Encoding UTF8)
    if ($lines.Count -gt $stepsKeepLines) {
        if ($DryRun) {
            Say ("  [将截断] login_steps.log  " + $lines.Count + " 行 -> 末尾 " + $stepsKeepLines + " 行")
        } else {
            $tail = @($lines[($lines.Count - $stepsKeepLines) .. ($lines.Count - 1)])
            [System.IO.File]::WriteAllLines($dstSteps2, $tail, (New-Object System.Text.UTF8Encoding($false)))
            Say ("  已截断 login_steps.log -> 末尾 " + $stepsKeepLines + " 行")
        }
    }
}

# ---------- 4. 删除过期日志 ----------
Say ""
Say "----- 过期日志 -----"
if ($logsKeep -le 0) {
    # -Force：清掉轮转副本，保留当前正写的 monitor.log / login_steps.log
    $old = @(Get-ChildItem -Path $logDir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like "*.log.*" })
} else {
    $old = @(Get-ChildItem -Path $logDir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like "*.log*" -and ($now - $_.LastWriteTime).TotalDays -gt $logsKeep })
}
if ($old.Count -eq 0) { Say "  无过期日志" }
else {
    $tot = ($old | Measure-Object -Property Length -Sum).Sum
    foreach ($f in $old) {
        if ($DryRun) { Say ("  [将删除] " + $f.Name) }
        else { try { Remove-Item -Path $f.FullName -Force -ErrorAction Stop; $freed += $f.Length } catch {} }
    }
    Say ("  删除 " + $old.Count + " 个日志，释放 " + (SizeMB $tot) + " MB")
}

# ---------- 5. 回收 exe 解压残留 ----------
Say ""
Say "----- 临时解压残留 (%TEMP%) -----"
if (-not $meiEnabled) {
    Say "  已禁用（cleanup.temp_mei = false），跳过"
} else {
    $dirs = @(Get-ChildItem -Path $env:TEMP -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -like "_MEI*" -or $_.Name -like "_MEI_delete_me_*" })
    if ($dirs.Count -eq 0) {
        Say "  无残留"
    } else {
        foreach ($d in $dirs) {
            $age = ((Get-Date) - $d.LastWriteTime).TotalHours
            # 只认确实属于本程序 exe 的解压产物（含 ddddocr / playwright 目录），避免误删其它 PyInstaller 程序
            $isOurs = (Test-Path (Join-Path $d.FullName "ddddocr")) -or (Test-Path (Join-Path $d.FullName "playwright"))
            if (-not $isOurs) { continue }
            if ($age -lt $meiMaxAgeH) {
                Say ("  跳过 " + $d.Name + "（仅 " + [math]::Round($age,1) + " 小时，可能正在使用）")
                continue
            }
            $sz = (Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($sz -eq $null) { $sz = 0 }
            if ($DryRun) {
                Say ("  [将删除] " + $d.Name + "  " + (SizeMB $sz) + " MB")
                continue
            }
            try {
                Remove-Item -Path $d.FullName -Recurse -Force -ErrorAction Stop
                $freed += $sz
                Say ("  已清理 " + $d.Name + "  释放 " + (SizeMB $sz) + " MB")
            } catch {
                # 被独占占用：改名隔离，本次不再累积，重启后自动清掉
                try {
                    $newName = "_MEI_delete_me_" + (Get-Date -Format "yyyyMMdd_HHmmss")
                    Rename-Item -Path $d.FullName -NewName $newName -ErrorAction Stop
                    Say ("  " + $d.Name + " 被占用，已改名隔离 -> " + $newName + "（重启后自动清理）") -ForegroundColor Yellow
                } catch {
                    Say ("  " + $d.Name + " 清理失败: " + $_.Exception.Message) -ForegroundColor Red
                }
            }
        }
    }
}

# ---------- 6. 临时壁纸位图 ----------
$bmps = @(Get-ChildItem -Path $env:TEMP -Filter "campus_*.bmp" -File -ErrorAction SilentlyContinue)
if ($bmps.Count -gt 0) {
    foreach ($f in $bmps) {
        if (-not $DryRun) { try { Remove-Item -Path $f.FullName -Force -ErrorAction Stop; $freed += $f.Length } catch {} }
    }
    Say ("  清理临时壁纸位图 " + $bmps.Count + " 个")
}

# ---------- 汇总 ----------
Say ""
Say "========================================"
if ($DryRun) { Say "  演练结束，未做任何改动。" -ForegroundColor Yellow }
else { Say ("  清理完成，累计释放约 " + (SizeMB $freed) + " MB") -ForegroundColor Green }
Say "========================================"
Say ""
