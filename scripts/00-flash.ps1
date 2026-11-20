# =============================================================================
#  MX64 一键刷机（PC 侧全自动）
#
#    powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1
#    powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -Check      # 只看结论
#    powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -DryRun     # 只看计划
#
#  流程（6 个阶段）：
#    [1] 环境检查     网卡地址 / python / 工具
#    [2] 起传输服务   TFTP(UDP 69) + HTTP(备用)
#    [3] 刷 U-Boot    telnet 进 diagnostic mode，跑 one-shot-diag.sh
#    [4] 重启等系统    设备重启 -> U-Boot 自动 TFTP 拉 initramfs
#    [5] 关传输服务    不再需要 TFTP/HTTP 了
#    [6] sysupgrade    scp 上传 + ssh 执行，等系统回来
#
#  前提：
#    - 设备已进 diagnostic mode（按住 reset 上电，白灯闪两下后松手，等灯变绿）
#    - PC 网卡 192.168.1.2/24，网线接设备 LAN 口
#    - TFTP 要管理员权限；-Transport http 可以不用
# =============================================================================

param(
    [string]$ServerIp = '192.168.1.2',
    [string]$DeviceIp = '192.168.1.1',
    [int]$Port = 8000,
    [ValidateSet('tftp', 'http')]
    [string]$Transport = 'tftp',
    [ValidateSet('ng', 'clayface')]
    [string]$Uboot = 'ng',
    [string]$SysupgradeFile = '',
    [int]$BootTimeoutSec = 420,
    [int]$SshTimeoutSec = 240,
    [switch]$Check,
    [switch]$SkipSysupgrade,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$kitRoot = Split-Path -Parent $PSScriptRoot
$filesDir = Join-Path $kitRoot 'files'

# ----------------------------------------------------------------- UI 小工具
$script:T0 = Get-Date
$script:TotalPhase = 6

function Now2 { '{0:mm\:ss}' -f ((Get-Date) - $script:T0) }
function Rule { param([string]$Color = 'DarkGray') Write-Host ('-' * 68) -ForegroundColor $Color }

function Banner {
    Write-Host ''
    Write-Host '  +----------------------------------------------------------------+' -ForegroundColor DarkCyan
    Write-Host '  |  Meraki MX64 / MX64W  ->  OpenWrt                               |' -ForegroundColor DarkCyan
    Write-Host '  |  u-boot  +  initramfs  +  sysupgrade                            |' -ForegroundColor DarkCyan
    Write-Host '  +----------------------------------------------------------------+' -ForegroundColor DarkCyan
}

function Phase([int]$n, [string]$text) {
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $n, $script:TotalPhase, $text) -ForegroundColor Cyan
    Rule 'DarkCyan'
}

function Step([string]$m) { Write-Host ("        {0} ..." -f $m) -ForegroundColor Gray }
function Ok([string]$m)   { Write-Host ("   [ ok ] {0}" -f $m) -ForegroundColor Green }
function Warn([string]$m) { Write-Host ("   [ !  ] {0}" -f $m) -ForegroundColor Yellow }
function Bad([string]$m)  { Write-Host ("   [fail] {0}" -f $m) -ForegroundColor Red }
function Note([string]$m) { Write-Host ("          {0}" -f $m) -ForegroundColor DarkGray }
function KeyVal([string]$k, [string]$v) {
    Write-Host ("   {0,-11}: " -f $k) -ForegroundColor Gray -NoNewline
    Write-Host $v -ForegroundColor White
}

function Wait-Port {
    param([string]$IP, [int]$PortNo, [int]$TimeoutSec, [string]$Label)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $c = New-Object Net.Sockets.TcpClient
        try {
            $iar = $c.BeginConnect($IP, $PortNo, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(800)) {
                $c.EndConnect($iar)
                Write-Host ("`r" + (' ' * 72) + "`r") -NoNewline
                return $true
            }
        } catch {
        } finally {
            $c.Close()
        }
        $pct = [math]::Min(100, [int]($sw.Elapsed.TotalSeconds * 100 / $TimeoutSec))
        $fill = [int]($pct / 4)
        $bar = ('#' * $fill) + ('.' * (25 - $fill))
        Write-Host ("`r   [wait] {0,-22} [{1}] {2,3}s / {3}s" -f $Label, $bar, [int]$sw.Elapsed.TotalSeconds, $TimeoutSec) -NoNewline -ForegroundColor DarkCyan
        Start-Sleep -Milliseconds 800
    }
    Write-Host ("`r" + (' ' * 72) + "`r") -NoNewline
    return $false
}

