# monitor.ps1 - 校园网守护（X-file）v2.0
#
# 行为：
#   ping 检测 -> 异常则登录；正常则按间隔做 HTTP 会话探测，仅在会话失效或超过保活时限时登录
#   后台时段(默认 7:00-23:00)静默运行；失败换红色壁纸，失败后恢复换绿色壁纸
#
# v2.0 相对旧版的改动：
#   [修复] 配置读取去掉 PS6+ 才有的 -AsHashtable，PS5.1 下可正常加载（旧版 100% 加载失败）
#   [新增] 独立设置文件 monitor_settings.json，不干扰 exe 读取的 campus_net_config.json
#   [新增] 单实例互斥锁，避免重复实例并发登录
#   [新增] 会话轻量探测，网络与 HTTP 均正常时跳过无谓的整点重登
#   [新增] 连续失败指数退避与冷却，避免无效重试持续冲击认证接口
#   [新增] pause.flag / reconnect.flag 手动控制（暂停监控 / 立即重连）
#   [修复] 网络检测改用 ping 退出码，不再依赖 "TTL=" 文案（兼容 IPv6 与非中文系统）
#   [修复] 壁纸 GDI 资源在 finally 中释放，异常时不再泄漏句柄
#   [新增] 日志分级、心跳降噪与按大小轮转
#   [新增] 可选：exe 超时后终止；可选：清理 PyInstaller 残留解压目录
#
# v2.8 相对 v2.7 的改动：
#   [新增] 连接失败壁纸改为 4K 高清主题图：主视觉「臣妾做不到啊」+ 右侧「连接失败」检查清单
#          画布按屏幕比例放大到长边 3840（4K），文字走 GDI+ 矢量渲染，任何分辨率下都清晰
#   [修复] 背景渐变改用两段两色线性渐变刷（PS5.1 下 ColorBlend 三色插值不可靠，会导致画面发灰）
#   [调整] TEMP 里的临时提示壁纸清理时一并回收 jpg / png（新壁纸是 JPEG）
#
# v2.9 相对 v2.8 的改动：
#   [新增] 失败壁纸轮替：内置主题图 + assets\theme_*.jpg（网络素材）轮流使用，
#          游标存于 config\wallpaper_rotation.txt，每次切换前进一格
#   [新增] 素材卡片模式：网络素材按原生像素装裱成白底金框卡片（不做有损放大），
#          个别素材可按文件名约定裁边（theme_01.jpg 裁掉右侧 28% 的站方水印）
#   [修复] 重构后遗留的一句 $brTitle.Dispose() 引用了已移出的变量，会导致整张图生成失败
#
# v2.9.2 相对 v2.9.1 的改动：
#   [新增] 素材支持两种版式，按文件名前缀自动区分（用户自己找的图放进来即可用）：
#           theme_full_*.jpg  -> 全屏铺底：整图等比铺满 4K 画布（cover 居中裁剪），再压暗叠字
#           theme_*.jpg       -> 卡片装裱：原图像素装裱成白底金框卡片，左侧展示、右侧留给检查清单
#   [新增] 素材说明文字自动取 assets\SOURCES.txt 中同名条目，找不到时显示「自定义素材 · 文件名」，
#          不再把「甄嬛传名场面」写死在用户自己的图片下方
#   [新增] 素材模式记录进日志（WALLPAPER 行），便于确认某次切图用的是卡片还是整图
#
# v2.9.3 相对 v2.9.2 的改动：
#   [修复] 全屏铺底改成【整图居中】：原图等比收进左半区显示框，完整可见、不裁剪、不拉伸变形
#          （v2.9.2 的 cover 铺满会把横图/方图裁掉一大半，看起来像"被拉伸、看不全"）
#   [修复] 卡片模式同样不再对素材裁边（theme_01 原来固定裁掉右侧 28%），整张原图进卡片
#   [修复] 小图不再有损放大：卡片最多放大 1.25 倍、整图模式一律不放大，宁可小一点也不糊
#
# v2.9.4 相对 v2.9.3 的改动：
#   [修复] 改完账号密码不能立刻生效：手动重连（reconnect.flag）现在会把退避/冷却节奏一并归零，
#          此前该分支虽不受退避限制，但一次失败后 failStreak 仍会从上次的计数继续累加，
#          密码填错后改对，最坏要等满 60 分钟冷却才会重试。
#   [新增] 配合 set_account.ps1：保存账号密码成功后自动写 reconnect.flag，
#          实现「保存即自动重试一次」，不必再手动双击 立即重连.bat。
#
# v2.9.5 相对 v2.9.4 的改动：
#   [修复] 壁纸还原失败的残余缺口：以前 SetOkWallpaper 无条件清除失败标记，
#          万一"还原"这一步本身失败（原壁纸文件被删、恢复提示图生成或应用失败），
#          标记照样被清掉，之后所有自愈点都认为"没有失败态"，红屏永久留在桌面且不再重试。
#          现在只有【确认桌面已回到正常状态】才清标记；失败则保留标记并于 60s 后重试。
#   [修复] ApplyWallpaper 不再无条件返回成功：Win32 分支校验 SystemParametersInfo 返回值，
#          注册表分支回读比对，避免"设置失败却被当成还原成功"。

# v2.9.6 相对 v2.9.5 的改动：
#   [修复] 幻灯片 / Windows 聚焦 / 动态壁纸下"网络已恢复但红屏不消失"：
#          这类背景的注册表 Wallpaper 指向 Windows 转码缓存
#          （%APPDATA%\Microsoft\Windows\Themes\TranscodedWallpaper），
#          它会被当成"用户原图"记录下来；而"切红屏"这一下，Windows 恰好会把红图
#          转码【覆盖】进同一个缓存文件 —— 于是"还原"= 把红图再设一遍，
#          桌面永久红屏，日志却还报"已还原为原始壁纸"。
#          新增 Test-SystemWallCache 守卫：系统主题缓存目录内的一切路径都不作为原图。
#   [新增] 切红屏前把该缓存【内容】备份到 config\wallpaper_backup.<png|jpg|bmp>，
#          还原时改用它 —— 红屏功能照旧，用户那张壁纸还能真正回到桌面
#          （没有备份时退回绿色"已恢复"提示图，至少不卡死）。
#   [调整] 还原壁纸.bat / 重置脚本同步识别该缓存，并一并清理备份文件。

$ErrorActionPreference = "Continue"

# X-file 采用分层目录：
#   bin\     登录程序与其配置（两者必须同目录，exe 按自身所在目录查找 campus_net_config.json）
#   config\  监控设置与运行标志
#   logs\    日志
#   shots\   截图
#   scripts\ 本脚本所在目录
#   docs\    说明文档
#   src\     Python 源码
$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir      = Split-Path -Parent $scriptDir
$binDir       = Join-Path $rootDir "bin"
$configDir    = Join-Path $rootDir "config"
$logDir       = Join-Path $rootDir "logs"
$shotDir      = Join-Path $rootDir "shots"

