# status.ps1 - 校园网守护状态自检（X-file，只读）v2.0
# 新增：版本、依赖体检、路径一致性、暂停状态、失败冷却、残留解压目录占用
$ErrorActionPreference = "SilentlyContinue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # X-file\scripts
$rootDir   = Split-Path -Parent $scriptDir                     # X-file 根目录
$binDir    = Join-Path $rootDir "bin"        # 登录程序与其配置（必须同目录）
$configDir = Join-Path $rootDir "config"     # 监控设置与运行标志
$logDir    = Join-Path $rootDir "logs"       # 日志
$shotDir   = Join-Path $rootDir "shots"      # 截图


function Say($m) { Write-Host $m }
function OK($m)  { Write-Host ("  [正常] " + $m) -ForegroundColor Green }
function Bad($m) { Write-Host ("  [异常] " + $m) -ForegroundColor Red }
function Warn($m){ Write-Host ("  [提示] " + $m) -ForegroundColor Yellow }

Say "========================================"
Say "  校园网守护(X-file) - 状态检查"
Say "========================================"
Say ""

# --- 开发者标志（醒目置顶；主题写死在脚本内，不读配置、不提供修改入口）---
Write-Host ""
Write-Host "  ####  甄嬛传 · 熹贵妃  ·  DEVELOPER MODE  ####" -ForegroundColor Magenta
Write-Host "  ####  「臣妾做不到啊」—— 除非开着开发者模式  ####" -ForegroundColor Magenta
Write-Host "  ####  仅作标识，登录与监控行为与普通模式完全一致  ####" -ForegroundColor Magenta
Write-Host ""

# --- 版本 ---
$verFile = Join-Path $rootDir "VERSION"
if (Test-Path $verFile) { Say ("版本: v" + (Get-Content $verFile -Raw -Encoding UTF8).Trim()) } else { Say "版本: 未知（缺少 VERSION 文件）" }
Say ("PowerShell: " + $PSVersionTable.PSVersion.ToString())
Say ""