function Read-Available {
    param([System.IO.Stream]$Stream, [int]$Ms = 1000, [System.Text.Decoder]$Decoder)
    $buf = New-Object byte[] 8192
    $bytes = New-Object System.Collections.Generic.List[byte]
    $deadline = (Get-Date).AddMilliseconds($Ms)
    while ((Get-Date) -lt $deadline) {
        try {
            $n = $Stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            for ($i = 0; $i -lt $n; $i++) { $bytes.Add($buf[$i]) }
        } catch { }
    }
    if ($bytes.Count -eq 0) { return '' }

    # 设备输出是 UTF-8，用带状态的 Decoder 才不会把多字节汉字切坏
    $arr = $bytes.ToArray()
    if (-not $Decoder) { $Decoder = [System.Text.Encoding]::UTF8.GetDecoder() }
    $chars = New-Object char[] ($arr.Length + 8)
    $cnt = $Decoder.GetChars($arr, 0, $arr.Length, $chars, 0)
    if ($cnt -le 0) { return '' }
    $text = -join $chars[0..($cnt - 1)]
    $text = $text -replace "`0", ''
    $text = [regex]::Replace($text, "\xFF[\xFB-\xFE].|\xFF\xFA.*?\xFF\xF0", '', 'Singleline')
    return ($text -replace "`b", '')
}

function Send-Line {
    param([System.IO.Stream]$Stream, [string]$Line)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Line + "`r`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

# ----------------------------------------------------------------- 计划
Banner

$httpBase = "http://${ServerIp}:$Port"
$tftpBase = "tftp://$ServerIp"
if ($Transport -eq 'tftp') { $primary = $tftpBase; $fallback = $httpBase }
else { $primary = $httpBase; $fallback = $tftpBase }

$flagCheck = ''
if ($Check) { $flagCheck = '--check ' }
$flagUboot = ''
if ($Uboot -eq 'clayface') { $flagUboot = '--clayface ' }
$bootstrap = "cd /tmp && wget $httpBase/one-shot-diag.sh && sh one-shot-diag.sh $flagCheck$flagUboot$primary $fallback"

Write-Host ''
Write-Host '  这次的配置' -ForegroundColor White
KeyVal 'Device'     "$DeviceIp (telnet 23)"
KeyVal 'Server'     "$ServerIp  ($Transport 主 / $(if ($Transport -eq 'tftp') { 'http' } else { 'tftp' }) 备)"
KeyVal 'U-Boot'     $(if ($Uboot -eq 'ng') { 'uboot_ng.bin（本项目，需 1 MiB 分区）' } else { 'clayface uboot_mx64 / uboot_mx64_small（按 mtd0 自动选）' })
KeyVal 'Sysupgrade' $(if ($SkipSysupgrade) { '跳过' } elseif ($SysupgradeFile) { $SysupgradeFile } else { '自动选最新的（按 A0/B0+ 匹配）' })
KeyVal 'Mode'       $(if ($Check) { '仅检测（--check，不写 NAND）' } elseif ($DryRun) { 'DryRun（只看计划）' } else { '真刷' })

if ($DryRun) {
    Write-Host ''
    Rule 'DarkYellow'
    Write-Host '  DryRun：下面是会注入到设备的那一行，不会做任何实际操作' -ForegroundColor Yellow
    Write-Host ("  " + $bootstrap) -ForegroundColor DarkGray
    Rule 'DarkYellow'
    return
}

# ----------------------------------------------------------------- [1] 环境检查
Phase 1 '环境检查'

$hasIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -eq $ServerIp }
if (-not $hasIp) {
    Bad "本机没有 $ServerIp 这个地址"
    Note '先执行（管理员 PowerShell）：'
    Note '  Get-NetAdapter | Format-Table Name,InterfaceIndex,Status'
    Note "  New-NetIPAddress -InterfaceIndex <索引> -IPAddress $ServerIp -PrefixLength 24"
    throw "缺少地址 $ServerIp"
}
Ok "网卡地址 $ServerIp 就绪"

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { Bad '找不到 python（脚本用它起 TFTP/HTTP 服务）'; throw 'python 未安装' }
Ok ("python " + (& python --version 2>&1))

$sshExe = Get-Command ssh -ErrorAction SilentlyContinue
$scpExe = Get-Command scp -ErrorAction SilentlyContinue
if ($SkipSysupgrade) {
    Warn '按 -SkipSysupgrade 跳过 sysupgrade 阶段'
} elseif (-not $sshExe -or -not $scpExe) {
    Warn '没找到 ssh/scp，第 6 阶段会跳过（可先装 OpenSSH 客户端）'
    $SkipSysupgrade = $true
} else {
    Ok 'ssh / scp 就绪（第 6 阶段用）'
}

# 暂存目录：把 files/ 和 *.sh 摊平，设备端路径就是 /uboot_ng.bin 这种
$stage = Join-Path $env:TEMP 'mx64-http'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory $stage | Out-Null
Copy-Item (Join-Path $filesDir '*') $stage -Force
Copy-Item (Join-Path $PSScriptRoot '*.sh') $stage -Force
Ok ("暂存 {0} 个文件 -> {1}" -f (Get-ChildItem $stage).Count, $stage)