# 若目录被误删则自动重建，避免监控因路径缺失而失效
foreach ($d in @($binDir, $configDir, $logDir, $shotDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$exe          = Join-Path $binDir "CampusNetLogin.exe"
$configPath   = Join-Path $binDir "campus_net_config.json"
$settingsPath = Join-Path $configDir "monitor_settings.json"
$logPath      = Join-Path $logDir "monitor.log"
$stateFile    = Join-Path $configDir "wallpaper_state.txt"
$origWallFile = Join-Path $configDir "wallpaper_orig.txt"
$pauseFile    = Join-Path $configDir "pause.flag"
$reconnectFile= Join-Path $configDir "reconnect.flag"
$versionFile  = Join-Path $rootDir "VERSION"
$retentionFile= Join-Path $configDir "last_retention.txt"
$hbFile       = Join-Path $configDir "monitor_heartbeat.json"
$themesDir    = Join-Path $env:APPDATA "Microsoft\Windows\Themes"   # [v2.9.6] Windows 主题缓存目录（幻灯片/聚焦壁纸的 Wallpaper 值指向这里）
$script:hbStaleSec = 900      # 心跳超过 15 分钟未刷新即视为僵死，可被新实例接管

# ---------------- 日志 ----------------
$script:logMaxBytes = 2097152
$script:logKeep     = 3

function Rotate-Log {
    try {
        for ($i = $script:logKeep; $i -ge 1; $i--) {
            $src = "$logPath.$i"
            if (-not (Test-Path $src)) { continue }
            if ($i -ge $script:logKeep) { Remove-Item $src -Force -ErrorAction SilentlyContinue }
            else { Move-Item $src ($logPath + "." + ($i + 1)) -Force -ErrorAction SilentlyContinue }
        }
        Move-Item $logPath ($logPath + ".1") -Force -ErrorAction SilentlyContinue
        Add-Content -Path $logPath -Value ((Get-Date -Format "yyyy/MM/dd HH:mm:ss") + " [INFO] 日志已轮转") -Encoding UTF8
    } catch {}
}

function Log($m, $level = "INFO") {
    try {
        $t = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
        $tag = ""
        if ($script:devTag) { $tag = " " + $script:devTag }
        Add-Content -Path $logPath -Value "$t [$level]$tag $m" -Encoding UTF8 -ErrorAction Stop
    } catch {
        # 日志写不进去也不能让监控停摆
    }
    try {
        if ((Get-Item $logPath -ErrorAction SilentlyContinue).Length -gt $script:logMaxBytes) { Rotate-Log }
    } catch {}
}

# ---------------- 设置读取 ----------------
function Read-JsonFile($path) {
    if (-not (Test-Path $path)) { return $null }
    try {
        # 必须显式指定 UTF8：PS5.1 默认按 ANSI 读取，含中文且无 BOM 的配置会乱码
        return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Log ("CONFIG: 解析失败 " + $path + " : " + $_.Exception.Message) "ERROR"
        return $null
    }
}

function GetCfg($obj, $prop, $default) {
    if ($obj -ne $null) {
        $p = $obj.PSObject.Properties[$prop]
        if ($p -ne $null -and $p.Value -ne $null) { return $p.Value }
    }
    return $default
}

$settings = Read-JsonFile $settingsPath
if ($settings -eq $null) { $settings = Read-JsonFile $configPath }   # 向后兼容：没有新设置文件时退回旧配置

# 默认值（任一项读取失败都退回这里，保证可用性）
$pingTargets     = @("www.baidu.com", "www.qq.com", "bilibili.com")
$pingCount       = 2
$pingTimeoutMs   = 2000
$pingIntervalSec = 300
$probeEnabled    = $true
$probeUrl        = "https://www.bilibili.com"
$probeTimeoutMs  = 8000
$probeIntervalSec = 3600
$forceReloginHours = 2
$bgStartH = 7; $bgEndH = 23
# 免打扰时段：默认 23:00-07:00。时段内不弹窗、不换壁纸、不弹通知；
# skip_auto_login=false 时仍会静默保活登录（既不吵人，又不会让你整夜断网）。
$quietEnabled    = $true
$quietStartH     = 23; $quietStartM = 0
$quietEndH       = 7;  $quietEndM   = 0
$quietSkipLogin  = $false
$quietMuteNotify = $true
$coolThreshold   = 5
$cooldownMinutes = 60
$backoffBase     = 300
$backoffMax      = 1800
$retryAfterSec   = 120
$exeWaitMs       = 180000
$hideEdgeIntervalSec = 5
$notifyWallpaper = $true
$notifyToast     = $true
$cleanTempMei    = $false
$tempMeiMaxAgeHours = 6
$killExeOnTimeout = $true
$killExeTree     = $false
$heartbeatSec    = 1800
# 开发者标志：以《甄嬛传》为主题，固化写死在脚本内（不读配置、不提供修改入口）。
# 仅用于醒目标识开发者身份 / 开发环境，不改变任何登录与监控行为。
$devEnabled      = $true
$devLabel        = "甄嬛传"
$devOwner        = "熹贵妃"
$devQuote        = "「臣妾做不到啊」—— 除非开着开发者模式"
$devMarkLog      = $true
$devMarkToast    = $true
$devMarkWall     = $true
# 开机宽限期：刚启动的头 N 秒，网卡/拨号通常还没就绪，此时 ping 不通属于正常现象。
# 宽限期内不切红色失败壁纸、不累积失败次数、不进冷却，只持续重试登录。
$startupGraceSec = 150
$startupRetrySec = 20

if ($settings -ne $null) {
    $ping   = GetCfg $settings "ping"   $null
    $probe  = GetCfg $settings "session_probe" $null
    $retry  = GetCfg $settings "retry"  $null
    $exes   = GetCfg $settings "exe"    $null
    $notif  = GetCfg $settings "notify" $null
    $clean  = GetCfg $settings "cleanup" $null
    $logcfg = GetCfg $settings "log"    $null
    $bw     = GetCfg $settings "background_window" $null
    $qh     = GetCfg $settings "quiet_hours" $null
    $su     = GetCfg $settings "startup" $null

    $pingTargets     = GetCfg $ping "targets" $pingTargets
    $pingCount       = [int](GetCfg $ping "count" $pingCount)
    $pingTimeoutMs   = [int](GetCfg $ping "timeout_ms" $pingTimeoutMs)
    $pingIntervalSec = [int](GetCfg $ping "interval_sec" $pingIntervalSec)

    $probeEnabled      = [bool](GetCfg $probe "enabled" $probeEnabled)
    $probeUrl          = GetCfg $probe "url" $probeUrl
    $probeTimeoutMs    = [int](GetCfg $probe "timeout_ms" $probeTimeoutMs)
    $probeIntervalSec  = [int](GetCfg $probe "interval_sec" $probeIntervalSec)
    $forceReloginHours = [double](GetCfg $probe "force_relogin_hours" $forceReloginHours)

    $coolThreshold   = [int](GetCfg $retry "consecutive_failures_before_cooldown" $coolThreshold)
    $cooldownMinutes = [int](GetCfg $retry "cooldown_minutes" $cooldownMinutes)
    $backoffBase     = [double](GetCfg $retry "backoff_base_sec" $backoffBase)
    $backoffMax      = [double](GetCfg $retry "backoff_max_sec" $backoffMax)
    $retryAfterSec   = [int](GetCfg $retry "after_login_wait_sec" $retryAfterSec)

    $exeWaitMs           = [int](GetCfg $exes "wait_ms" $exeWaitMs)
    $hideEdgeIntervalSec = [int](GetCfg $exes "hide_edge_interval_sec" $hideEdgeIntervalSec)

    $notifyWallpaper = [bool](GetCfg $notif "wallpaper" $notifyWallpaper)
    $notifyToast     = [bool](GetCfg $notif "toast" $notifyToast)

    $killExeOnTimeout  = [bool](GetCfg $clean "kill_exe_on_timeout" $killExeOnTimeout)
    $killExeTree       = [bool](GetCfg $clean "kill_exe_tree" $killExeTree)
    $cleanTempMei      = [bool](GetCfg $clean "temp_mei" $cleanTempMei)
    $tempMeiMaxAgeHours= [int](GetCfg $clean "temp_mei_max_age_hours" $tempMeiMaxAgeHours)

    $script:logMaxBytes = [int](GetCfg $logcfg "max_bytes" $script:logMaxBytes)
    $script:logKeep     = [int](GetCfg $logcfg "keep" $script:logKeep)
    $heartbeatSec       = [int](GetCfg $logcfg "heartbeat_every_sec" $heartbeatSec)

    if ($bw -ne $null) {
        $s = [string](GetCfg $bw "start" "")
        $e = [string](GetCfg $bw "end" "")
        if ($s -match "^(\d{1,2}):") { $bgStartH = [int]$Matches[1] }
        if ($e -match "^(\d{1,2}):") { $bgEndH   = [int]$Matches[1] }
    }
    if ($qh -ne $null) {
        $quietEnabled    = [bool](GetCfg $qh "enabled" $quietEnabled)
        $quietSkipLogin  = [bool](GetCfg $qh "skip_auto_login" $quietSkipLogin)
        $quietMuteNotify = [bool](GetCfg $qh "mute_notify" $quietMuteNotify)
        $s = [string](GetCfg $qh "start" "")
        $e = [string](GetCfg $qh "end" "")
        if ($s -match "^(\d{1,2}):(\d{1,2})$") { $quietStartH = [int]$Matches[1]; $quietStartM = [int]$Matches[2] }
        if ($e -match "^(\d{1,2}):(\d{1,2})$") { $quietEndH   = [int]$Matches[1]; $quietEndM   = [int]$Matches[2] }
    }
    if ($su -ne $null) {
        $startupGraceSec = [int](GetCfg $su "grace_sec" $startupGraceSec)
        $startupRetrySec = [int](GetCfg $su "retry_interval_sec" $startupRetrySec)
    }
    if ($startupGraceSec -lt 0)    { $startupGraceSec = 0 }
    if ($startupRetrySec  -lt 5)    { $startupRetrySec = 5 }
}

# 开发者标志汇总：主题写死，不看配置文件，也没有对外修改入口
$devShow = $devLabel
if ($devOwner) { $devShow = $devLabel + " · " + $devOwner }
$script:devEnabled   = $devEnabled
$script:devLabel     = $devLabel
$script:devOwner     = $devOwner
$script:devShow      = $devShow
$script:devQuote     = $devQuote
$script:devMarkLog   = $devMarkLog
$script:devMarkToast = $devMarkToast
$script:devMarkWall  = $devMarkWall
$script:devTag       = ""       # 日志行内标签，供 Log 使用
$script:devWallBadge = ""
if ($devEnabled) {
    if ($devMarkLog)   { $script:devTag       = "[甄嬛传]" }
    if ($devMarkWall)  { $script:devWallBadge = "甄嬛传 · DEV" }
}

$script:bgStartH = $bgStartH
$script:bgEndH   = $bgEndH
$script:quietEnabled    = $quietEnabled
$script:quietStartMin   = $quietStartH * 60 + $quietStartM
$script:quietEndMin     = $quietEndH   * 60 + $quietEndM
$script:quietSkipLogin  = $quietSkipLogin
$script:quietMuteNotify = $quietMuteNotify
$script:quietLabel      = ("{0:D2}:{1:D2}-{2:D2}:{3:D2}" -f $quietStartH, $quietStartM, $quietEndH, $quietEndM)
$script:hideEdgeIntervalSec = $hideEdgeIntervalSec
$script:notifyToast = $notifyToast
$script:notifyWallpaper = $notifyWallpaper
$script:failStreak = 0
$script:toastWarned = $false
$script:lastLoginTime = Get-Date
$script:startTime = Get-Date
$script:startupGraceSec = $startupGraceSec
$script:startupRetrySec = $startupRetrySec
$script:graceEnded = $false

# ---------------- 启动信息 ----------------
$ver = "unknown"
if (Test-Path $versionFile) { try { $ver = (Get-Content $versionFile -Raw -Encoding UTF8).Trim() } catch {} }
Log ("INIT: monitor 启动 v" + $ver + " / PS " + $PSVersionTable.PSVersion.ToString()) "INFO"
if ($settings -eq $null) {
    Log "INIT: 未读到任何配置文件，全部使用内置默认值" "WARN"
}
Log ("INIT: 后台时段 " + $bgStartH + ":00-" + $bgEndH + ":00 / ping " + $pingIntervalSec + "s / 探测 " + $probeIntervalSec + "s / 保活 " + $forceReloginHours + "h") "INFO"
if ($startupGraceSec -gt 0) {
    Log ("INIT: 开机宽限期 " + $startupGraceSec + "s（宽限期内网络不通不切红壁纸、不进冷却，每 " + $startupRetrySec + "s 重试登录）") "INFO"
} else {
    Log "INIT: 开机宽限期已关闭（网络不通会立即切红色失败壁纸）" "INFO"
}
if ($quietEnabled) {
    Log ("INIT: 免打扰时段 " + $script:quietLabel + " / 静音通知=" + $quietMuteNotify + " / 停止自动登录=" + $quietSkipLogin) "INFO"
} else {
    Log "INIT: 免打扰未启用" "INFO"
}
if (-not (Test-Path $exe)) { Log ("INIT: 未找到登录程序 " + $exe) "ERROR" }
if ($script:devEnabled) {
    # 开发者标志：在日志里打一条醒目横幅，翻日志时第一眼就能看出这份日志来自开发环境
    Log "########################################################"
    Log ("###  " + $script:devShow + "  ·  DEVELOPER MODE")
    Log ("###  " + $script:devQuote)
    Log "###  仅作标识，登录与监控行为与普通模式完全一致"
    Log "########################################################"
}

# ---------------- 心跳（单实例判定的可靠依据）----------------
# 只靠互斥锁无法区分"真重复启动"和"上次异常退出留下的死锁"；
# 只靠扫描进程命令行也不可靠（提权/隐藏进程的命令行常常读不到）。
# 因此以心跳文件为主：存活实例每轮循环刷新 PID+时间戳。
function Write-Hb {
    try {
        $obj = @{ pid = $PID; ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); ver = $ver }
        ($obj | ConvertTo-Json -Compress) | Set-Content -LiteralPath $hbFile -Encoding UTF8 -Force -ErrorAction Stop
    } catch {}
}
function Read-Hb {
    if (-not (Test-Path $hbFile)) { return $null }
    try {
        $j = (Get-Content -LiteralPath $hbFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
        if (-not $j -or -not $j.pid -or -not $j.ts) { return $null }
        return $j
    } catch { return $null }
}
function Get-HbAgeSec($hb) {
    try { return [int]((Get-Date) - [datetime]::Parse($hb.ts)).TotalSeconds } catch { return 999999 }
}

# ---------------- 单实例互斥锁 ----------------
$script:mutex = $null
$script:hasLock = $true
try {
    $script:mutex = New-Object System.Threading.Mutex($false, "Xfile_CampusNetGuard_Monitor")
    $script:hasLock = $script:mutex.WaitOne(0, $false)
} catch {
    $script:hasLock = $true   # 拿不到互斥机制时宁可运行，也不要彻底不监控
}
if (-not $script:hasLock) {
    # 互斥锁拿不到：可能是真重复启动，也可能是上次异常退出留下的死锁。
    # 判定顺序：心跳 -> 进程命令行扫描 -> 兜底接管
    $hb = Read-Hb
    if ($hb) {
        $age = Get-HbAgeSec $hb
        $alive = $null
        try { $alive = Get-Process -Id ([int]$hb.pid) -ErrorAction SilentlyContinue } catch {}
        if ($alive -and $age -le $script:hbStaleSec) {
            Log ("INIT: 已有监控实例在运行 (PID=" + $hb.pid + "，心跳 " + $age + "s 前)，本次退出") "WARN"
            exit 0
        }
        if ($alive -and $age -gt $script:hbStaleSec) {
            Log ("INIT: 发现僵死实例 PID=" + $hb.pid + "（心跳停滞 " + $age + "s）-> 尝试结束") "WARN"
            try { Stop-Process -Id ([int]$hb.pid) -Force -ErrorAction Stop; Log ("INIT: 已结束僵死实例 PID=" + $hb.pid) "INFO" }
            catch { Log ("INIT: 无法自动结束 PID=" + $hb.pid + "（权限不足），请在任务管理器中手动结束后重启监控") "WARN" }
        }
        if (-not $alive) { Log ("INIT: 心跳中的 PID=" + $hb.pid + " 已不存在 -> 本次接管") "WARN" }
    } else {
        # 无心跳：要么从未启动过，要么是旧版（2.1.0 及更早）实例在跑
        $live = @()
        try {
            $live = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                      Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*monitor.ps1*" })
        } catch {}
        if ($live.Count -gt 0) {
            Log ("INIT: 检测到旧版监控实例 (PID=" + $live[0].ProcessId + ") 正在运行，本次退出；如需切换到新版请先结束该进程") "WARN"
            exit 0
        }
        Log "INIT: 未发现有效心跳，判定为残留锁 -> 本次接管" "WARN"
    }
    $script:hasLock = $true
}
Write-Hb

# ---------------- Win32 接口（编译失败也绝不阻断登录，仅降级）----------------
$script:HasWin32 = $false
try {
    $csrc = 'using System;'
    $csrc += 'using System.Runtime.InteropServices;'
    $csrc += 'public class NetWin {'
    $csrc += '  [DllImport("user32.dll")] public static extern int SystemParametersInfo(int a,int b,string c,int d);'
    $csrc += '  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);'
    $csrc += '}'
    Add-Type -TypeDefinition $csrc -ErrorAction Stop
    $script:HasWin32 = $true
    Log "INIT: Win32 接口就绪" "INFO"
} catch {
    $script:HasWin32 = $false
    Log ("INIT: Win32 接口不可用，降级运行（登录照常，隐藏窗口/换壁纸受限）: " + $_.Exception.Message) "WARN"
}

# ---------------- 通知 ----------------
function Show-Toast($title, $text) {
    if (-not $script:notifyToast) { return }
    if (IsMutedNow) { return }          # 免打扰时段：不弹通知
    if ($script:devEnabled -and $script:devMarkToast) { $title = "[甄嬛传] " + $title }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $xml = '<toast><visual><binding template="ToastText02"><text id="1">' + $title + '</text><text id="2">' + $text + '</text></binding></visual></toast>'
        $doc = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $doc.LoadXml($xml)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Xfile 校园网守护").Show($toast)
    } catch {
        if (-not $script:toastWarned) {
            $script:toastWarned = $true
            Log ("TOAST: 不可用，后续仅用壁纸提示: " + $_.Exception.Message) "INFO"
        }
    }
}

function ApplyWallpaper($path) {
    # [v2.9.5] 返回值必须是"真的设置成功了"。以前 Win32 分支无条件 return $true，
    # 于是连"设置失败"都会被当成还原成功 —— 调用方随即清掉失败标记，红屏再也不会重试。
    if ($script:HasWin32) {
        $r = [NetWin]::SystemParametersInfo(20, 0, $path, 3)
        return ([int]$r -ne 0)
    }
    try {
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -Value $path
        Start-Process -FilePath "rundll32.exe" -ArgumentList "user32.dll,UpdatePerUserSystemParameters" -WindowStyle Hidden -ErrorAction SilentlyContinue
        # 回读注册表确认值确实写进去了（rundll32 的应用是异步的，这里只确认写入成功）
        $cur = (Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -ErrorAction Stop).Wallpaper
        return ([string]$cur -eq [string]$path)
    } catch {
        return $false
    }
}

function MakeWallpaper($file, $rgb, $title, $badge = "") {
    $bmp = $null; $g = $null; $font = $null; $bfont = $null
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $w = 1920; $h = 1080
        try {
            $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            if ($b.Width -gt 0 -and $b.Height -gt 0) { $w = $b.Width; $h = $b.Height }
        } catch {}
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::FromArgb($rgb[0], $rgb[1], $rgb[2]))
        $size = [int]($h / 15)
        try { $font = New-Object System.Drawing.Font("Microsoft YaHei", $size) }
        catch { $font = New-Object System.Drawing.Font("Arial", $size) }
        $g.DrawString($title, $font, [System.Drawing.Brushes]::White, ($w * 0.09), ($h * 0.40))
        if ($badge) {
            # 右下角醒目角标（开发者标志）
            $bsize = [int]($h / 26)
            try { $bfont = New-Object System.Drawing.Font("Microsoft YaHei", $bsize, [System.Drawing.FontStyle]::Bold) }
            catch { $bfont = New-Object System.Drawing.Font("Arial", $bsize, [System.Drawing.FontStyle]::Bold) }
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment     = [System.Drawing.StringAlignment]::Far
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Far
            $pad = [int]($w * 0.03)
            $rect = New-Object System.Drawing.RectangleF($pad, $pad, ($w - 2 * $pad), ($h - 2 * $pad))
            $g.DrawString($badge, $bfont, [System.Drawing.Brushes]::Yellow, $rect, $sf)
        }
        $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Bmp)
        return $true
    } catch {
        Log ("WALLPAPER: 生成失败 " + $_.Exception.Message) "ERROR"
        return $false
    } finally {
        if ($bfont -ne $null) { try { $bfont.Dispose() } catch {} }
        if ($font -ne $null) { try { $font.Dispose() } catch {} }
        if ($g -ne $null)    { try { $g.Dispose() }    catch {} }
        if ($bmp -ne $null)  { try { $bmp.Dispose() }  catch {} }
    }
}

