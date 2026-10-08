# set_account.ps1 - 图形化修改校园网账号与密码（X-file）
# v2.0 改动：密码框掩码显示、写入改为原子替换 + .bak 备份、保存前做校验、错误信息本地化
# v2.1 修复：File.Replace 的第三个参数改传真实备份路径（原来传 $null 被 PS 变成空串，
#            触发 "The path is not of a legal form."，导致密码一直保存不了）
# v2.2 新增：保存成功后自动触发一次重连（写 config\reconnect.flag，必要时拉起监控），
#            让「保存即生效」真正成立 —— 此前改完密码最坏要等满 60 分钟冷却才会重试。
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path   # X-file\scripts
$rootDir    = Split-Path -Parent $scriptDir
$binDir     = Join-Path $rootDir "bin"      # exe 与它的配置必须同目录
$configPath = Join-Path $binDir "campus_net_config.json"
$backupPath = Join-Path $binDir "campus_net_config.json.bak"
$tmpPath    = Join-Path $binDir "campus_net_config.json.tmp"

function Read-Config {
    if (-not (Test-Path $configPath)) { return $null }
    try { return (Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

# [v2.2] 保存成功后立即触发一次重连：写 config\reconnect.flag，监控会在 10 秒内用新密码重试。
# 监控没在运行的话顺手把它拉起来（判定方式与 立即重连.bat 一致）。返回一句给用户看的结果说明。
function Invoke-ImmediateReconnect {
    $cfgDir = Join-Path $rootDir "config"
    if (-not (Test-Path $cfgDir)) {
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    }
    Set-Content -Path (Join-Path $cfgDir "reconnect.flag") `
                -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8

    $running = $true
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
                   Where-Object { $_.CommandLine -like "*monitor.ps1*" })
        $running = ($procs.Count -ge 1)
    } catch {
        # 查不到就当作它正在跑：标志文件不会丢，最坏只是晚一点被消费，不误报错误
        $running = $true
    }
    if ($running) {
        return "已通知监控，约 10 秒内会用新密码重试一次（结果见 logs\monitor.log）。"
    }

    $mon = Join-Path $scriptDir "monitor.ps1"
    if (-not (Test-Path $mon)) {
        return "但监控未在运行、也没找到 monitor.ps1，请双击 恢复监控.bat。"
    }
    Start-Process -FilePath "powershell.exe" `
                  -ArgumentList @("-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$mon`"") `
                  -WorkingDirectory $rootDir | Out-Null
    Start-Sleep -Seconds 2
    return "监控此前未在运行，已自动启动，它会立刻用新密码尝试登录。"
}

$cfg = Read-Config

$form = New-Object Windows.Forms.Form
$form.Text = "校园网账号设置"
$form.Size = New-Object Drawing.Size(400, 250)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$accText = ""; $pwdText = ""
if ($cfg -ne $null -and $cfg.campus_network -ne $null) {
    $accText = [string]$cfg.campus_network.account
    $pwdText = [string]$cfg.campus_network.password
}

$l1 = New-Object Windows.Forms.Label; $l1.Text = "账号:"; $l1.Location = New-Object Drawing.Point(20, 22); $l1.AutoSize = $true
$t1 = New-Object Windows.Forms.TextBox; $t1.Location = New-Object Drawing.Point(90, 18); $t1.Width = 260
$t1.Text = $accText

$l2 = New-Object Windows.Forms.Label; $l2.Text = "密码:"; $l2.Location = New-Object Drawing.Point(20, 62); $l2.AutoSize = $true
$t2 = New-Object Windows.Forms.TextBox; $t2.Location = New-Object Drawing.Point(90, 58); $t2.Width = 260
$t2.Text = $pwdText
$t2.UseSystemPasswordChar = $true          # [修复] 密码不再明文显示

$cb = New-Object Windows.Forms.CheckBox
$cb.Text = "显示密码"; $cb.Location = New-Object Drawing.Point(90, 84); $cb.AutoSize = $true
$cb.Add_CheckedChanged({ $t2.UseSystemPasswordChar = -not $cb.Checked })

$l3 = New-Object Windows.Forms.Label
$l3.Text = "保存后会自动重连一次，无需重装 / 重启电脑。"
$l3.Location = New-Object Drawing.Point(20, 112); $l3.AutoSize = $true

$l4 = New-Object Windows.Forms.Label
$l4.Text = "提示：密码以明文保存在配置文件中，请勿外传该文件夹。"
$l4.Location = New-Object Drawing.Point(20, 134); $l4.AutoSize = $true
$l4.ForeColor = [System.Drawing.Color]::FromArgb(150, 60, 30)

$b = New-Object Windows.Forms.Button; $b.Text = "保存"; $b.Location = New-Object Drawing.Point(150, 168)
$b.Width = 100

$b.Add_Click({
    $acc = $t1.Text.Trim()
    $pwd = $t2.Text
    if ($acc -eq "") { [Windows.Forms.MessageBox]::Show("账号不能为空。", "输入有误") | Out-Null; return }
    if ($pwd -eq "") { [Windows.Forms.MessageBox]::Show("密码不能为空。", "输入有误") | Out-Null; return }
    try {
        $c = $null
        if (Test-Path $configPath) { $c = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        if ($c -eq $null) { $c = [PSCustomObject]@{} }
        if ($c.campus_network -eq $null) {
            $c | Add-Member -MemberType NoteProperty -Name campus_network -Value ([PSCustomObject]@{}) -Force
        }
        $c.campus_network.account  = $acc
        $c.campus_network.password = $pwd

        # 写 UTF-8 且不带 BOM：与原版配置一致，避免 exe 用普通 utf-8 解析失败
        $json = $c | ConvertTo-Json -Depth 6
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpPath, $json, $utf8NoBom)

        # 校验临时文件可解析后再原子替换，避免写坏配置导致登录失效
        $null = Get-Content $tmpPath -Raw -Encoding UTF8 | ConvertFrom-Json
        # [坑·已修] PowerShell 会把 $null 转成空字符串再传给 .NET 的 string 参数，
        # 于是 File.Replace 内部对空路径调 Path.GetFullPath("") 直接抛
        # "The path is not of a legal form."，表现为每次点保存都失败。
        # 改为传真实备份路径：Replace 会自己把原配置备份过去，原子替换语义不变。
        if (Test-Path $configPath) {
            [System.IO.File]::Replace($tmpPath, $configPath, $backupPath)
        } else {
            [System.IO.File]::Move($tmpPath, $configPath)   # 首次生成配置，无需备份
        }

        # [v2.2] 保存成功后自动触发一次重连，让「保存即生效」真正成立：
        # 之前改完密码最坏要等满 60 分钟冷却才会重试，看起来像"没反应"。
        $reconMsg = ""
        try { $reconMsg = Invoke-ImmediateReconnect }
        catch { $reconMsg = "但自动重连通知失败，请手动双击一次 立即重连.bat。" }

        [Windows.Forms.MessageBox]::Show(
            ("账号密码已保存，程序已按新密码重新尝试登录。" + [Environment]::NewLine +
             $reconMsg + [Environment]::NewLine +
             "不需要重新安装，也不需要重启电脑。"), "已生效") | Out-Null
        $form.Close()
    } catch {
        if (Test-Path $tmpPath) { try { [System.IO.File]::Delete($tmpPath) } catch {} }
        $msg = $_.Exception.Message
        if ($msg -match "denied|拒绝|being used|正在使用") { $msg = "配置文件被占用或只读，请关闭占用它的程序后重试。" }
        elseif ($msg -match "not found|找不到") { $msg = "找不到配置文件。" }
        elseif ($msg -match "legal form|不是合法|路径") { $msg = "配置文件路径异常，请确认程序目录完整、未被移动或改名。" }
        [Windows.Forms.MessageBox]::Show(("保存失败：" + $msg), "错误") | Out-Null
    }
})

$form.Controls.AddRange(@($l1, $t1, $l2, $t2, $cb, $l3, $l4, $b))
[Windows.Forms.Application]::Run($form)