# ----------------------------------------------------------------- [2] 服务
Phase 2 '启动传输服务'

$servers = @()
$logs = @{}
$httpLog = Join-Path $env:TEMP 'mx64-http.log'
$servers += Start-Process python -ArgumentList '-m', 'http.server', "$Port", '--bind', '0.0.0.0', '--directory', $stage `
    -PassThru -WindowStyle Hidden -RedirectStandardOutput $httpLog -RedirectStandardError "$httpLog.err"
$logs['http'] = $httpLog
Ok "HTTP  $httpBase  (pid $($servers[-1].Id))"

if ($Transport -eq 'tftp') {
    $tftpLog = Join-Path $env:TEMP 'mx64-tftp.log'
    $servers += Start-Process python -ArgumentList (Join-Path $PSScriptRoot '70-tftp-server.py'), '--dir', $stage, '--port', '69' `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $tftpLog -RedirectStandardError "$tftpLog.err"
    $logs['tftp'] = $tftpLog
    Start-Sleep -Milliseconds 900
    if ($servers[-1].HasExited) {
        Warn 'TFTP 起不来（UDP 69 需要管理员权限），改走 HTTP'
        $primary = $httpBase; $fallback = $tftpBase
        $bootstrap = "cd /tmp && wget $httpBase/one-shot-diag.sh && sh one-shot-diag.sh $flagCheck$flagUboot$primary $fallback"
    } else {
        Ok "TFTP  $tftpBase  (pid $($servers[-1].Id), UDP 69)"
    }
}

function Stop-Servers {
    foreach ($p in $servers) {
        if ($p -and -not $p.HasExited) { try { $p.Kill() } catch { } }
    }
}