# ---------------- 4K 高清失败壁纸 ----------------
# 主视觉「臣妾做不到啊」+ 右侧「连接失败 / 检查清单」面板。
# 画布按屏幕比例放大到 4K（长边 3840 像素），文字走 GDI+ 矢量渲染，任意分辨率下都清晰。
$script:fontFancy = @("华文行楷", "STXingkai", "华文楷体", "STKaiti", "楷体", "KaiTi", "Microsoft YaHei UI", "Microsoft YaHei")
$script:fontSans  = @("Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "SimHei", "Arial")

# 网络素材（可选）：assets\theme_*.jpg|png，与内置渐变主题图轮流上阵
$script:wallAssetDir = Join-Path $rootDir "assets"
$script:wallRotFile  = Join-Path $configDir "wallpaper_rotation.txt"

function Get-WallThemes {
    $out = @()
    if (Test-Path $script:wallAssetDir) {
        try {
            $out = @(Get-ChildItem -Path $script:wallAssetDir -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like "theme_*" -and @(".jpg", ".jpeg", ".png", ".bmp") -contains $_.Extension.ToLower() } |
                     Sort-Object Name |
                     ForEach-Object { $_.FullName })
        } catch {}
    }
    return $out
}

# 个别素材需要裁掉边缘（例如剧照右上角带平台水印），按文件名约定
function Get-ThemeCrop($path) {
    # 默认一律不裁边：整张原图完整显示，缺了哪一块都比带水印更别扭。
    # 真遇到必须裁的素材，再在这里按文件名登记比例（0.28 = 裁掉右侧 28%）
    $map = @{}
    $n = ""
    try { $n = (Split-Path $path -Leaf).ToLower() } catch {}
    if ($map.ContainsKey($n)) { return [double]$map[$n] }
    return 0.0
}

# 素材版式：theme_full_* 走全屏铺底，其余走卡片装裱
function Get-ThemeMode($path) {
    $n = ""
    try { $n = (Split-Path $path -Leaf).ToLower() } catch {}
    if ($n -like "theme_full_*") { return "full" }
    return "card"
}

# 素材说明：优先取 assets\SOURCES.txt 里以该文件名开头的那一行，没有就回落成「自定义素材」
function Get-ThemeCaption($path) {
    $name = ""
    try { $name = (Split-Path $path -Leaf) } catch {}
    $fallback = "自定义素材 · " + $name
    try {
        $src = Join-Path $script:wallAssetDir "SOURCES.txt"
        if (-not (Test-Path -LiteralPath $src)) { return $fallback }
        $all = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
        foreach ($line in ($all -split "`r?`n")) {
            $t = $line.Trim()
            if ($t -eq "") { continue }
            if ($t.StartsWith("#")) { continue }
            if ($t.ToLower().StartsWith($name.ToLower())) {
                $cap = $t.Substring($name.Length).Trim()
                $cap = $cap.TrimStart("-", "—", "·", "：", ":", " ")
                if ($cap.Length -gt 40) { $cap = $cap.Substring(0, 40) + "…" }
                if ($cap -ne "") { return $cap }
            }
        }
    } catch {}
    return $fallback
}

# 轮换游标：每切一次失败壁纸前进一格；0 号固定是内置主题图
function Get-NextWallIndex($count) {
    if ($count -le 1) { return 0 }
    $cur = 0
    try {
        if (Test-Path $script:wallRotFile) {
            $t = (Get-Content $script:wallRotFile -Raw -Encoding UTF8).Trim()
            if ($t -match "^\d+$") { $cur = [int]$t }
        }
    } catch {}
    if ($cur -lt 0 -or $cur -ge $count) { $cur = 0 }
    try {
        [System.IO.File]::WriteAllText($script:wallRotFile, [string](($cur + 1) % $count), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
    return $cur
}

# 按候选名单挑系统里真实存在的字体；字号用像素单位，方便在 4K 画布上精确排版
function New-UiFont($candidates, $px, $style, $pool) {
    $fam = $null
    try {
        $names = @([System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name })
        foreach ($c in $candidates) { if ($names -contains $c) { $fam = $c; break } }
    } catch {}
    if (-not $fam) { $fam = "Microsoft YaHei" }
    $f = $null
    try { $f = New-Object System.Drawing.Font($fam, [single]$px, $style, [System.Drawing.GraphicsUnit]::Pixel) } catch {}
    if ($f -eq $null) {
        try { $f = New-Object System.Drawing.Font("Microsoft YaHei", [single]$px, $style, [System.Drawing.GraphicsUnit]::Pixel) } catch {}
    }
    if ($f -eq $null) { $f = New-Object System.Drawing.Font("Arial", [single]$px, $style, [System.Drawing.GraphicsUnit]::Pixel) }
    if ($pool -ne $null) { $pool.Add($f) | Out-Null }
    return $f
}

function New-TextFormat($hAlign, $vAlign) {
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment     = $hAlign
    $sf.LineAlignment = $vAlign
    return $sf
}

# 先描一层偏移阴影再画正文，4K 大字在浅色背景上也不会糊
function Draw-EmbossedText($g, $text, $font, $brush, $rect, $sf, $off) {
    $sb = $null
    try {
        $sb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 0, 0, 0))
        $sr = New-Object System.Drawing.RectangleF($rect.X + $off, $rect.Y + $off, $rect.Width, $rect.Height)
        $g.DrawString($text, $font, $sb, $sr, $sf)
    } catch {}
    if ($sb -ne $null) { $sb.Dispose() }
    $g.DrawString($text, $font, $brush, $rect, $sf)
}

# 主视觉 A（内置主题图）：左侧「臣妾做不到啊」大字，白字描金边
function Draw-FailHero($g, $W, $H, $pool) {
    $tx = [int]($W * 0.06)
    $title = "臣妾做不到啊"
    $fsTitle = [int](($W * 0.43) / $title.Length)
    $fTitle = New-UiFont $script:fontFancy $fsTitle ([System.Drawing.FontStyle]::Bold) $pool
    $fKai   = New-UiFont $script:fontFancy ([int]($H * 0.040)) ([System.Drawing.FontStyle]::Regular) $pool
    $sfNear = New-TextFormat ([System.Drawing.StringAlignment]::Near) ([System.Drawing.StringAlignment]::Near)

    $ey = [int]($H * 0.215)
    $brEye = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(215, 255, 232, 190))
    $g.DrawString("校园网认证失败 · 连接中断", $fKai, $brEye,
        (New-Object System.Drawing.RectangleF($tx, $ey, [int]($W * 0.55), [int]($H * 0.07))), $sfNear)
    $brEye.Dispose()

    $ty = [int]($H * 0.30)
    $brTitle = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 255))
    # 描一圈金边再压白字，远看像宫里的匾额
    $edge   = [int]($H * 0.006)
    $brEdge = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 226, 178, 84))
    foreach ($dx in @(-$edge, 0, $edge)) {
        foreach ($dy in @(-$edge, 0, $edge)) {
            if ($dx -eq 0 -and $dy -eq 0) { continue }
            $er = New-Object System.Drawing.RectangleF(($tx + $dx), ($ty + $dy), [int]($W * 0.50), [int]($H * 0.30))
            $g.DrawString($title, $fTitle, $brEdge, $er, $sfNear)
        }
    }
    $brEdge.Dispose()
    $titleRect = New-Object System.Drawing.RectangleF($tx, $ty, [int]($W * 0.50), [int]($H * 0.30))
    Draw-EmbossedText $g $title $fTitle $brTitle $titleRect $sfNear ([int]($H * 0.004))
    $brTitle.Dispose()

    $subY = $ty + [int]($fsTitle * 1.30)
    $brSub = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220, 255, 236, 198))
    $subTxt = "—— 熹贵妃 · 甄嬛传"
    if ($script:devEnabled -and $script:devOwner) { $subTxt = "—— " + $script:devOwner + " · " + $script:devLabel }
    $g.DrawString($subTxt, $fKai, $brSub, (New-Object System.Drawing.RectangleF($tx, $subY, [int]($W * 0.55), [int]($H * 0.08))), $sfNear)
    $brSub.Dispose()

    $lineY = $subY + [int]($H * 0.085)
    $penGold = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(210, 232, 200, 112), [single]($H * 0.0055))
    $g.DrawLine($penGold, $tx, $lineY, ($tx + [int]($W * 0.30)), $lineY)
    $penGold.Dispose()

    $brNote = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(190, 255, 245, 225))
    $g.DrawString("臣妾已尽力重试，奈何这网终究是连不上……", $fKai, $brNote,
        (New-Object System.Drawing.RectangleF($tx, ($lineY + [int]($H * 0.025)), [int]($W * 0.50), [int]($H * 0.07))), $sfNear)
    $brNote.Dispose()
}

