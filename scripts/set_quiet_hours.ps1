# set_quiet_hours.ps1 - 自定义免打扰时段 / 后台静默时段（X-file）v2.3.0
#
# 交互修改 config\monitor_settings.json 里的：
#   quiet_hours        免打扰时段（默认 23:00-07:00）
#   background_window  后台静默时段（默认 07:00-23:00）
# 也支持非交互调用：
#   powershell -File set_quiet_hours.ps1 -Start 23:30 -End 07:30
#   powershell -File set_quiet_hours.ps1 -Disable
#   powershell -File set_quiet_hours.ps1 -SkipLogin $true

param(
    [string]$Start,          # 免打扰开始，如 23:30
    [string]$End,            # 免打扰结束，如 07:00
    [switch]$Disable,        # 关闭免打扰
    [switch]$Enable,         # 开启免打扰
    [Nullable[bool]]$SkipLogin,   # 免打扰时段是否完全停止自动登录
    [switch]$NoRestart       # 改完不重启监控
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir   = Split-Path -Parent $scriptDir
$configDir = Join-Path $rootDir "config"
$settingsPath = Join-Path $configDir "monitor_settings.json"

function Say($m)  { Write-Host $m }
function OK($m)   { Write-Host ("  [正常] " + $m) -ForegroundColor Green }
function Bad($m)  { Write-Host ("  [异常] " + $m) -ForegroundColor Red }
function Warn($m) { Write-Host ("  [提示] " + $m) -ForegroundColor Yellow }

# 解析 "HH:mm"，非法返回 $null
function Parse-Hm($s) {
    if ($s -eq $null) { return $null }
    $t = ([string]$s).Trim()
    if ($t -match '^(\d{1,2}):(\d{1,2})$') {
        $h = [int]$Matches[1]; $m = [int]$Matches[2]
        if ($h -ge 0 -and $h -le 23 -and $m -ge 0 -and $m -le 59) {
            return ("{0:D2}:{1:D2}" -f $h, $m)
        }
    }
    if ($t -match '^(\d{1,2})$') {
        $h = [int]$Matches[1]
        if ($h -ge 0 -and $h -le 23) { return ("{0:D2}:00" -f $h) }
    }
    return $null
}

# 只替换指定 JSON 块里的某个键值，保留原有排版与注释（ConvertTo-Json 会把缩进搞得很乱）
function Set-JsonBlockValue([string]$text, [string]$block, [string]$key, [string]$val) {
    $bi = $text.IndexOf('"' + $block + '"')
    if ($bi -lt 0) { return $null }
    $ob = $text.IndexOf('{', $bi)
    if ($ob -lt 0) { return $null }
    $depth = 0; $inStr = $false; $end = -1
    for ($i = $ob; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($inStr) {
            if ($c -eq '\') { $i++; continue }     # 跳过转义
            if ($c -eq '"') { $inStr = $false }
            continue
        }
        if ($c -eq '"') { $inStr = $true; continue }
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
    }
    if ($end -lt 0) { return $null }
    $inner    = $text.Substring($ob + 1, $end - $ob - 1)
    $pattern  = '"' + $key + '"\s*:\s*(true|false|"[^"]*"|-?\d+(?:\.\d+)?)'
    if ($inner -match $pattern) {
        $newInner = [regex]::Replace($inner, $pattern, ('"' + $key + '": ' + $val), 1)
    } else {
        $newInner = "`n        `"" + $key + "`": " + $val + "," + $inner
    }
    return ($text.Substring(0, $ob + 1) + $newInner + $text.Substring($end))
}

Say ""
Say "========================================"
Say "  免打扰时段设置 (X-file)"
Say "========================================"

if (-not (Test-Path $settingsPath)) {
    Bad ("未找到 " + $settingsPath)
    Say ""
    exit 1
}

# 读配置（json 不能带 BOM，这里按 UTF8 无 BOM 读取）
$raw = [System.IO.File]::ReadAllText($settingsPath, (New-Object System.Text.UTF8Encoding($false)))
try { $cfg = $raw | ConvertFrom-Json } catch { Bad ("配置解析失败: " + $_.Exception.Message); exit 1 }

if ($cfg.PSObject.Properties['quiet_hours'] -eq $null) {
    $cfg | Add-Member -NotePropertyName 'quiet_hours' -NotePropertyValue ([pscustomobject]@{
        enabled = $true; start = "23:00"; end = "07:00"; skip_auto_login = $false; mute_notify = $true
    })
}
if ($cfg.PSObject.Properties['background_window'] -eq $null) {
    $cfg | Add-Member -NotePropertyName 'background_window' -NotePropertyValue ([pscustomobject]@{ start = "07:00"; end = "23:00" })
}

$qh = $cfg.quiet_hours
$bw = $cfg.background_window
if ($qh.PSObject.Properties['enabled'] -eq $null)         { $qh | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $true }
if ($qh.PSObject.Properties['skip_auto_login'] -eq $null) { $qh | Add-Member -NotePropertyName 'skip_auto_login' -NotePropertyValue $false }
if ($qh.PSObject.Properties['mute_notify'] -eq $null)     { $qh | Add-Member -NotePropertyName 'mute_notify' -NotePropertyValue $true }

$qStart = Parse-Hm $qh.start; if (-not $qStart) { $qStart = "23:00" }
$qEnd   = Parse-Hm $qh.end;   if (-not $qEnd)   { $qEnd   = "07:00" }
$bStart = Parse-Hm $bw.start; if (-not $bStart) { $bStart = "07:00" }
$bEnd   = Parse-Hm $bw.end;   if (-not $bEnd)   { $bEnd   = "23:00" }

$changed = $false

# ---------- 非交互模式 ----------
if ($Start -or $End -or $Disable -or $Enable -or ($SkipLogin -ne $null)) {
    if ($Start)  { $s = Parse-Hm $Start; if (-not $s) { Bad ("开始时间格式不对: " + $Start + "（应为 HH:mm，如 23:30）"); exit 1 } $qStart = $s; $changed = $true }
    if ($End)    { $e = Parse-Hm $End;   if (-not $e) { Bad ("结束时间格式不对: " + $End + "（应为 HH:mm，如 07:00）");   exit 1 } $qEnd   = $e; $changed = $true }
    if ($Disable) { $qh.enabled = $false; $changed = $true }
    if ($Enable)  { $qh.enabled = $true;  $changed = $true }
    if ($SkipLogin -ne $null) { $qh.skip_auto_login = [bool]$SkipLogin; $changed = $true }
} else {
    # ---------- 交互模式 ----------
    Say ""
    Say ("  当前免打扰:  " + $(if($qh.enabled){"已开启"}else{"已关闭"}) + "   " + $qStart + " - " + $qEnd)
    Say ("  当前后台静默: " + $bStart + " - " + $bEnd + "（该时段内登录窗口后台运行）")
    Say ("  免打扰时是否停止自动登录: " + $(if($qh.skip_auto_login){"是（完全不动，但可手动重连）"}else{"否（仍静默保活，不吵人）"}))
    Say ""
    Say "  1. 修改免打扰时段"
    Say "  2. 开启 / 关闭免打扰"
    Say "  3. 修改后台静默时段（就是 7:00-23:00 那个）"
    Say "  4. 免打扰时是否完全停止自动登录"
    Say "  0. 不改，退出"
    Say ""
    $choice = (Read-Host "  请输入选项 (0-4)").Trim()

    switch ($choice) {
        '1' {
            $a = (Read-Host ("  开始时间（当前 " + $qStart + "，如 23:30，直接回车表示不变）")).Trim()
            if ($a) { $s = Parse-Hm $a; if (-not $s) { Bad "格式不对，应为 HH:mm"; exit 1 } $qStart = $s; $changed = $true }
            $b = (Read-Host ("  结束时间（当前 " + $qEnd   + "，如 07:00，直接回车表示不变）")).Trim()
            if ($b) { $e = Parse-Hm $b; if (-not $e) { Bad "格式不对，应为 HH:mm"; exit 1 } $qEnd = $e; $changed = $true }
            $qh.enabled = $true
            $changed = $true
        }
        '2' {
            $qh.enabled = -not [bool]$qh.enabled
            Say ("  已" + $(if($qh.enabled){"开启"}else{"关闭"}) + "免打扰")
            $changed = $true
        }
        '3' {
            $a = (Read-Host ("  后台静默开始（当前 " + $bStart + "）")).Trim()
            if ($a) { $s = Parse-Hm $a; if (-not $s) { Bad "格式不对，应为 HH:mm"; exit 1 } $bStart = $s; $changed = $true }
            $b = (Read-Host ("  后台静默结束（当前 " + $bEnd + "）")).Trim()
            if ($b) { $e = Parse-Hm $b; if (-not $e) { Bad "格式不对，应为 HH:mm"; exit 1 } $bEnd = $e; $changed = $true }
        }
        '4' {
            Say "  true  = 免打扰时段完全不自动登录（最安静，但掉线也不会重连）"
            Say "  false = 免打扰时段仍静默登录（推荐，不吵人且不会整夜断网）"
            $v = (Read-Host ("  请选择 true / false（当前 " + $qh.skip_auto_login + "）")).Trim()
            if ($v -match '^(?i)(true|1|y|yes|是)$')  { $qh.skip_auto_login = $true;  $changed = $true }
            if ($v -match '^(?i)(false|0|n|no|否)$') { $qh.skip_auto_login = $false; $changed = $true }
        }
        default { Say "  未做修改。"; Say ""; exit 0 }
    }
}

if (-not $changed) { Say "  未做修改。"; Say ""; exit 0 }

# 写回：定点替换，保住原来的缩进、注释与 _note
$newRaw = $raw
foreach ($kv in @(
    @('quiet_hours',       'start',           ('"' + $qStart + '"')),
    @('quiet_hours',       'end',             ('"' + $qEnd   + '"')),
    @('quiet_hours',       'enabled',         ([string]([bool]$qh.enabled)).ToLower()),
    @('quiet_hours',       'skip_auto_login', ([string]([bool]$qh.skip_auto_login)).ToLower()),
    @('background_window', 'start',           ('"' + $bStart + '"')),
    @('background_window', 'end',             ('"' + $bEnd   + '"'))
)) {
    $r = Set-JsonBlockValue $newRaw $kv[0] $kv[1] $kv[2]
    if ($r -eq $null) { Warn ("未能定位 " + $kv[0] + "." + $kv[1] + "，跳过该项") } else { $newRaw = $r }
}

try {
    $null = $newRaw | ConvertFrom-Json          # 先校验，写坏了就回滚
    [System.IO.File]::WriteAllText($settingsPath, $newRaw, (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Bad ("写回失败，配置未改动: " + $_.Exception.Message)
    Say ""
    exit 1
}

Say ""
OK ("免打扰: " + $(if($qh.enabled){"已开启"}else{"已关闭"}) + "  " + $qStart + " - " + $qEnd + "（停止自动登录=" + $qh.skip_auto_login + "）")
OK ("后台静默: " + $bStart + " - " + $bEnd)
Say ""

# 配置只在监控启动时读取，改完必须重启才生效
if (-not $NoRestart) {
    $r = (Read-Host "  监控需要重启才能生效，现在重启？[Y/n]").Trim()
    if ($r -eq "" -or $r -match '^(?i)(y|yes|是)$') {
        try { Stop-ScheduledTask -TaskName "Xfile_CampusNetGuard" -ErrorAction Stop; Start-Sleep -Seconds 2 } catch { Warn ("停止任务失败: " + $_.Exception.Message) }
        try { Start-ScheduledTask -TaskName "Xfile_CampusNetGuard" -ErrorAction Stop; OK "监控已重启，新时段已生效" }
        catch { Warn ("自动重启失败，请手动运行 安装.bat 或重启电脑: " + $_.Exception.Message) }
    } else {
        Warn "配置已保存，将在下次监控启动时生效（或现在手动运行 安装.bat 重启）"
    }
} else {
    Warn "配置已保存，将在下次监控启动时生效"
}
Say ""