try {
    Start-Sleep -Milliseconds 900

    # ------------------------------------------------------------- [3] 刷 U-Boot
    Phase 3 $(if ($Check) { '检测设备（不写 NAND）' } else { '刷 U-Boot' })

    Step "telnet $DeviceIp`:23"
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect($DeviceIp, 23)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 1000
    $decoder = [System.Text.Encoding]::UTF8.GetDecoder()
    Ok '已连上 diagnostic mode'

    Start-Sleep -Milliseconds 1200
    Send-Line $stream ''
    $greeting = Read-Available -Stream $stream -Ms 1500 -Decoder $decoder
    if ($greeting.Trim()) {
        Note '设备返回：'
        ($greeting -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 6 |
            ForEach-Object { Note ("  " + $_.Trim()) }
    }

    Step '注入 one-shot-diag.sh'
    Send-Line $stream $bootstrap

    $deadline = (Get-Date).AddSeconds($BootTimeoutSec)
    $all = New-Object System.Text.StringBuilder
    $done = $false
    Write-Host ''
    while ((Get-Date) -lt $deadline) {
        $chunk = Read-Available -Stream $stream -Ms 1200 -Decoder $decoder
        if (-not $chunk) { continue }
        [void]$all.Append($chunk)
        ($chunk -split "`r?`n") | Where-Object { $_ -ne '' } | ForEach-Object {
            Write-Host ("   | " + $_) -ForegroundColor DarkGray
        }
        if ($chunk -match '====\s*完成\s*====') { $done = $true; break }
    }
    $out = $all.ToString()

    if (-not $done) {
        Bad '没等到完成标记（超时或中途出错）'
        if ($out -match '!!\s*(.+)') { Bad ('设备报错: ' + $matches[1].Trim()) }
        throw '第 3 阶段失败'
    }

    # 从设备输出里提取结论
    $variant = 'b0'
    if ($out -match '->\s*a0') { $variant = 'a0' }
    elseif ($out -match '->\s*b0') { $variant = 'b0' }
    $target = ''
    if ($out -match 'TARGET=(\S+)') { $target = $matches[1] }
    elseif ($out -match 'Target\s*:\s*(\S+)') { $target = $matches[1] }

    Ok ('设备侧完成，写入: ' + $(if ($target) { $target } else { '（未知）' }))
    Ok ('SoC 判定: ' + $(if ($variant -eq 'a0') { 'A0（后续用 -a0- 镜像）' } else { 'B0+（用常规镜像）' }))

    if ($Check) {
        Write-Host ''
        Rule 'DarkYellow'
        Write-Host '  -Check：只拿到了结论，什么都没写。' -ForegroundColor Yellow
        Write-Host ('  设备会写入: ' + $(if ($target) { $target } else { '（见上面输出）' })) -ForegroundColor Yellow
        Rule 'DarkYellow'
        Send-Line $stream 'exit'
        Start-Sleep -Milliseconds 400
        $client.Close()
        return
    }

    # ------------------------------------------------------------- [4] 重启
    Phase 4 '重启并等待 initramfs 起来'
    Step 'reboot（U-Boot 会自动 TFTP 拉 initramfs）'
    Send-Line $stream 'reboot'
    Start-Sleep -Milliseconds 800
    try { $client.Close() } catch { }

    Note 'U-Boot 顺序：UBI（空）-> USB（没插）-> TFTP，所以会自己来取镜像'
    if (-not (Wait-Port -IP $DeviceIp -PortNo 22 -TimeoutSec $BootTimeoutSec -Label 'initramfs ssh')) {
        Bad '等不到设备的 22 端口'
        Note '检查：TFTP 服务是否还在（本节日志）、网线是否在 LAN 口、U-Boot 是否真的刷进去了'
        throw '第 4 阶段失败'
    }
    Ok 'initramfs 已启动（ssh 端口打开）'

    # ------------------------------------------------------------- [5] 关服务
    Phase 5 '关闭 TFTP / HTTP'
    Stop-Servers
    Ok '传输服务已停止（设备已经在 RAM 里跑系统，不再需要）'

    if ($SkipSysupgrade) {
        Warn '按 -SkipSysupgrade 跳过 sysupgrade'
        Write-Host ''
        Rule 'DarkGreen'
        Write-Host '  到这里就完成了：设备正在跑 initramfs。' -ForegroundColor Green
        Write-Host '  手动继续: scp sysupgrade 到 /tmp 后 ssh 执行 sysupgrade -n <file>' -ForegroundColor Green
        Rule 'DarkGreen'
        return
    }

    # ------------------------------------------------------------- [6] sysupgrade
    Phase 6 '上传并执行 sysupgrade'

    $img = $SysupgradeFile
    if (-not $img) {
        $pattern = if ($variant -eq 'a0') { 'openwrt-*-meraki_mx64-a0-squashfs.sysupgrade.bin' } else { 'openwrt-*-meraki_mx64-squashfs.sysupgrade.bin' }
        $cand = Get-ChildItem (Join-Path $filesDir $pattern) -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
        if (-not $cand) { throw "files/ 里找不到 $pattern" }
        $img = $cand.FullName
    }
    if (-not (Test-Path $img)) { throw "找不到 sysupgrade 文件: $img" }

    KeyVal 'Image' (Split-Path $img -Leaf)
    KeyVal 'Size'  ('{0:N1} MB' -f ((Get-Item $img).Length / 1MB))

    $sshOpts = @('-O', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')
    $sshOptsNoO = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')

    Step 'scp 上传到 /tmp'
    $remote = '/tmp/' + (Split-Path $img -Leaf)
    & scp @sshOpts $img "root@${DeviceIp}:$remote" 2>&1 | ForEach-Object { Note $_ }
    if ($LASTEXITCODE -ne 0) { throw 'scp 上传失败' }
    Ok '上传完成'

    Step 'sysupgrade -n（不保留配置，全新安装）'
    Note '设备会校验镜像然后自己重启，SSH 会断开，这是正常的'
    & ssh @sshOptsNoO "root@$DeviceIp" "sysupgrade -n $remote" 2>&1 | ForEach-Object { Note $_ }
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { Warn "sysupgrade 返回 $rc（连接被断开时也常见，看下面能否重新连上）" }
    else { Ok 'sysupgrade 已下发' }

    Step '等待系统重新起来'
    Start-Sleep -Seconds 8
    if (Wait-Port -IP $DeviceIp -PortNo 22 -TimeoutSec $SshTimeoutSec -Label 'OpenWrt ssh') {
        Ok 'OpenWrt 已启动（ssh 端口打开）'
    } else {
        Warn '等不到 ssh；可能还在写 flash，稍等多一两分钟再试 ping/ssh'
    }

    # ------------------------------------------------------------- 总结
    Write-Host ''
    Rule 'DarkGreen'
    Write-Host '  完成' -ForegroundColor Green
    Rule 'DarkGreen'
    KeyVal 'Elapsed' (Now2)
    KeyVal 'U-Boot'  $(if ($target) { $target } else { '(见上)' })
    KeyVal 'Image'   (Split-Path $img -Leaf)
    KeyVal 'Device'  $DeviceIp
    Write-Host ''
    Note '下一步：ssh root@192.168.1.1 进去设密码，然后可选做第 10 节释放 flash 空间'
    Rule 'DarkGreen'
}
catch {
    Write-Host ''
    Rule 'DarkRed'
    Write-Host ("  中断: " + $_.Exception.Message) -ForegroundColor Red
    Rule 'DarkRed'
    Note ("日志: $httpLog" + $(if ($logs['tftp']) { "  " + $logs['tftp'] } else { '' }))
    Stop-Servers
    throw
}
finally {
    Stop-Servers
}