# 主视觉 B（网络素材）：把素材原图按原生像素装裱成白底金框卡片，避免放大变糊
function Draw-FailCard($g, $W, $H, $pool, $imgPath, $cropRight) {
    $img = $null
    try {
        $img  = [System.Drawing.Image]::FromFile($imgPath)
        $iw   = [int]$img.Width
        $ih   = [int]$img.Height
        $srcW = [int]($iw * (1.0 - $cropRight))
        $srcH = $ih
        if ($srcW -lt 32) { $srcW = $iw }

        # 目标尺寸：先按高度放，太宽再按宽度收，始终等比（整张原图，不裁边）
        $maxH = [int]($H * 0.600)
        $maxW = [int]($W * 0.46)
        $dh = $maxH
        $dw = [int]($dh * $srcW / $srcH)
        if ($dw -gt $maxW) { $dw = $maxW; $dh = [int]($dw * $srcH / $srcW) }
        # 小图不做有损放大：最多放大 1.25 倍，宁可小一点也不糊（4K 画布上放 500px 的图会很肉）
        if ($dh -gt [int]($srcH * 1.25)) { $dh = [int]($srcH * 1.25); $dw = [int]($srcW * 1.25) }

        $pad = [int]($W * 0.009)
        $cw  = $dw + 2 * $pad
        $ch  = $dh + 2 * $pad
        $cx  = [int](($W * 0.50 - $cw) / 2)          # 居中于左半区，右侧留给提示面板
        $boxTop = [int]($H * 0.200)
        $boxH   = [int]($H * 0.610)
        $cy = $boxTop + [int](($boxH - $ch) / 2)
        if ($cy -lt $boxTop) { $cy = $boxTop }

        # 投影 -> 白底 -> 金框 -> 素材
        $off = [int]($H * 0.006)
        $bs = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 0, 0, 0))
        $g.FillRectangle($bs, ($cx + $off), ($cy + $off), $cw, $ch)
        $bs.Dispose()
        $bw = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 253, 251, 247))
        $g.FillRectangle($bw, $cx, $cy, $cw, $ch)
        $bw.Dispose()
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(235, 226, 178, 84), [single]($H * 0.0045))
        $g.DrawRectangle($pen, $cx, $cy, $cw, $ch)
        $pen.Dispose()

        $dst = New-Object System.Drawing.Rectangle(($cx + $pad), ($cy + $pad), $dw, $dh)
        $g.DrawImage($img, $dst, 0, 0, $srcW, $srcH, [System.Drawing.GraphicsUnit]::Pixel)

        # 卡片下方一行小字：说明这张图的来历
        $fCap = New-UiFont $script:fontSans ([int]($H * 0.027)) ([System.Drawing.FontStyle]::Regular) $pool
        $brCap = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(190, 255, 244, 224))
        $sfCap = New-TextFormat ([System.Drawing.StringAlignment]::Center) ([System.Drawing.StringAlignment]::Near)
        $capY = $cy + $ch + [int]($H * 0.014)
        if ($capY -lt ($H * 0.88)) {
            $capText = Get-ThemeCaption $imgPath     # 自己找的图会显示「自定义素材 · 文件名」
            $g.DrawString($capText, $fCap, $brCap,
                (New-Object System.Drawing.RectangleF(0, $capY, [int]($W * 0.50), [int]($H * 0.05))), $sfCap)
        }
        $brCap.Dispose()
    } catch {
        Log ("WALLPAPER: 素材卡片绘制失败 " + $_.Exception.Message) "WARN"
    } finally {
        if ($img -ne $null) { try { $img.Dispose() } catch {} }
    }
}

# 主视觉 C（用户自定义壁纸 / theme_full_*）：整图居中大图，完整可见、不裁剪、不拉伸变形
function Draw-FailFullImage($g, $W, $H, $pool, $imgPath) {
    $img = $null
    try {
        $img = [System.Drawing.Image]::FromFile($imgPath)
        $iw  = [double]$img.Width
        $ih  = [double]$img.Height
        if ($iw -le 0 -or $ih -le 0) { return }

        # contain：整张图等比收进左半区的显示框里，长边顶到框边即止 —— 不放大、不裁边
        $boxW = [int]($W * 0.50)
        $boxH = [int]($H * 0.70)
        $scale = [Math]::Min(($boxW / $iw), ($boxH / $ih))
        if ($scale -gt 1.0) { $scale = 1.0 }        # 小图也不硬拉：宁可小一点，也不糊
        $dw = [int][Math]::Round($iw * $scale)
        $dh = [int][Math]::Round($ih * $scale)

        # 水平居中于左半区，垂直落在主视觉带内
        $cx = [int][Math]::Round(($W * 0.50 - $dw) / 2)
        $top = [int]($H * 0.215)
        $cy = [int][Math]::Round($top + ($boxH - $dh) / 2)
        if ($cy -lt $top) { $cy = $top }

        # 投影 -> 金框 -> 原图（不加白底，免得浅色图外面多一圈突兀的白边）
        $off = [int]($H * 0.007)
        $bs = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(130, 0, 0, 0))
        $g.FillRectangle($bs, ($cx + $off), ($cy + $off), $dw, $dh)
        $bs.Dispose()
        $g.DrawImage($img, (New-Object System.Drawing.Rectangle($cx, $cy, $dw, $dh)),
                     0, 0, [int]$iw, [int]$ih, [System.Drawing.GraphicsUnit]::Pixel)
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(220, 226, 178, 84), [single]($H * 0.0035))
        $g.DrawRectangle($pen, $cx, $cy, $dw, $dh)
        $pen.Dispose()
    } catch {
        Log ("WALLPAPER: 自定义壁纸绘制失败 " + $_.Exception.Message) "WARN"
    } finally {
        if ($img -ne $null) { try { $img.Dispose() } catch {} }
    }
}