# --- 依赖体检 ---
Say "----- 依赖体检 -----"
$exe = Join-Path $binDir "CampusNetLogin.exe"
if (Test-Path $exe) {
    OK ("登录程序存在 (" + [math]::Round((Get-Item $exe).Length/1MB,1) + " MB)")
    # v2.2.0 起为 onedir 打包：exe 必须与 _internal 同目录，否则启动即崩
    $internal = Join-Path $binDir "_internal"
    if (Test-Path $internal) {
        $sz = (Get-ChildItem $internal -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($sz -eq $null) { $sz = 0 }
        OK ("就地依赖目录 _internal 存在（约 " + [math]::Round($sz/1MB,0) + " MB）-> 就地加载，不再解压到 TEMP")
    } else {
        Bad "缺少 _internal 依赖目录（onedir 版必须与 exe 同目录）"
    }
} else { Bad "未找到 CampusNetLogin.exe" }

$cfg = Join-Path $binDir "campus_net_config.json"
if (Test-Path $cfg) {
    OK "配置 campus_net_config.json 存在"
    try {
        $c = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
        $acc = ""; $pwd = ""
        if ($c.campus_network -ne $null) { $acc = [string]$c.campus_network.account; $pwd = [string]$c.campus_network.password }
        if ($acc -eq "") { Bad "配置中账号为空" } else { OK ("账号: " + $acc) }
        if ($pwd -eq "") { Bad "配置中密码为空" } else { OK ("密码: 已设置 (" + $pwd.Length + " 位，明文存储)") }
    } catch { Bad ("配置无法解析: " + $_.Exception.Message) }
} else { Bad "缺少 campus_net_config.json" }

$st = Join-Path $configDir "monitor_settings.json"
if (Test-Path $st) {
    try {
        $null = Get-Content $st -Raw -Encoding UTF8 | ConvertFrom-Json
        OK "监控设置 monitor_settings.json 存在且可解析"
    } catch { Bad ("monitor_settings.json 无法解析: " + $_.Exception.Message) }
} else { Warn "无 monitor_settings.json（将使用内置默认值）" }

$edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
if (Test-Path $edge) { OK ("Microsoft Edge " + (Get-Item $edge).VersionInfo.ProductVersion) } else { Warn "未在默认路径找到 Edge（登录依赖浏览器）" }
Say ""

# --- 计划任务 ---
Say "----- 计划任务 -----"
$t = Get-ScheduledTask -TaskName "Xfile_CampusNetGuard"
if (-not $t) {
    Bad "未安装 Xfile_CampusNetGuard   <-- 请右键 安装.bat，以管理员身份运行"
} else {
    OK ("已安装   状态=" + $t.State + "   身份=" + $t.Principal.UserId + "   权限=" + $t.Principal.RunLevel)
    foreach ($tr in $t.Triggers) { Say ("   触发器: " + $tr.CimClass.CimClassName) }
    $info = Get-ScheduledTaskInfo -TaskName "Xfile_CampusNetGuard"
    if ($info) { Say ("   上次运行: " + $info.LastRunTime + "   结果码: " + $info.LastTaskResult) }
    # 路径一致性：目录分层或移动过文件夹后，任务会指向已不存在的旧脚本路径。
    # 必须比对「脚本完整路径」而非目录，否则旧路径会被误判为一致。
    $mon = Join-Path $scriptDir "monitor.ps1"
    $taskCmd = ""
    # [修复] 属性名是 Execute 而非 Exec，写错会导致永远读不到命令、路径校验形同虚设
    foreach ($a in $t.Actions) { if ($a.Execute) { $taskCmd = [string]$a.Arguments } }
    if (-not $taskCmd) {
        Warn "未能读取计划任务命令，无法校验路径"
    } elseif ($taskCmd -notmatch [regex]::Escape($mon)) {
        Bad "计划任务仍指向旧路径，自动登录已失效 <-- 请重新运行 安装.bat"
        Say  ("      期望: " + $mon)
        Say  ("      实际: " + $taskCmd)
    } elseif (-not (Test-Path $mon)) {
        Bad ("任务指向的脚本不存在: " + $mon)
    } else {
        OK "任务路径与当前脚本一致"
    }
}
Say ""

# --- 进程 ---
Say "----- 监控进程 -----"
$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*monitor.ps1*" })
# 心跳：新版 monitor 每轮循环刷新 PID+时间戳，是判断实例是否真活着的可靠依据。
# 计划任务以 Highest 启动时，进程命令行对普通窗口不可读，只看 $procs 会误报"未运行"，故以心跳为准。
$hbFile = Join-Path $configDir "monitor_heartbeat.json"
$hbAlive = $false
$hbPid   = 0
if (Test-Path $hbFile) {
    try {
        $hb  = Get-Content $hbFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $age = [int]((Get-Date) - [datetime]::Parse($hb.ts)).TotalSeconds
        $hbp = Get-Process -Id ([int]$hb.pid) -ErrorAction SilentlyContinue
        $hbPid = [int]$hb.pid
        if ($hbp -and $age -le 900) {
            $hbAlive = $true
            OK ("心跳正常：PID=" + $hb.pid + "，" + $age + "s 前刷新")
        } elseif ($age -gt 900) {
            Warn ("心跳已停滞 " + $age + "s（PID=" + $hb.pid + "），实例可能卡死，下次启动会被接管")
        } else {
            Warn ("心跳中的 PID=" + $hb.pid + " 已不存在，属异常残留")
        }
    } catch { Warn ("心跳文件无法解析: " + $_.Exception.Message) }
} else {
    Warn "无心跳文件 -> 在跑的可能是 2.1.1 之前的旧版实例；右键 安装.bat 以管理员运行即可切换到新版"
}

if ($procs.Count -eq 0) {
    if ($hbAlive) { OK ("监控进程运行中 (PID=" + $hbPid + "，命令行因权限不可读，已按心跳确认存活)") }
    else          { Bad "监控进程未运行" }
} elseif ($procs.Count -eq 1) {
    OK ("监控进程 1 个 (PID=" + $procs[0].ProcessId + ")")
} else {
    Bad ("监控进程 " + $procs.Count + " 个，存在重复实例！")
}
foreach ($p in $procs) { Say ("   PID=" + $p.ProcessId + "  内存=" + [math]::Round($p.WorkingSetSize/1MB,1) + " MB") }
Say ""

# --- 状态 ---
Say "----- 运行状态 -----"
if (Test-Path (Join-Path $configDir "pause.flag")) { Warn "已暂停自动登录（运行 恢复监控.bat 恢复）" } else { OK "自动登录已启用" }
$stateWall = Join-Path $configDir "wallpaper_state.txt"
$origWall  = Join-Path $configDir "wallpaper_orig.txt"
if (Test-Path $stateWall) {
    Warn "桌面壁纸处于【失败】红色状态（网络一旦恢复，监控会自动还原）"
    if (Test-Path $origWall) {
        Say ("  已记录原始壁纸: " + [System.IO.File]::ReadAllText($origWall).Trim().Trim([char]0xFEFF))
    } else {
        Warn "  未记录原始壁纸，恢复时可能只能用提示图兜底（可用 还原壁纸.bat 手动指定）"
    }
} elseif (Test-Path $origWall) {
    Warn "残留了原始壁纸记录但没有失败标记（监控下次循环会自动清理）"
} else {
    OK "壁纸状态正常（无失败标记）"
}

# --- 免打扰时段 ---
try {
    $st2 = Get-Content (Join-Path $configDir "monitor_settings.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $qh = $st2.quiet_hours
    if ($qh) {
        function ToMin($hm) {
            if ($hm -match '^(\d{1,2}):(\d{1,2})$') { return ([int]$Matches[1] * 60 + [int]$Matches[2]) }
            return 0
        }
        $qs = ToMin ([string]$qh.start); $qe = ToMin ([string]$qh.end)
        $nn = (Get-Date).Hour * 60 + (Get-Date).Minute
        $inQuiet = $false
        if ([bool]$qh.enabled -and $qs -ne $qe) {
            if ($qs -lt $qe) { $inQuiet = ($nn -ge $qs -and $nn -lt $qe) } else { $inQuiet = ($nn -ge $qs -or $nn -lt $qe) }
        }
        $label = ([string]$qh.start) + "-" + ([string]$qh.end)
        if (-not [bool]$qh.enabled) {
            Say  ("  免打扰: 未启用（可用 设置免打扰.bat 开启）")
        } elseif ($inQuiet) {
            Warn ("免打扰: 生效中 " + $label + "（" + $(if([bool]$qh.skip_auto_login){"已停止自动登录"}else{"仍静默保活登录"}) + "，不弹窗/不换壁纸/不通知）")
        } else {
            OK   ("免打扰: " + $label + "（当前不在该时段，" + $(if([bool]$qh.skip_auto_login){"时段内停止自动登录"}else{"时段内仍静默保活"}) + "）")
        }
    } else {
        Warn "免打扰: 配置中无 quiet_hours 段（运行 设置免打扰.bat 可写入）"
    }
    $bw2 = $st2.background_window
    if ($bw2) { Say ("  后台静默: " + $bw2.start + "-" + $bw2.end + "（该时段登录窗口后台运行，可用 设置免打扰.bat 修改）") }
    $su2 = $st2.startup
    if ($su2) {
        $g = [int]$su2.grace_sec
        if ($g -gt 0) { Say ("  开机宽限期: " + $g + "s（该时段内网络不通不切红壁纸，每 " + [int]$su2.retry_interval_sec + "s 重试登录）") }
        else          { Say "  开机宽限期: 已关闭（网络不通会立即切红壁纸）" }
    }
} catch {}
Say ""

# --- 磁盘占用 ---
Say "----- 产物占用 -----"
function DirMB($d) {
    if (-not (Test-Path -LiteralPath $d)) { return 0 }
    $s = (Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($s -eq $null) { return 0 }
    return [math]::Round(([double]$s / 1MB), 2)
}
$logMB = DirMB $logDir
$shotMB = DirMB $shotDir
$shotCnt = @(Get-ChildItem -LiteralPath $shotDir -Filter "*.png" -File -ErrorAction SilentlyContinue).Count
$cap = 40
try {
    $st3 = Get-Content (Join-Path $configDir "monitor_settings.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($st3.cleanup -ne $null -and $st3.cleanup.shots_max_files -ne $null) { $cap = [int]$st3.cleanup.shots_max_files }
} catch {}
Say ("  日志 logs\        " + $logMB + " MB（monitor.log 2MB 轮转保留 3 份 + 步骤日志 1MB 封顶）")
if ($cap -gt 0 -and $shotCnt -gt $cap) {
    Warn ("  截图 shots\       " + $shotMB + " MB / " + $shotCnt + " 张（上限 " + $cap + " 张，下次清理会删最旧的）")
} else {
    Say  ("  截图 shots\       " + $shotMB + " MB / " + $shotCnt + " 张（上限 " + $cap + " 张）")
}
$binPng = @(Get-ChildItem -LiteralPath $binDir -Filter "*.png" -File -ErrorAction SilentlyContinue)
if ($binPng.Count -gt 0) {
    $bp = [math]::Round((($binPng | Measure-Object -Property Length -Sum).Sum / 1MB), 2)
    Say ("  bin\ 待归档截图   " + $bp + " MB / " + $binPng.Count + " 张（清理周期内会移入 shots\）")
}
Say "  想全部清掉：清理维护.bat；想回到未安装状态：恢复初始状态.bat"
Say ""

# --- 残留占用 ---
Say "----- 临时目录占用 -----"
$mei = @(Get-ChildItem -Path $env:TEMP -Filter "_MEI*" -Directory -ErrorAction SilentlyContinue)
if ($mei.Count -gt 0) {
    $total = 0
    foreach ($d in $mei) {
        $sz = (Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($sz -eq $null) { $sz = 0 }
        $total += $sz
    }
    Warn ("发现 " + $mei.Count + " 个 PyInstaller 解压残留，合计约 " + [math]::Round($total/1MB,0) + " MB")
    Say "   如需立即清理：运行根目录的 清理维护.bat（或等待监控按周期自动清理）"
} else { OK "无解压残留" }
Say ""

# --- 日志 ---
$log = Join-Path $logDir "monitor.log"
if (Test-Path $log) {
    Say ("----- monitor.log 最后 15 行（共 " + (Get-Item $log).Length + " 字节）-----")
    Get-Content $log -Tail 15
} else {
    Say "monitor.log 尚不存在（监控还未运行过）"
}