function MakeFailWallpaper($file, $rgb, $badge = "", $subInfo = "", $themeImage = "", $themeCrop = 0.0, $themeMode = "card") {
    $bmp = $null; $g = $null
    $pool = New-Object System.Collections.ArrayList
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

        # --- 画布：长边固定 3840（4K），短边按屏幕比例换算，壁纸不会被拉伸变形 ---
        $sw = 1920.0; $sh = 1080.0
        try {
            $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            if ($b.Width -gt 0 -and $b.Height -gt 0) { $sw = [double]$b.Width; $sh = [double]$b.Height }
        } catch {}
        $ratio = $sw / $sh
        $W = 3840; $H = [int][Math]::Round(3840 / $ratio)
        if ($ratio -lt 1) { $H = 3840; $W = [int][Math]::Round(3840 * $ratio) }
        if ($W % 2 -ne 0) { $W += 1 }
        if ($H % 2 -ne 0) { $H += 1 }

        $bmp = New-Object System.Drawing.Bitmap($W, $H)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.TextRenderingHint  = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

        # --- 背景：三段式渐变 + 光晕，避免纯色块在高分屏上显脏 ---
        # 主色调往白/黑两侧扩散：中间带提亮（否则深红会压成一团黑），两端压暗做层次
        $c0 = [System.Drawing.Color]::FromArgb(
                  [int][Math]::Round($rgb[0] * 0.28), [int][Math]::Round($rgb[1] * 0.20), [int][Math]::Round($rgb[2] * 0.34))
        $c1 = [System.Drawing.Color]::FromArgb(
                  [int][Math]::Round($rgb[0] + (255 - $rgb[0]) * 0.24),
                  [int][Math]::Round($rgb[1] + (255 - $rgb[1]) * 0.20),
                  [int][Math]::Round($rgb[2] + (255 - $rgb[2]) * 0.24))
        $c2 = [System.Drawing.Color]::FromArgb(
                  [int][Math]::Round($rgb[0] * 0.44), [int][Math]::Round($rgb[1] * 0.28), [int][Math]::Round($rgb[2] * 0.50))
        # 分两段上色（PS5.1 下 ColorBlend 的三色插值不可靠，两色渐变更稳）
        $hMid = [int]($H * 0.55)
        $lbA = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                   (New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point(0, $hMid)), $c0, $c1)
        $g.FillRectangle($lbA, 0, 0, $W, $hMid)
        $lbA.Dispose()
        $lbB = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                   (New-Object System.Drawing.Point(0, $hMid)), (New-Object System.Drawing.Point(0, $H)), $c1, $c2)
        $g.FillRectangle($lbB, 0, $hMid, $W, ($H - $hMid))
        $lbB.Dispose()

        foreach ($halo in @(
            @{ x = 0.30; y = 0.46; a = 26 },
            @{ x = 0.78; y = 0.18; a = 18 },
            @{ x = 0.62; y = 0.86; a = 15 }
        )) {
            $hb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($halo.a, 255, 246, 214))
            $rr = [int]($W * 0.30)
            $g.FillEllipse($hb, [int]($W * $halo.x - $rr / 2), [int]($H * $halo.y - $rr / 2), $rr, $rr)
            $hb.Dispose()
        }

        # 素材卡片模式：整体再压暗一层，白卡金框才跳得出来
        if ($themeImage -ne "" -and (Test-Path -LiteralPath $themeImage)) {
            # 有素材时整体压暗一层背景，白卡金框与原图才跳得出来
            # （压的是背景渐变，素材图在其之后绘制，不受影响）
            $bDim = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(104, 0, 0, 0))
            $g.FillRectangle($bDim, 0, 0, $W, $H)
            $bDim.Dispose()
        }

        # 整图模式的主图要在顶栏与所有文字之前画，避免压住「程序名 + 断网时间」
        if ($themeImage -ne "" -and (Test-Path -LiteralPath $themeImage) -and $themeMode -eq "full") {
            Draw-FailFullImage $g $W $H $pool $themeImage
        }

        $gold   = [System.Drawing.Color]::FromArgb(232, 200, 112)
        $white  = [System.Drawing.Color]::FromArgb(255, 255, 255)
        $sfNear = New-TextFormat ([System.Drawing.StringAlignment]::Near) ([System.Drawing.StringAlignment]::Near)
        $sfFar  = New-TextFormat ([System.Drawing.StringAlignment]::Far)  ([System.Drawing.StringAlignment]::Near)

        # --- 顶部栏：程序名 + 开发者标志 / 右上是断网时间 ---
        $fsTop  = [int]($H * 0.027)
        $fTop   = New-UiFont $script:fontSans $fsTop ([System.Drawing.FontStyle]::Regular) $pool
        $brTop  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(205, 255, 240, 205))
        $topY   = [int]($H * 0.055)
        $topH   = [int]($H * 0.06)
        $topTxt = "X-file  ·  校园网守护"
        if ($script:devEnabled) { $topTxt += "     " + $script:devShow + "  ·  DEVELOPER MODE" }
        $g.DrawString($topTxt, $fTop, $brTop, (New-Object System.Drawing.RectangleF([int]($W * 0.06), $topY, [int]($W * 0.62), $topH)), $sfNear)
        $stamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        if ($subInfo) { $stamp = $stamp + "   " + $subInfo }
        $g.DrawString($stamp, $fTop, $brTop, (New-Object System.Drawing.RectangleF([int]($W * 0.32), $topY, [int]($W * 0.62), $topH)), $sfFar)

        # --- 主视觉：内置主题大字 / 网络素材卡片（两张轮替）---
        $useCard = ($themeImage -ne "" -and (Test-Path -LiteralPath $themeImage))
        if ($useCard) {
            $cropR = 0.0
            if ($themeCrop -gt 0) { $cropR = [double]$themeCrop }
            # 整图模式的主图已在上面画好，这里只补标题；卡片模式在此装裱（含说明文字）
            if ($themeMode -ne "full") { Draw-FailCard $g $W $H $pool $themeImage $cropR }
            # 卡片模式下主标题压成一行，摆在卡片上方
            $sfH2   = New-TextFormat ([System.Drawing.StringAlignment]::Near) ([System.Drawing.StringAlignment]::Near)
            $fHead2 = New-UiFont $script:fontFancy ([int]($H * 0.066)) ([System.Drawing.FontStyle]::Bold) $pool
            $hx = [int]($W * 0.06); $hy = [int]($H * 0.100)
            $hRect = New-Object System.Drawing.RectangleF($hx, $hy, [int]($W * 0.45), [int]($H * 0.09))
            $e2 = [int]($H * 0.0035)
            $brH2e = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 226, 178, 84))
            foreach ($dx in @(-$e2, 0, $e2)) {
                foreach ($dy in @(-$e2, 0, $e2)) {
                    if ($dx -eq 0 -and $dy -eq 0) { continue }
                    $g.DrawString("臣妾做不到啊", $fHead2, $brH2e,
                        (New-Object System.Drawing.RectangleF(($hx + $dx), ($hy + $dy), [int]($W * 0.45), [int]($H * 0.09))), $sfH2)
                }
            }
            $brH2e.Dispose()
            $brH2 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 255))
            Draw-EmbossedText $g "臣妾做不到啊" $fHead2 $brH2 $hRect $sfH2 ([int]($H * 0.0025))
            $brH2.Dispose()
            $fSub2 = New-UiFont $script:fontFancy ([int]($H * 0.030)) ([System.Drawing.FontStyle]::Regular) $pool
            $brSub2 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(215, 255, 236, 198))
            # 副标题接在主标题右侧同行，避免和下面卡片挤在一起
            $g.DrawString("校园网认证失败 · 连接中断", $fSub2, $brSub2,
                (New-Object System.Drawing.RectangleF([int]($W * 0.305), [int]($H * 0.118), [int]($W * 0.24), [int]($H * 0.05))), $sfH2)
            $brSub2.Dispose()
        } else {
            Draw-FailHero $g $W $H $pool
        }

        # --- 右侧面板：连接失败 + 检查清单 ---
        $px = [int]($W * 0.555); $pw = [int]($W * 0.360)
        $py = [int]($H * 0.255); $ph = [int]($H * 0.520)
        $brPanel = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(104, 10, 5, 16))
        $g.FillRectangle($brPanel, $px, $py, $pw, $ph)
        $brPanel.Dispose()
        $penPanel = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(185, 232, 200, 112), [single]($H * 0.0035))
        $g.DrawRectangle($penPanel, $px, $py, $pw, $ph)
        $penPanel.Dispose()

        $ix = $px + [int]($W * 0.022)
        $iw = $pw - [int]($W * 0.044)
        $iy = $py + [int]($H * 0.032)

        $fHead = New-UiFont $script:fontSans ([int]($H * 0.098)) ([System.Drawing.FontStyle]::Bold) $pool
        $brHead = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 246, 238))
        $g.DrawString("连接失败", $fHead, $brHead, (New-Object System.Drawing.RectangleF($ix, $iy, $iw, [int]($H * 0.13))), $sfNear)
        $brHead.Dispose()

        $iy += [int]($H * 0.135)
        $fEn = New-UiFont $script:fontSans ([int]($H * 0.026)) ([System.Drawing.FontStyle]::Regular) $pool
        $brEn = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200, 255, 214, 214))
        $g.DrawString("CONNECTION FAILED", $fEn, $brEn, (New-Object System.Drawing.RectangleF($ix, $iy, $iw, [int]($H * 0.05))), $sfNear)
        $brEn.Dispose()

        $iy += [int]($H * 0.062)
        $penLine = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 232, 200, 112), [single]($H * 0.0022))
        $g.DrawLine($penLine, $ix, $iy, ($ix + $iw), $iy)
        $penLine.Dispose()

        $iy += [int]($H * 0.028)
        $fChk = New-UiFont $script:fontSans ([int]($H * 0.0335)) ([System.Drawing.FontStyle]::Regular) $pool
        $brChk = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(238, 245, 240, 232))
        $fChkT = New-UiFont $script:fontSans ([int]($H * 0.032)) ([System.Drawing.FontStyle]::Bold) $pool
        $brChkT = New-Object System.Drawing.SolidBrush($gold)
        $g.DrawString("请依次检查：", $fChkT, $brChkT, (New-Object System.Drawing.RectangleF($ix, $iy, $iw, [int]($H * 0.05))), $sfNear)
        $iy += [int]($H * 0.056)

        $checks = @(
            "① 网线 / Wi-Fi 是否已连上",
            "② 账号密码是否正确",
            "③ 认证页面是否已弹出",
            "④ 网卡禁用 / 欠费 / 未认证",
            "⑤ 稍候片刻，臣妾会继续重试"
        )
        $step = [int]($H * 0.055)
        foreach ($c in $checks) {
            $g.DrawString($c, $fChk, $brChk, (New-Object System.Drawing.RectangleF($ix, $iy, $iw, [int]($H * 0.05))), $sfNear)
            $iy += $step
        }
        $brChk.Dispose(); $brChkT.Dispose()

        $fFoot = New-UiFont $script:fontSans ([int]($H * 0.026)) ([System.Drawing.FontStyle]::Regular) $pool
        $brFoot = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(185, 255, 240, 210))
        $g.DrawString("恢复连接后，本壁纸会自动还原为你原来的桌面。", $fFoot, $brFoot,
            (New-Object System.Drawing.RectangleF([int]($W * 0.06), [int]($H * 0.905), [int]($W * 0.60), [int]($H * 0.05))), $sfNear)
        $brFoot.Dispose()

        # --- 右下角开发者角标 ---
        if ($badge) {
            $fBadge = New-UiFont $script:fontSans ([int]($H * 0.046)) ([System.Drawing.FontStyle]::Bold) $pool
            $brBadge = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 236, 96))
            $pad = [int]($W * 0.03)
            $sfBadge = New-TextFormat ([System.Drawing.StringAlignment]::Far) ([System.Drawing.StringAlignment]::Far)
            $g.DrawString($badge, $fBadge, $brBadge,
                (New-Object System.Drawing.RectangleF($pad, $pad, ($W - 2 * $pad), ($H - 2 * $pad))), $sfBadge)
            $brBadge.Dispose()
        }

        $brTop.Dispose()

        # --- 存盘：JPEG q92（体积约 1MB 上下），失败则退回 PNG ---
        $codec = $null
        foreach ($c in [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()) {
            if ($c.MimeType -eq "image/jpeg") { $codec = $c }
        }
        $saved = $false
        foreach ($attempt in @(1, 2)) {
            if ($saved) { break }
            # 上一轮留下的同名文件偶尔被系统占用，先删掉再写
            if ($attempt -eq 2 -and (Test-Path -LiteralPath $file)) {
                try { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue } catch {}
            }
            if ($codec -ne $null) {
                try {
                    $eps = New-Object System.Drawing.Imaging.EncoderParameters(1)
                    $eps.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]92)
                    $bmp.Save($file, $codec, $eps)
                    $eps.Dispose()
                    $saved = $true
                } catch {}
            }
        }
        if (-not $saved) { return $false }   # 存不下来就交给上层退回简版提示图
        return $true
    } catch {
        Log ("WALLPAPER: 4K 失败壁纸生成异常 " + $_.Exception.Message + " @line" + $_.InvocationInfo.ScriptLineNumber) "ERROR"
        return $false
    } finally {
        foreach ($f in $pool) { try { $f.Dispose() } catch {} }
        if ($g -ne $null)   { try { $g.Dispose() }   catch {} }
        if ($bmp -ne $null) { try { $bmp.Dispose() } catch {} }
    }
}

# 当前壁纸路径（注册表）
function Get-CurrentWallpaper {
    try {
        $cur = (Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -ErrorAction Stop).Wallpaper
        if ($cur) { return ([string]$cur).Trim().Trim([char]0xFEFF) }
    } catch {}
    return ""
}

# ---------------- [v2.9.6] 系统主题缓存守卫 ----------------
# Windows 的幻灯片 / 聚焦 / 动态壁纸，其注册表 Wallpaper 值并不指向用户挑的那张图，
# 而是指向 %APPDATA%\Microsoft\Windows\Themes\TranscodedWallpaper 这个"转码缓存"。
# 而任何一次 SPI_SETDESKWALLPAPER 都会让 Windows 重新生成该文件 —— 包括我们自己切红屏。
# 所以：缓存目录里的东西【不能】被当成"用户的原始壁纸"，否则还原= 再设一遍红图。
function Test-SystemWallCache([string]$p) {
    if (-not $p) { return $false }
    try { $p = [System.IO.Path]::GetFullPath($p) } catch {}
    $p = ([string]$p).Trim().TrimEnd('\')
    if (-not $p) { return $false }
    # ① 文件名特征
    if (($p -like "*\Microsoft\Windows\Themes\TranscodedWallpaper") -or
        ($p -like "*\Microsoft\Windows\Themes\Transcoded_*")) { return $true }
    # ② 目录特征：整个主题缓存目录。里面全是 Windows 自己生成/管理的文件
    #    （TranscodedWallpaper / Transcoded_000 / slideshow.ini / TranscodedImageCache…），
    #    没有一张是用户自己挑的图片。
    $th = ""
    try { $th = [System.IO.Path]::GetFullPath($themesDir).TrimEnd('\') } catch {}
    if (-not $th) {   # 兜底：万一 $themesDir 不在作用域内，规则②也不能失效
        try { $th = [System.IO.Path]::GetFullPath((Join-Path $env:APPDATA "Microsoft\Windows\Themes")).TrimEnd('\') } catch {}
    }
    if ($th -and $p.Length -gt $th.Length) {
        if ($p.Substring(0, $th.Length).ToLower() -eq $th.ToLower() -and $p[$th.Length] -eq '\') { return $true }
    }
    return $false
}

# 清掉历史遗留的缓存备份（扩展名按内容嗅探，故用通配）
function Clear-WallpaperBackup {
    try {
        Get-ChildItem -LiteralPath $configDir -Filter "wallpaper_backup.*" -File -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    } catch {}
}

# [v2.9.6] 把系统主题缓存的内容复制到 config 下，供还原时使用。
# 缓存文件本身没有扩展名，这里按文件头嗅探给一个正确后缀（不改内容），
# 避免个别系统对无后缀路径处理异常；认不出的格式就不备份（调用方退回守卫行为）。
function Backup-SystemWallCache($src) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($src)
        if ($bytes.Length -lt 8) { return "" }
        $ext = ""
        if ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) { $ext = ".png" }
        elseif ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) { $ext = ".jpg" }
        elseif ($bytes[0] -eq 0x42 -and $bytes[1] -eq 0x4D) { $ext = ".bmp" }
        if (-not $ext) { return "" }
        Clear-WallpaperBackup
        $dst = Join-Path $configDir ("wallpaper_backup" + $ext)
        [System.IO.File]::WriteAllBytes($dst, $bytes)
        # 记下"这份备份是从哪个系统缓存文件来的"，还原成功后要把内容写回它
        try {
            [System.IO.File]::WriteAllText((Join-Path $configDir "wallpaper_backup.src"), [string]$src,
                                           (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
        return $dst
    } catch { return "" }
}
# 判断某个路径是不是本程序放在 config 下的缓存备份
function Test-IsWallpaperBackup([string]$p) {
    if (-not $p) { return $false }
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { return $false }
    $d = ""; $n = ""; $cd = ""
    try { $d  = [System.IO.Path]::GetDirectoryName($p).TrimEnd('\') } catch {}
    try { $n  = [System.IO.Path]::GetFileName($p) } catch {}
    try { $cd = [System.IO.Path]::GetFullPath($configDir).TrimEnd('\') } catch {}
    if (-not $d -or -not $n) { return $false }
    return (($d.ToLower() -eq $cd.ToLower()) -and $n.ToLower().StartsWith("wallpaper_backup."))
}

# [v2.9.6] 备份只是"临时替身"：还原成功后要把内容写回原来的系统主题缓存文件，
# 并让桌面重新指向缓存文件 —— 否则注册表指向的备份一旦被清理，重启后桌面会变成默认壁纸。
function Restore-BackupToCache($bak) {
    try {
        $srcFile = Join-Path $configDir "wallpaper_backup.src"
        if (-not (Test-Path -LiteralPath $srcFile)) { return }
        $src = [System.IO.File]::ReadAllText($srcFile, [System.Text.Encoding]::UTF8).Trim().Trim([char]0xFEFF)
        if (-not $src) { return }
        $dir = ""
        try { $dir = Split-Path -Parent $src } catch {}
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return }
        [System.IO.File]::WriteAllBytes($src, [System.IO.File]::ReadAllBytes($bak))
        if (ApplyWallpaper $src) {
            Log ("WALLPAPER: 原图已写回系统主题缓存并让桌面指回它 -> " + $src) "INFO"
        } else {
            Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -Value $src -ErrorAction SilentlyContinue
            Log "WALLPAPER: 原图已写回系统主题缓存，但让桌面指回它未成功（当前画面不受影响；若重启后壁纸不对，到 个性化->背景 重选一次即可）" "WARN"
        }
    } catch {
        Log "WALLPAPER: 写回系统主题缓存失败（当前画面不受影响；若重启后壁纸不对，到 个性化->背景 重选一次即可）" "WARN"
    }
}

# 兜底来源：开机早期 Wallpaper 值可能还是空的，而 TranscodedImageCache 已存着上次那张图
function Get-WallpaperFromCache {
    try {
        $b = (Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name TranscodedImageCache -ErrorAction Stop).TranscodedImageCache
        if ($b -eq $null -or $b.Length -lt 32) { return "" }
        $s = [System.Text.Encoding]::Unicode.GetString($b, 24, $b.Length - 24)
        $i = $s.IndexOf([char]0)
        if ($i -ge 0) { $s = $s.Substring(0, $i) }
        $s = $s.Trim().Trim([char]0xFEFF)
        # [v2.9.6] 系统主题缓存不能作为"原图"（其内容会被我们切红屏那一下覆盖）
        if ($s -and (-not (Test-SystemWallCache $s)) -and (Test-Path -LiteralPath $s)) { return $s }
    } catch {}
    return ""
}

function Save-OriginalWallpaper {
    # 首次切换到失败壁纸前记下用户原本的壁纸，否则恢复后用户的壁纸会被永久替换成提示图
    if (Test-Path $origWallFile) { return }
    $cur = Get-CurrentWallpaper
    # 自家生成的提示图不能当成"原始壁纸"存下来
    if ($cur -and ($cur -like "*campus_fail*" -or $cur -like "*campus_ok*")) { $cur = "" }
    if (-not $cur) { $cur = Get-WallpaperFromCache }
    # [v2.9.6] 系统主题缓存：路径确实"存在"，但它的内容会被紧接着的"切红屏"覆盖掉。
    # 直接把它当原图记录，等于还原时把红图再设一遍（永久红屏）——改为在覆盖前备份内容。
    if ($cur -and (Test-SystemWallCache $cur)) {
        $bak = Backup-SystemWallCache $cur
        if ($bak) {
            Log ("WALLPAPER: 原始壁纸是系统主题缓存，已备份其内容 -> " + $bak) "INFO"
            $cur = $bak
        } else {
            Log ("WALLPAPER: 原始壁纸是系统主题缓存且备份失败，不予记录: " + $cur) "WARN"
            $cur = ""
        }
    }
    if ($cur -and (Test-Path -LiteralPath $cur)) {
        try {
            # 必须无 BOM：带 BOM 的路径 Test-Path 会失败，恢复时就只能退回提示图了
            [System.IO.File]::WriteAllText($origWallFile, $cur, (New-Object System.Text.UTF8Encoding($false)))
            Log ("WALLPAPER: 已记录原始壁纸 -> " + $cur) "INFO"
        } catch {}
    } else {
        Log "WALLPAPER: 未能取得原始壁纸路径，恢复时将改用提示图兜底" "WARN"
    }
}

# 失败状态文件：第 1 行 "fail"，第 2 行记录本程序实际应用的红图路径（用于判断当前红屏是不是我们干的）
function Write-FailState($wallPath) {
    try {
        [System.IO.File]::WriteAllLines($stateFile, @("fail", [string]$wallPath), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}
function Get-FailState {
    if (-not (Test-Path $stateFile)) { return $null }
    try {
        $lines = [System.IO.File]::ReadAllLines($stateFile)
        $w = ""
        if ($lines.Length -ge 2) { $w = $lines[1].Trim().Trim([char]0xFEFF) }
        return @{ state = $lines[0].Trim().Trim([char]0xFEFF); wall = $w }
    } catch { return $null }
}
function Clear-FailState {
    foreach ($f in @($stateFile, $origWallFile)) {
        if (Test-Path $f) { try { [System.IO.File]::Delete($f) } catch {} }
    }
    Clear-WallpaperBackup     # [v2.9.6] 还原成功后，缓存备份也就没用了
}
function Has-FailState {
    return ((Test-Path $stateFile) -or (Test-Path $origWallFile))
}

function Restore-OriginalWallpaper {
    # 返回值语义（[v2.9.5] 明确）：
    #   $true  = 桌面已处于正常状态：要么已成功还原，要么本来就不是我们改的、无需处理
    #   $false = 确实需要还原却没做成 -> 调用方【必须保留失败标记】，稍后重试
    # 优先还原用户原本的壁纸
    $orig = $null
    if (Test-Path $origWallFile) {
        try { $orig = [System.IO.File]::ReadAllText($origWallFile).Trim().Trim([char]0xFEFF) } catch {}
    }
    # [v2.9.6] 旧版本可能已经把系统主题缓存写进了记录文件，那时该缓存内容早已被红图覆盖，
    # 按它"还原"就是把红图再设一遍 —— 必须放弃，改走备份 / 绿色提示图兜底。
    if ($orig -and (Test-SystemWallCache $orig)) {
        Log ("WALLPAPER: 记录的原图是系统主题缓存（内容已被失败壁纸覆盖），放弃按它还原: " + $orig) "WARN"
        $orig = $null
    }
    if (-not $orig) { $orig = Get-WallpaperFromCache }
    if ($orig -and (Test-Path -LiteralPath $orig)) {
        if (ApplyWallpaper $orig) {
            Log ("WALLPAPER: 已还原为原始壁纸 -> " + $orig) "INFO"
            # 用的是缓存备份：把内容写回系统缓存并让桌面指回它，之后才能安全清理备份
            if (Test-IsWallpaperBackup $orig) { Restore-BackupToCache $orig }
            return $true
        }
        Log ("WALLPAPER: 应用原始壁纸未成功（文件在但设置没生效）-> 保留失败标记，稍后重试: " + $orig) "WARN"
    } elseif ($orig) {
        Log ("WALLPAPER: 记录的原始壁纸文件已不存在 -> 改用恢复提示图: " + $orig) "WARN"
    }
    # 没有原始壁纸记录时，只有在确认当前桌面确实是我们自己那张红图的前提下才顶掉它；
    # 否则宁可不动——把用户自己换的壁纸覆盖成绿色提示图是没法撤销的。
    $mine = ""
    $fs = Get-FailState
    if ($fs -and $fs.wall) { $mine = $fs.wall }
    $cur = Get-CurrentWallpaper
    $isMine = $false
    if ($mine -and $cur -and ($cur -eq $mine)) { $isMine = $true }
    if ((-not $mine) -and $cur -and ($cur -like "*campus_*")) { $isMine = $true }   # 旧版本留下的红图
    if (-not $isMine) {
        Log "WALLPAPER: 无原始壁纸记录且当前壁纸并非本程序设置 -> 保持不动" "WARN"
        return $true
    }
    $tmp = Join-Path $env:TEMP "campus_ok.bmp"
    if (MakeWallpaper $tmp @(30, 130, 70) "校园网已恢复连接" $script:devWallBadge) {
        if (ApplyWallpaper $tmp) {
            Log "WALLPAPER: 已切换为【已恢复】壁纸（未找到原始壁纸）" "INFO"
            return $true
        }
        Log "WALLPAPER: 恢复提示图应用未成功 -> 保留失败标记，稍后重试" "WARN"
    } else {
        Log "WALLPAPER: 恢复提示图生成失败 -> 保留失败标记，稍后重试" "WARN"
    }
    return $false
}

function SetFailWallpaper {
    if (-not $script:notifyWallpaper) { return }
    if (IsStartupGrace) {
        # 刚开机，网卡/拨号多半还没就绪。此时红屏基本都是误报，等过了宽限期再判断。
        $left = [int]($script:startupGraceSec - ((Get-Date) - $script:startTime).TotalSeconds)
        Log ("WALLPAPER: 开机宽限期内（剩 " + $left + "s），暂不切换失败壁纸") "INFO"
        return
    }
    if (IsMutedNow) {                   # 免打扰时段：只在日志里记一笔，不动桌面
        Save-OriginalWallpaper          # 此刻桌面还是原图，正是记录原壁纸的好时机
        Write-FailState ""
        Log "WALLPAPER: 免打扰时段，已跳过失败壁纸（仅记录状态）" "INFO"
        return
    }
    Save-OriginalWallpaper
    # 开发者标志开启时改用紫色并叠加角标，与生产环境的红色一眼区分
    $rgb   = @(190, 40, 40)
    $badge = ""
    if ($script:devEnabled -and $script:devMarkWall) { $rgb = @(88, 44, 138); $badge = $script:devWallBadge }
    $info = ""
    if ($script:failStreak -gt 0) { $info = "连续失败 " + $script:failStreak + " 次" }
    # 主题轮替：内置渐变主题图（0 号）与 assets\theme_*.jpg 网络素材（1..N 号）轮流使用
    $themes   = @(Get-WallThemes)
    $themeImg = ""
    $cropR    = 0.0
    $themeMode = "card"
    $themeTag = "内置主题图"
    if ($themes.Count -gt 0) {
        $idx = Get-NextWallIndex ($themes.Count + 1)
        if ($idx -gt 0 -and $idx -le $themes.Count) {
            $themeImg  = $themes[$idx - 1]
            $cropR     = Get-ThemeCrop $themeImg
            $themeMode = Get-ThemeMode $themeImg      # theme_full_* 全屏铺底，其余卡片装裱
            $leaf      = Split-Path $themeImg -Leaf
            if ($themeMode -eq "full") { $themeTag = "自定义壁纸（整图居中）" + $leaf }
            else                       { $themeTag = "素材卡片 " + $leaf }
        }
    }
    # 4K 主题壁纸（臣妾做不到 + 连接失败检查清单）；生成失败时退回简版提示图
    $tmp = Join-Path $env:TEMP "campus_fail.jpg"
    if (-not (MakeFailWallpaper $tmp $rgb $badge $info $themeImg $cropR $themeMode)) {
        $tmp = Join-Path $env:TEMP "campus_fail.bmp"
        if (-not (MakeWallpaper $tmp $rgb "校园网连接失败`n请检查网络或账号密码" $badge)) { $tmp = "" }
    }
    if ($tmp -ne "") {
        if (ApplyWallpaper $tmp) {
            Write-FailState $tmp         # 记下失败壁纸路径，恢复时用来确认"红屏确实是我们干的"
            Log ("WALLPAPER: 已切换为【失败】壁纸（" + $themeTag + "，4K，共 " + ($themes.Count + 1) + " 张轮替）") "WARN"
        }
    }
    Show-Toast "校园网连接失败" "请检查网络或账号密码"
}

function SetOkWallpaper {
    # 返回值：$true = 桌面已确认回到正常状态（失败标记已清）
    #         $false = 还原没做成（失败标记保留，稍后重试）
    # [v2.9.5] 以前这里是无条件 Clear-FailState：万一"还原"这一步本身失败（原壁纸文件被删、
    # 恢复提示图生成或应用失败），标记照样被清掉，之后所有自愈点都认为"没有失败态"，
    # 红屏就永久留在桌面上、再也不会重试 —— 这是壁纸卡住那个历史 bug 的残余缺口。
    if (-not $script:notifyWallpaper) { Clear-FailState; return $true }   # 关闭壁纸提示时只清标记，不动桌面
    if ($null -eq $script:nextRestoreAt) { $script:nextRestoreAt = [datetime]::MinValue }
    if ($null -eq $script:restoreFail)   { $script:restoreFail = 0 }
    if ((Get-Date) -lt $script:nextRestoreAt) { return $false }   # 上次还原失败后的 60s 冷却期内不重复尝试
    if (Restore-OriginalWallpaper) {
        $script:restoreFail   = 0
        $script:nextRestoreAt = [datetime]::MinValue
        Show-Toast "校园网已恢复" "连接已重新建立"
        Clear-FailState
        return $true
    }
    # 还原没成功：保留两个状态文件，60s 后由各个自愈点继续重试；不弹"已恢复"通知，避免反复打扰
    $script:restoreFail = [int]$script:restoreFail + 1
    $script:nextRestoreAt = (Get-Date).AddSeconds(60)
    Log ("WALLPAPER: 还原动作未成功（第 " + $script:restoreFail + " 次），保留失败标记，60s 后重试；若长期如此可双击 还原壁纸.bat 手动处理") "WARN"
    return $false
}

# 壁纸状态自愈：只要还留着失败标记，就在每个循环点检查网络是否已恢复，
# 恢复则立刻还原。以前只在"登录成功"这条路径上还原，于是网络自己恢复、
# 或冷却/探测跳过登录时，红屏会一直挂在桌面上。
function Sync-FailWallpaper {
    param([string]$NetState = "")        # "up"=已知网络通 / "down"=已知断 / ""=自行探测
    if (-not (Has-FailState)) { return }
    # 还原失败后的冷却期内直接跳过：否则每个循环点都会重复打一遍同样的日志
    if ($script:nextRestoreAt -and ((Get-Date) -lt $script:nextRestoreAt)) { return }
    $ok = $false
    if ($NetState -eq "up")        { $ok = $true }
    elseif ($NetState -eq "down")  { return }
    else                           { $ok = IsNetworkOK }
    if ($ok) {
        Log "WALLPAPER: 网络已恢复但仍留有失败标记 -> 立即还原壁纸" "INFO"
        SetOkWallpaper | Out-Null
    }
}

# ---------------- 网络与会话检测 ----------------
function IsNetworkOK {
    foreach ($t in $pingTargets) {
        try {
            $proc = Start-Process -FilePath "ping.exe" -ArgumentList @("-n", "$pingCount", "-w", "$pingTimeoutMs", $t) -PassThru -WindowStyle Hidden -ErrorAction Stop
            # 用退出码判断，不再解析 "TTL=" 文案：兼容 IPv6 与非中文系统
            if ($proc.WaitForExit(15000)) {
                if ($proc.ExitCode -eq 0) { return $true }
            } else {
                try { $proc.Kill() } catch {}
            }
        } catch {
            try { if (Test-Connection -ComputerName $t -Count 1 -Quiet -ErrorAction Stop) { return $true } } catch {}
        }
    }
    return $false
}

function Test-SessionAlive {
    # 返回 $true 表示"确认会话有效，可以跳过本次重登"
    # 任何异常或非 2xx 状态码都返回 $false —— 保守地执行登录，宁可多登一次也不掉线
    try {
        $req = [System.Net.HttpWebRequest]::Create($probeUrl)
        $req.AllowAutoRedirect = $false
        $req.Timeout = $probeTimeoutMs
        $req.ReadWriteTimeout = $probeTimeoutMs
        $req.Method = "GET"
        $req.UserAgent = "Xfile-Monitor/2.0"
        $resp = $null
        try {
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $loc = ""
            try { $loc = $resp.Headers["Location"] } catch {}
            if ($code -ge 200 -and $code -lt 300) { return $true }
            Log ("PROBE: HTTP " + $code + " Location=" + $loc + " -> 判定会话失效") "WARN"
            return $false
        } finally {
            if ($resp -ne $null) { try { $resp.Close() } catch {} }
        }
    } catch {
        Log ("PROBE: 探测异常，保守执行登录: " + $_.Exception.Message) "WARN"
        return $false
    }
}

# ---------------- 临时解压目录清理（默认关闭，可在 config\monitor_settings.json 开启）----------------
function Cleanup-MeItemp {
    if (-not $cleanTempMei) { return }
    try {
        # 既清理 PyInstaller 原生 _MEI*，也清理上次因被占用而改名待删的 _MEI_delete_me_*
        $dirs = @(Get-ChildItem -Path $env:TEMP -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "_MEI*" -or $_.Name -like "_MEI_delete_me_*" })
        foreach ($d in $dirs) {
            if (((Get-Date) - $d.LastWriteTime).TotalHours -lt $tempMeiMaxAgeHours) { continue }
            # 仅清理确实属于本程序 exe 的解压目录，避免误删其它 PyInstaller 程序
            if (-not (Test-Path (Join-Path $d.FullName "ddddocr"))) { continue }
            try {
                Remove-Item -Path $d.FullName -Recurse -Force -ErrorAction Stop
                Log ("CLEANUP: 已清理残留解压目录 " + $d.Name) "INFO"
            } catch {
                # 文件被独占占用时无法删除：改名隔离，避免下次运行继续累积，重启后再由本函数清掉
                try {
                    $newName = "_MEI_delete_me_" + (Get-Date -Format "yyyyMMdd_HHmmss")
                    Rename-Item -Path $d.FullName -NewName $newName -ErrorAction Stop
                    Log ("CLEANUP: 目录被占用，已改名隔离 " + $d.Name + " -> " + $newName) "WARN"
                } catch {
                    Log ("CLEANUP: 清理失败 " + $d.Name + " : " + $_.Exception.Message) "WARN"
                }
            }
        }
    } catch {}
}

# ---------------- 过期文件清理与归档（分层后新增）----------------
# 1) exe 会把截图与 login_steps.log 写在 bin\（它的 BASE_DIR），这里归档到 shots\ / logs\
# 2) 按保留天数删除过期截图
# 3) 按保留天数删除过期日志与临时壁纸文件
function Invoke-Retention {
    $now = Get-Date
    $cl = GetCfg $settings "cleanup" $null
    try {
        # --- 归档 bin\ 下由 exe 产出的截图 ---
        $shotKeepDays = [double](GetCfg $cl "shots_keep_days" 7)
        $pngs = @(Get-ChildItem -Path $binDir -Filter "*.png" -File -ErrorAction SilentlyContinue)
        foreach ($f in $pngs) {
            try {
                $dst = Join-Path $shotDir $f.Name
                Move-Item -Path $f.FullName -Destination $dst -Force -ErrorAction Stop
            } catch {}
        }
        if ($pngs.Count -gt 0) { Log ("CLEANUP: 归档 " + $pngs.Count + " 张截图 -> shots\") "INFO" }

        # --- 归档 exe 写在 bin\ 的 login_steps.log ---
        $srcSteps = Join-Path $binDir "login_steps.log"
        $dstSteps = Join-Path $logDir "login_steps.log"
        if (Test-Path $srcSteps) {
            try {
                $content = Get-Content -Path $srcSteps -Raw -Encoding UTF8 -ErrorAction Stop
                Add-Content -Path $dstSteps -Value $content -Encoding UTF8 -ErrorAction Stop
                Remove-Item -Path $srcSteps -Force -ErrorAction Stop
            } catch {}
        }

        # --- login_steps.log 大小封顶 ---
        # 这个文件是每次登录都往末尾追加的，mtime 永远是最新的，
        # 只靠 logs_keep_days（按 mtime 判断）永远轮不到它，必须单独按体积截断。
        $stepsMax = [double](GetCfg $cl "login_steps_max_bytes" 1048576)
        if ((Test-Path $dstSteps) -and ((Get-Item $dstSteps).Length -gt $stepsMax)) {
            $keepLines = [int](GetCfg $cl "login_steps_keep_lines" 400)
            try {
                $lines = @(Get-Content -Path $dstSteps -Encoding UTF8)
                if ($lines.Count -gt $keepLines) {
                    $tail = @($lines[($lines.Count - $keepLines) .. ($lines.Count - 1)])
                    [System.IO.File]::WriteAllLines($dstSteps, $tail, (New-Object System.Text.UTF8Encoding($false)))
                    Log ("CLEANUP: login_steps.log 超过 " + [math]::Round($stepsMax / 1MB, 2) + " MB，已截断为末尾 " + $keepLines + " 行") "INFO"
                }
            } catch {}
        }

        # --- 删除过期截图 ---
        if ($shotKeepDays -gt 0) {
            $oldPng = @(Get-ChildItem -Path $shotDir -Filter "*.png" -File -ErrorAction SilentlyContinue |
                        Where-Object { ($now - $_.LastWriteTime).TotalDays -gt $shotKeepDays })
            foreach ($f in $oldPng) {
                try { Remove-Item -Path $f.FullName -Force -ErrorAction Stop } catch {}
            }
            if ($oldPng.Count -gt 0) { Log ("CLEANUP: 删除过期截图 " + $oldPng.Count + " 张（>" + $shotKeepDays + "天）") "INFO" }
        }

        # --- 截图数量封顶：只按天数不够，一天内反复重连也会堆出上百张 ---
        $shotMaxFiles = [int](GetCfg $cl "shots_max_files" 40)
        if ($shotMaxFiles -gt 0) {
            $allPng = @(Get-ChildItem -Path $shotDir -Filter "*.png" -File -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime)
            if ($allPng.Count -gt $shotMaxFiles) {
                $del = @($allPng[0 .. ($allPng.Count - $shotMaxFiles - 1)])
                foreach ($f in $del) { try { Remove-Item -Path $f.FullName -Force -ErrorAction Stop } catch {} }
                if ($del.Count -gt 0) { Log ("CLEANUP: 截图超过 " + $shotMaxFiles + " 张上限，删除最旧的 " + $del.Count + " 张") "INFO" }
            }
        }

        # --- 删除过期日志（含轮转副本）---
        $logKeepDays = [double](GetCfg $cl "logs_keep_days" 30)
        if ($logKeepDays -gt 0) {
            $oldLog = @(Get-ChildItem -Path $logDir -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like "*.log*" -and ($now - $_.LastWriteTime).TotalDays -gt $logKeepDays })
            foreach ($f in $oldLog) {
                try { Remove-Item -Path $f.FullName -Force -ErrorAction Stop } catch {}
            }
            if ($oldLog.Count -gt 0) { Log ("CLEANUP: 删除过期日志 " + $oldLog.Count + " 个（>" + $logKeepDays + "天）") "INFO" }
        }

        # --- 清理 %TEMP% 下的临时壁纸位图 ---
        # 4K 主题壁纸是 jpg，简版兜底是 bmp，一并回收
        $tmpBmps = @(Get-ChildItem -Path $env:TEMP -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like "campus_*" -and @(".bmp", ".jpg", ".png") -contains $_.Extension.ToLower() })
        foreach ($f in $tmpBmps) { try { Remove-Item -Path $f.FullName -Force -ErrorAction Stop } catch {} }

        # --- exe 残留解压目录（跟随 cleanup.temp_mei 开关）---
        Cleanup-MeItemp

        try { Set-Content -Path $retentionFile -Value ($now.ToString("yyyy-MM-dd HH:mm:ss")) -Encoding UTF8 } catch {}
    } catch {
        Log ("CLEANUP: 清理过程异常: " + $_.Exception.Message) "WARN"
    }
}

function Should-RunRetention {
    $cl = GetCfg $settings "cleanup" $null
    $intervalH = [double](GetCfg $cl "interval_hours" 24)
    if (-not (Test-Path $retentionFile)) { return $true }
    try {
        $last = Get-Content -Path $retentionFile -Raw -Encoding UTF8
        $lastDt = [datetime]::Parse($last.Trim())
        return (((Get-Date) - $lastDt).TotalHours -ge $intervalH)
    } catch { return $true }
}

# ---------------- 登录 ----------------
function HideEdge($exeStart) {
    if (-not $script:HasWin32) { return }
    try {
        $edges = Get-Process msedge -ErrorAction SilentlyContinue |
                 Where-Object { $_.StartTime -gt $exeStart -and $_.MainWindowHandle -ne 0 }
        foreach ($p in $edges) { [NetWin]::ShowWindow($p.MainWindowHandle, 0) | Out-Null }
    } catch {}
}

function IsBackgroundNow {
    $h = (Get-Date).Hour
    return ($h -ge $script:bgStartH -and $h -lt $script:bgEndH)
}

# 开机宽限期：监控进程刚启动的头 N 秒。
# 此时网卡驱动、WLAN 关联、拨号往往还没就绪，ping 全失败是常态，
# 若据此立刻切红色失败壁纸，就是用户看到的「一开机就红屏」。
function IsStartupGrace {
    if ($script:startupGraceSec -le 0) { return $false }
    $elapsed = ((Get-Date) - $script:startTime).TotalSeconds
    if ($elapsed -ge $script:startupGraceSec) {
        if (-not $script:graceEnded) {
            $script:graceEnded = $true
            Log ("GRACE: 开机宽限期结束（" + $script:startupGraceSec + "s），此后网络不通将按正常流程提示") "INFO"
        }
        return $false
    }
    return $true
}

# 免打扰时段判定（支持跨午夜，精确到分钟）。
# start==end 视为不生效，避免手滑配成 00:00-00:00 后全天免打扰。
function IsQuietNow {
    if (-not $script:quietEnabled) { return $false }
    $s = [int]$script:quietStartMin
    $e = [int]$script:quietEndMin
    if ($s -eq $e) { return $false }
    $n = (Get-Date).Hour * 60 + (Get-Date).Minute
    if ($s -lt $e) { return ($n -ge $s -and $n -lt $e) }
    return ($n -ge $s -or $n -lt $e)     # 跨午夜，如 23:00-07:00
}

# 免打扰时段内是否要静音（不弹通知、不换壁纸）
function IsMutedNow {
    return ($script:quietMuteNotify -and (IsQuietNow))
}

function InvokeLogin {
    if (-not (Test-Path $exe)) {
        Log ("LOGIN: 登录程序不存在，跳过: " + $exe) "ERROR"
        return $false
    }
    # 免打扰时段一律走后台静默，绝不把登录窗口顶到前台
    $bg   = (IsBackgroundNow) -or (IsQuietNow)
    $mode = if ($bg) { "后台" } else { "弹出" }
    Log ("LOGIN: 启动 CampusNetLogin.exe (mode=" + $mode + ")") "INFO"
    $exeStart = Get-Date
    $style = if ($bg) { "Hidden" } else { "Normal" }
    $p = $null
    try {
        $p = Start-Process -FilePath $exe -ArgumentList "--auto" -WindowStyle $style -WorkingDirectory $binDir -PassThru -ErrorAction Stop
    } catch {
        Log ("LOGIN: 启动失败 " + $_.Exception.Message) "ERROR"
        return $false
    }

    if ($p -ne $null) {
        $deadline = (Get-Date).AddMilliseconds($exeWaitMs)
        $lastHide = Get-Date
        $lastHb   = Get-Date
        while ($true) {
            Start-Sleep -Seconds 2
            # 登录可能耗时数分钟，期间持续刷新心跳，避免被新实例误判为僵死
            if (((Get-Date) - $lastHb).TotalSeconds -ge 30) { Write-Hb; $lastHb = Get-Date }
            $hasExited = $false
            try { $hasExited = $p.HasExited } catch { $hasExited = $true }
            if ($hasExited) { break }
            if ($bg -and (((Get-Date) - $lastHide).TotalSeconds -ge $script:hideEdgeIntervalSec)) {
                HideEdge $exeStart
                $lastHide = Get-Date
            }
            if ((Get-Date) -ge $deadline) {
                Log "LOGIN: exe 超时未退出" "WARN"
                if ($killExeOnTimeout) {
                    try {
                        if (-not $p.HasExited) {
                            if ($killExeTree) {
                                Start-Process -FilePath "taskkill.exe" -ArgumentList @("/PID", "$($p.Id)", "/T", "/F") -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
                                Log ("LOGIN: 已终止进程树 PID=" + $p.Id) "WARN"
                            } else {
                                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                                Log ("LOGIN: 已终止进程 PID=" + $p.Id) "WARN"
                            }
                        }
                    } catch {
                        Log ("LOGIN: 终止进程失败 " + $_.Exception.Message) "WARN"
                    }
                }
                Cleanup-MeItemp
                break
            }
        }
        if ($bg) { HideEdge $exeStart }
    }

    Start-Sleep -Seconds 5
    $script:lastLoginTime = Get-Date
    $ok = IsNetworkOK
    if ($ok) {
        Log "LOGIN: 网络已恢复（成功）" "INFO"
        # [修复] 恢复不再受后台时段限制：否则夜间失败后红色壁纸会一直留到次日早上
        if (Has-FailState) { SetOkWallpaper }
        else { Log "LOGIN: 成功且此前未失败 -> 无动作" "INFO" }
    } else {
        Log "LOGIN: 网络仍未恢复（失败）" "WARN"
        SetFailWallpaper
    }
    return $ok
}

# ---------------- 可响应手动标志的睡眠 ----------------
function Sleep-WithFlags($seconds) {
    $left = [int]$seconds
    $hbTick = Get-Date
    while ($left -gt 0) {
        $step = [Math]::Min(10, $left)
        Start-Sleep -Seconds $step
        $left -= $step
        if (((Get-Date) - $hbTick).TotalSeconds -ge 60) { Write-Hb; $hbTick = Get-Date }
        if ((Test-Path $reconnectFile) -or (Test-Path $pauseFile)) { return }
    }
}

# ---------------- 主循环 ----------------
Cleanup-MeItemp
Log "MODE: 监控开始" "INFO"

# 启动自检：上次留下【失败】红屏，而这次开机网络其实是通的 -> 立刻还原。
# 刚开机时网卡往往还没就绪，所以不能只 ping 一次就放弃，要等一小会儿（最多 60s）。
if (Test-Path $stateFile) {
    $waitMax = [Math]::Min($script:startupGraceSec, 60)
    if ($waitMax -lt 10) { $waitMax = 10 }
    $deadline = (Get-Date).AddSeconds($waitMax)
    $restored = $false
    while ((Get-Date) -lt $deadline) {
        if (IsNetworkOK) {
            Log "INIT: 检测到遗留的失败标记但网络已恢复 -> 还原壁纸" "INFO"
            $restored = [bool](SetOkWallpaper)   # [v2.9.5] 以真实结果为准：还原失败要留给主循环重试
            break
        }
        Start-Sleep -Seconds 10
    }
    if (-not $restored) {
        Log ("INIT: 遗留失败标记未解除（网络未通或还原未成功）-> 保持失败壁纸，交由主循环处理") "WARN"
    }
} elseif (Test-Path $origWallFile) {
    # 没有失败标记却留着原始壁纸记录：状态不一致，清掉即可（壁纸并不在失败态）
    try { [System.IO.File]::Delete($origWallFile) } catch {}
    Clear-WallpaperBackup     # [v2.9.6]
}
$lastProbe     = [datetime]::MinValue
$lastHeartbeat = [datetime]::MinValue
$nextLoginAt   = [datetime]::MinValue

while ($true) {
    Write-Hb
    # 手动重连（也可由 设置账号密码.ps1 保存成功后自动触发）
    if (Test-Path $reconnectFile) {
        try { Remove-Item $reconnectFile -Force -ErrorAction Stop } catch {}
        Log "MANUAL: 收到立即重连请求" "INFO"
        # [v2.9.4] 手动重连 = 人明确要求"现在就用最新配置试一次"：把退避/冷却节奏一并归零。
        # 否则 failStreak 仍带着旧计数往下走，密码填错后改成对的，最坏要等满 60 分钟冷却才重试。
        # （本分支在退避判断之前，所以归零后这次登录必定立即执行。）
        if ($script:failStreak -ne 0) {
            Log ("MANUAL: 重试节奏归零（此前连续失败 " + $script:failStreak + " 次）") "INFO"
        }
        $script:failStreak = 0
        $nextLoginAt = [datetime]::MinValue
        InvokeLogin
        $lastProbe = Get-Date
        Start-Sleep -Seconds $retryAfterSec
        continue
    }

    # 暂停
    if (Test-Path $pauseFile) {
        if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $heartbeatSec) {
            Log "PAUSE: 已暂停自动登录（删除 pause.flag 即可恢复）" "INFO"
            $lastHeartbeat = Get-Date
        }
        if (Has-FailState) { Sync-FailWallpaper }   # 暂停期间网络恢复也要把红屏撤掉
        Sleep-WithFlags $pingIntervalSec
        continue
    }

    # 定期清理：归档截图/日志、删除过期文件、回收 exe 残留解压目录
    if (Should-RunRetention) { Invoke-Retention }

    # 免打扰时段：跳过自动登录。手动重连在循环最前面已处理，所以 立即重连.bat 依然有效。
    if ((IsQuietNow) -and $script:quietSkipLogin) {
        if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $heartbeatSec) {
            Log ("QUIET: 免打扰时段 " + $script:quietLabel + "，跳过自动登录（立即重连.bat 仍可用）") "INFO"
            $lastHeartbeat = Get-Date
        }
        # 免打扰期间红屏本身就是打扰：网络一恢复就静默撤掉（不弹通知）
        if (Has-FailState) { Sync-FailWallpaper }
        Sleep-WithFlags $pingIntervalSec
        continue
    }

    $netOK = IsNetworkOK

    if ($netOK) {
        Sync-FailWallpaper "up"          # 网络正常 -> 有失败标记就立刻还原，不等下次登录
        if ($script:failStreak -ne 0) { Log ("RECOVER: 网络恢复，连续失败计数归零（曾失败 " + $script:failStreak + " 次）") "INFO" }
        $script:failStreak = 0
        $nextLoginAt = [datetime]::MinValue

        $dueForce = (((Get-Date) - $script:lastLoginTime).TotalHours -ge $forceReloginHours)
        $dueProbe = ($lastProbe -eq [datetime]::MinValue) -or (((Get-Date) - $lastProbe).TotalSeconds -ge $probeIntervalSec)

        if ($dueForce) {
            Log ("FULL: 距上次登录已超过 " + $forceReloginHours + "h，执行保活登录") "INFO"
            InvokeLogin
            $lastProbe = Get-Date
        } elseif ($dueProbe) {
            if ($probeEnabled -and (Test-SessionAlive)) {
                Log "PROBE: 会话有效，跳过本次重登" "INFO"
                $lastProbe = Get-Date
            } else {
                Log "PROBE: 会话失效或探测不可用，执行登录" "WARN"
                InvokeLogin
                $lastProbe = Get-Date
            }
        } else {
            if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $heartbeatSec) {
                $left = [int]($probeIntervalSec - ((Get-Date) - $lastProbe).TotalSeconds)
                Log ("OK: 网络正常，下次会话探测剩 " + $left + "s") "INFO"
                $lastHeartbeat = Get-Date
            }
        }
    } else {
        $grace = IsStartupGrace
        if (((Get-Date) -lt $nextLoginAt) -and -not $grace) {
            $wait = [int](($nextLoginAt - (Get-Date)).TotalSeconds)
            Log ("BACKOFF: 退避中，" + $wait + "s 后再试（连续失败 " + $script:failStreak + " 次）") "WARN"
        } else {
            if ($grace) { Log "ALERT: 网络异常（开机宽限期内），立即尝试登录" "WARN" }
            else        { Log "ALERT: 网络异常，尝试登录" "WARN" }
            $ok = InvokeLogin
            $lastProbe = Get-Date
            if ($ok) {
                $script:failStreak = 0
                $nextLoginAt = [datetime]::MinValue
            } elseif ($grace) {
                # 宽限期内的失败大概率只是网卡还没就绪：不计入失败次数、不进冷却，快速重试
                $left = [int]($script:startupGraceSec - ((Get-Date) - $script:startTime).TotalSeconds)
                Log ("GRACE: 本次未成功，宽限期内不计数，剩 " + $left + "s，" + $script:startupRetrySec + "s 后重试") "WARN"
                $nextLoginAt = (Get-Date).AddSeconds($script:startupRetrySec)
            } else {
                $script:failStreak++
                if ($script:failStreak -ge $coolThreshold) {
                    $delay = $cooldownMinutes * 60
                    Log ("COOLDOWN: 连续失败 " + $script:failStreak + " 次，进入冷却，" + $cooldownMinutes + " 分钟后再试") "ERROR"
                } else {
                    $delay = [Math]::Min($backoffBase * [Math]::Pow(2, $script:failStreak - 1), $backoffMax)
                    Log ("BACKOFF: 连续失败 " + $script:failStreak + " 次，" + [int]$delay + "s 后再试") "WARN"
                }
                $nextLoginAt = (Get-Date).AddSeconds($delay)
            }
            if ($grace) { Start-Sleep -Seconds $script:startupRetrySec }
            else        { Start-Sleep -Seconds $retryAfterSec }
        }
    }

    if (IsStartupGrace) { Sleep-WithFlags $script:startupRetrySec }
    else                { Sleep-WithFlags $pingIntervalSec }
}
