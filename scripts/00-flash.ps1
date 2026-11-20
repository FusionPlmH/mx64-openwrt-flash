# =============================================================================
#  MX64 一键刷机（全部逻辑在 PC 侧）
#
#    powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1              # 默认 TFTP，刷 uboot_ng
#    powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -Check      # 只看结论
#    powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -DryRun     # 只看计划
#
#  设备上不落任何脚本：PC 通过 telnet 一条一条发原始命令（cat / wget / dd ...），
#  解析、判断、校验全在 PC 完成。所以不依赖设备上的 sed / awk / 脚本能力。
#
#  流程（6 个阶段）：
#    [1] 环境检查    网卡 / python / ssh+scp / 暂存文件
#    [2] 起服务      TFTP(UDP 69) + HTTP(备用)
#    [3] 刷 U-Boot   探测能力 -> 读分区/写保护/SoC -> 下载 -> 校验 -> 写入 -> 回读
#    [4] 重启等系统  设备重启 -> U-Boot 自动 TFTP 拉 initramfs
#    [5] 关服务      不再需要 TFTP/HTTP
#    [6] sysupgrade  scp 上传 + ssh 执行，等系统回来
#
#  前提：设备已在 diagnostic mode；PC 网卡 192.168.1.2/24；TFTP 需管理员（-Transport http 可免）
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

# ----------------------------------------------------------------- UI
$script:T0 = Get-Date
$script:TotalPhase = 6

function Now2 { '{0:mm\:ss}' -f ((Get-Date) - $script:T0) }
function Rule { param([string]$Color = 'DarkGray') Write-Host ('-' * 68) -ForegroundColor $Color }
function Banner {
    Write-Host ''
    Write-Host '  +----------------------------------------------------------------+' -ForegroundColor DarkCyan
    Write-Host '  |  Meraki MX64 / MX64W  ->  OpenWrt                               |' -ForegroundColor DarkCyan
    Write-Host '  |  全部逻辑在 PC 侧，设备上不落脚本                                |' -ForegroundColor DarkCyan
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
    $arr = $bytes.ToArray()
    if (-not $Decoder) { $Decoder = [System.Text.Encoding]::UTF8.GetDecoder() }
    $chars = New-Object char[] ($arr.Length + 8)
    $cnt = $Decoder.GetChars($arr, 0, $arr.Length, $chars, 0)
    if ($cnt -le 0) { return '' }
    $text = -join $chars[0..($cnt - 1)]
    $text = $text -replace "`0", ''
    return ($text -replace "`b", '')
}

function Send-Line {
    param([System.IO.Stream]$Stream, [string]$Line)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Line + "`r`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Test-Port {
    param([string]$IP, [int]$PortNo, [int]$Ms = 1200)
    $c = New-Object Net.Sockets.TcpClient
    try { $ok = $c.ConnectAsync($IP, $PortNo).Wait($Ms); return [bool]$ok }
    catch { return $false }
    finally { $c.Close() }
}

# ----------------------------------------------------------------- 计划
Banner

$httpBase = "http://${ServerIp}:$Port"
$tftpBase = "tftp://$ServerIp"
if ($Transport -eq 'tftp') { $primary = $tftpBase; $fallback = $httpBase }
else { $primary = $httpBase; $fallback = $tftpBase }

Write-Host ''
Write-Host '  这次的配置' -ForegroundColor White
KeyVal 'Device'     "$DeviceIp (telnet 23)"
KeyVal 'Server'     "$ServerIp  ($Transport 主 / $(if ($Transport -eq 'tftp') { 'http' } else { 'tftp' }) 备)"
KeyVal 'U-Boot'     $(if ($Uboot -eq 'ng') { 'uboot_ng.bin（本项目，需 1 MiB 分区）' } else { 'clayface uboot_mx64 / uboot_mx64_small（按 mtd0 自动选）' })
KeyVal 'Sysupgrade' $(if ($SkipSysupgrade) { '跳过' } elseif ($SysupgradeFile) { $SysupgradeFile } else { '自动选最新的（按 A0/B0+ 匹配）' })
KeyVal 'Backup'     '跳过（默认）。要备份见 README 第 8 节，在 initramfs 里用 scp 拉'
KeyVal 'Mode'       $(if ($Check) { '仅检测（不写 NAND）' } elseif ($DryRun) { '只看计划' } else { '真刷' })

if ($DryRun) {
    Write-Host ''
    Rule 'DarkYellow'
    Write-Host '  DryRun：真跑时会在设备上依次执行这些命令（解析全在 PC）' -ForegroundColor Yellow
    Note 'for t in wget wc dd md5sum insmod chmod devmem devmem2; do ... done   # 能力探测'
    Note 'cat /proc/mtd                                                      # mtd0 大小'
    Note 'cat /sys/block/mtdblock0/ro                                        # 写保护'
    Note 'devmem 0x18000000                                                  # SoC 版本'
    Note "cd /tmp && wget http://$ServerIp`:$Port/<u-boot 镜像>"
    Note 'wc -c < /tmp/<img> ; md5sum /tmp/<img>                            # 校验（PC 比对）'
    Note 'insmod /tmp/mtd-rw.ko i_want_a_brick=1                            # 仅当 mtd0 只读'
    Note 'dd if=/tmp/<img> of=/dev/mtdblock0    或   ./mtd write /tmp/<img> /dev/mtd0'
    Note 'dd if=/dev/mtdblock0 bs=1024 count=64 | md5sum                     # 回读比对'
    Note 'reboot'
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

$stage = Join-Path $env:TEMP 'mx64-http'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory $stage | Out-Null
Copy-Item (Join-Path $filesDir '*') $stage -Force
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

function Stop-Servers {
    foreach ($p in $servers) {
        if ($p -and -not $p.HasExited) { try { $p.Kill() } catch { } }
    }
}

$tftpOk = $false
if ($Transport -eq 'tftp') {
    $tftpLog = Join-Path $env:TEMP 'mx64-tftp.log'
    $servers += Start-Process python -ArgumentList (Join-Path $PSScriptRoot '70-tftp-server.py'), '--dir', $stage, '--port', '69' `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $tftpLog -RedirectStandardError "$tftpLog.err"
    $logs['tftp'] = $tftpLog
    Start-Sleep -Milliseconds 900
    if ($servers[-1].HasExited) {
        Warn 'TFTP 起不来（UDP 69 需要管理员权限），改走 HTTP'
    } else {
        $tftpOk = $true
        Ok "TFTP  $tftpBase  (pid $($servers[-1].Id), UDP 69)"
    }
}

try {
    Start-Sleep -Milliseconds 700

    # ------------------------------------------------------------- [3] 刷 U-Boot
    Phase 3 $(if ($Check) { '检测设备（不写 NAND）' } else { '刷 U-Boot（PC 驱动）' })

    Step "检查 $DeviceIp`:23 是否可达"
    if (-not (Test-Port -IP $DeviceIp -PortNo 23)) {
        Bad "telnet 端口 $DeviceIp`:23 连不上"
        Write-Host ''
        $probes = @(
            @{ ip = $DeviceIp;     port = 80; hint = '设备在正常启动的原厂固件里（不是 diagnostic mode）' },
            @{ ip = $DeviceIp;     port = 22; hint = '设备可能在跑 OpenWrt' },
            @{ ip = '192.168.0.1'; port = 23; hint = '原厂固件 LAN 默认地址是 192.168.0.1' },
            @{ ip = '192.168.0.1'; port = 80; hint = '原厂固件 LAN 默认地址是 192.168.0.1' }
        )
        $found = $false
        foreach ($p in $probes) {
            if (Test-Port -IP $p.ip -PortNo $p.port -Ms 800) {
                $found = $true
                Warn ("但是 {0}:{1} 是通的 -> {2}" -f $p.ip, $p.port, $p.hint)
            }
        }
        if (-not $found) {
            $arp = arp -a 2>$null | Select-String -SimpleMatch $DeviceIp
            if (-not $arp) {
                Warn "ARP 表里也没有 $DeviceIp -> 二层没有任何设备应答"
                Note '这通常意味着：设备没上电 / 网线插在 WAN 口 / 还在启动中 / 没进 diagnostic mode'
            }
        }
        Write-Host ''
        Note '按这个顺序排查：'
        Note '  1) 设备上电了吗？前面板灯：白灯闪两下 = diagnostic mode'
        Note '  2) 网线插在 LAN1-4 吗？（MX64 有 4 个 LAN + 1 个 WAN）'
        Note '  3) 进 diag 需要 20~30 秒'
        Note '  4) 换一根网线 / 换一个 LAN 口'
        throw "设备 $DeviceIp 不可达"
    }
    Ok 'telnet 端口已打开'

    Step "连接 telnet $DeviceIp`:23"
    $client = New-Object System.Net.Sockets.TcpClient
    try { $client.Connect($DeviceIp, 23) }
    catch { Bad "telnet 连接失败: $($_.Exception.Message)"; throw '设备不可达' }
    $stream = $client.GetStream()
    $stream.ReadTimeout = 1000
    $decoder = [System.Text.Encoding]::UTF8.GetDecoder()
    Ok '已连上 diagnostic mode'

    Start-Sleep -Milliseconds 1000
    Send-Line $stream ''
    $greeting = Read-Available -Stream $stream -Ms 1200 -Decoder $decoder
    ($greeting -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 4 |
        ForEach-Object { Note ("  " + $_.Trim()) }

    # ---- PC 驱动的命令执行器：用成对标记包住命令，输出边界可靠 ----
    function Invoke-Dev {
        param([string]$Command, [int]$TimeoutSec = 120)
        $id = Get-Random -Minimum 100000 -Maximum 999999
        $begin = "B$id"
        $end = "E$id"
        Send-Line -Stream $stream -Line "echo $begin; $Command; echo $end`$?"
        $sb = New-Object System.Text.StringBuilder
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $code = $null
        $out = ''
        while ((Get-Date) -lt $deadline) {
            $chunk = Read-Available -Stream $stream -Ms 700 -Decoder $decoder
            if ($chunk) { [void]$sb.Append($chunk) }
            # 命令回显那一行也含标记，取最后一次匹配 = 真正的输出块
            $ms = [regex]::Matches($sb.ToString(), "(?s)$begin\r?\n(.*?)\r?\n?$end(\d+)")
            if ($ms.Count -gt 0) {
                $hit = $ms[$ms.Count - 1]
                $out = $hit.Groups[1].Value
                $code = [int]$hit.Groups[2].Value
                break
            }
        }
        return @{ Code = $(if ($null -eq $code) { -1 } else { $code }); Output = $out }
    }

    # 1) 能力探测
    Step '探测设备可用的命令'
    $capCmd = 'for t in wget wc dd md5sum sha512sum insmod chmod devmem devmem2 mtd; do if command -v $t >/dev/null 2>&1; then echo "$t=1"; else echo "$t=0"; fi; done'
    $capOut = (Invoke-Dev $capCmd -TimeoutSec 40).Output
    $caps = @{}
    foreach ($mm in [regex]::Matches($capOut, '(\w+)=([01])')) { $caps[$mm.Groups[1].Value] = ($mm.Groups[2].Value -eq '1') }
    if ($caps.Count -eq 0) { Bad '探测命令没有返回（设备 shell 可能不是 ash？）'; throw '能力探测失败' }
    $have = (($caps.Keys | Where-Object { $caps[$_] } | Sort-Object) -join ' ')
    $miss = (($caps.Keys | Where-Object { -not $caps[$_] } | Sort-Object) -join ' ')
    Ok "有: $have"
    if ($miss) { Warn "没有: $miss" }
    if (-not $caps['wget']) { Bad '设备没有 wget，无法下载镜像'; throw '缺少 wget' }

    # 2) 分区
    Step '读分区表 /proc/mtd'
    $mtdTxt = (Invoke-Dev 'cat /proc/mtd').Output
    ($mtdTxt -split "`n") | Where-Object { $_.Trim() } | ForEach-Object { Note ("  " + $_.Trim()) }
    $mMtd = [regex]::Match($mtdTxt, '(?m)^mtd0:\s*([0-9a-fA-F]+)\s+([0-9a-fA-F]+)')
    if (-not $mMtd.Success) { Bad '读不到 mtd0（设备可能不是预期的分区布局）'; throw 'mtd0 未知' }
    $mtd0Hex = $mMtd.Groups[1].Value
    $mtd0Size = [Convert]::ToInt64($mtd0Hex, 16)
    Ok ("mtd0 = 0x{0} ({1} 字节)" -f $mtd0Hex, $mtd0Size)

    # 3) 写保护
    Step '读 mtd0 写保护状态'
    $roTxt = ((Invoke-Dev 'cat /sys/block/mtdblock0/ro').Output).Trim()
    $needUnlock = ($roTxt -match '^\s*1\s*$')
    if ($needUnlock) { Warn 'mtd0 有写保护（ro=1）-> 需要 mtd-rw.ko 解锁' }
    else { Ok "mtd0 可写（ro=$roTxt）" }

    # 4) SoC
    Step '读 SoC 版本'
    $variant = 'unknown'
    $chipCmd = ''
    if ($caps['devmem']) { $chipCmd = 'devmem 0x18000000' }
    elseif ($caps['devmem2']) { $chipCmd = 'devmem2 0x18000000' }
    if ($chipCmd) {
        $chipOut = (Invoke-Dev $chipCmd -TimeoutSec 30).Output
        $vals = @([regex]::Matches($chipOut, '0x[0-9a-fA-F]+') | ForEach-Object { $_.Value })
        if ($vals.Count -gt 0) {
            $rev = $vals[$vals.Count - 1]
            $rv = [Convert]::ToInt64($rev.Substring(2), 16)
            $nib = ($rv -shr 16) -band 0xF
            if ($nib -le 3) { $variant = 'a0' } else { $variant = 'b0' }
            Ok ("0x18000000 = {0} -> {1}" -f $rev, $(if ($variant -eq 'a0') { 'A0（后续用 -a0- 镜像）' } else { 'B0+（用常规镜像）' }))
        } else {
            Warn "devmem 没有输出可解析的内容: $($chipOut.Trim())"
        }
    } else {
        Warn '设备没有 devmem/devmem2 -> 无法判断 A0/B0+（先按 B0+ 处理）'
    }

    # 5) 决定刷哪个（PC 侧决策）
    $ngSize = (Get-Item (Join-Path $filesDir 'uboot_ng.bin')).Length
    if ($Uboot -eq 'ng') {
        if ($mtd0Size -lt 1048576) {
            Warn "mtd0 只有 0x$mtd0Hex，uboot_ng.bin 有 $ngSize 字节，装不下 -> 改用 uboot_mx64_small"
            $target = 'uboot_mx64_small'
        } else {
            $target = 'uboot_ng.bin'
        }
    } else {
        if ($mtd0Size -lt 1048576) { $target = 'uboot_mx64_small' } else { $target = 'uboot_mx64' }
    }
    $localPath = Join-Path $filesDir $target
    $localSize = (Get-Item $localPath).Length
    $localMd5 = (Get-FileHash $localPath -Algorithm MD5).Hash.ToLower()
    if ($localSize -gt $mtd0Size) { Bad "$target ($localSize 字节) 超过 mtd0 ($mtd0Size 字节)"; throw '镜像放不下' }
    Ok "将刷入 $target ($localSize 字节, md5 $localMd5)"

    if ($Check) {
        Write-Host ''
        Rule 'DarkYellow'
        Write-Host '  -Check：结论如下，什么都没写' -ForegroundColor Yellow
        KeyVal 'SoC'    $(if ($variant -eq 'a0') { 'A0' } elseif ($variant -eq 'b0') { 'B0+' } else { '未知' })
        KeyVal 'mtd0'   ("0x{0} ({1} 字节)" -f $mtd0Hex, $mtd0Size)
        KeyVal 'U-Boot' $target
        KeyVal '解锁'   $(if ($needUnlock) { '需要（mtd-rw.ko）' } else { '不需要' })
        KeyVal 'sysupgrade 镜像' $(if ($variant -eq 'a0') { '*-a0-squashfs.sysupgrade.bin' } else { '*-squashfs.sysupgrade.bin' })
        Rule 'DarkYellow'
        Send-Line $stream 'exit'
        Start-Sleep -Milliseconds 300
        $client.Close()
        return
    }

    # 6) 下载
    Step "设备下载 $target"
    $r = Invoke-Dev "cd /tmp && wget $httpBase/$target" -TimeoutSec 300
    ($r.Output -split "`n") | Where-Object { $_.Trim() } | ForEach-Object { Note ("  " + $_.Trim()) }
    if ($r.Code -ne 0) { Bad "wget 失败 (exit $($r.Code))"; throw '下载失败' }
    Ok '下载完成'

    # 7) 校验（PC 比对）
    Step '校验设备上的文件'
    if ($caps['wc']) {
        $r = Invoke-Dev "wc -c < /tmp/$target" -TimeoutSec 30
        $szM = [regex]::Match($r.Output, '(\d+)')
        if ($r.Code -ne 0) { Bad "wc 执行失败 (exit $($r.Code))"; throw '长度读取失败' }
        if (-not $szM.Success) { Bad "wc 输出无法解析: $($r.Output.Trim())"; throw '长度读取失败' }
        $devSize = [int64]$szM.Groups[1].Value
        if ($devSize -ne $localSize) { Bad "长度不一致: 设备 $devSize / 本地 $localSize"; throw '长度校验失败' }
        Ok "长度一致 ($devSize 字节)"
    } else { Warn '设备没有 wc，跳过长度校验' }
    if ($caps['md5sum']) {
        $r = Invoke-Dev "md5sum /tmp/$target" -TimeoutSec 60
        if ($r.Code -ne 0) { Bad "md5sum 执行失败 (exit $($r.Code))"; throw 'md5 读取失败' }
        $md5M = [regex]::Match($r.Output, '([0-9a-fA-F]{32})')
        if (-not $md5M.Success) { Bad "md5sum 输出无法解析: $($r.Output.Trim())"; throw 'md5 读取失败' }
        $devMd5 = $md5M.Groups[1].Value.ToLower()
        if ($devMd5 -ne $localMd5) { Bad "md5 不一致: 设备 $devMd5 / 本地 $localMd5"; throw 'md5 校验失败' }
        Ok "md5 一致 ($devMd5)"
    } else { Warn '设备没有 md5sum，只校验了长度' }

    # 8) 解锁（只在必要时）
    if ($needUnlock) {
        Step '下载 mtd-rw.ko + mtd'
        $r = Invoke-Dev "cd /tmp && wget $httpBase/mtd-rw.ko" -TimeoutSec 120
        if ($r.Code -ne 0) { Bad 'mtd-rw.ko 下载失败'; throw '下载失败' }
        $r = Invoke-Dev "cd /tmp && wget $httpBase/mtd && chmod +x /tmp/mtd" -TimeoutSec 120
        if ($r.Code -ne 0) { Bad 'mtd 下载失败'; throw '下载失败' }
        Step 'insmod mtd-rw.ko i_want_a_brick=1'
        $r = Invoke-Dev 'insmod /tmp/mtd-rw.ko i_want_a_brick=1' -TimeoutSec 60
        ($r.Output -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 3 | ForEach-Object { Note ("  " + $_.Trim()) }
        $ro2 = ((Invoke-Dev 'cat /sys/block/mtdblock0/ro' -TimeoutSec 30).Output).Trim()
        if ($ro2 -notmatch '^\s*0\s*$') { Bad "解锁失败（ro=$ro2），不要继续"; throw '解锁失败' }
        Ok 'mtd0 已解锁（ro=0）'
    }

    # 9) 写入
    Step '写入 mtd0'
    if ($needUnlock) { $r = Invoke-Dev "cd /tmp && ./mtd write /tmp/$target /dev/mtd0" -TimeoutSec 900 }
    else { $r = Invoke-Dev "dd if=/tmp/$target of=/dev/mtdblock0" -TimeoutSec 900 }
    ($r.Output -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 3 | ForEach-Object { Note ("  " + $_.Trim()) }
    if ($r.Code -ne 0) { Bad "写入失败 (exit $($r.Code))"; throw '写入失败' }
    Ok '写入完成'

    # 10) 回读比对
    if ($caps['md5sum'] -and $caps['dd']) {
        Step '回读前 64 KiB 比对'
        $rbOut = (Invoke-Dev 'dd if=/dev/mtdblock0 bs=1024 count=64 2>/dev/null | md5sum' -TimeoutSec 120).Output
        $rbM = [regex]::Match($rbOut, '([0-9a-fA-F]{32})')
        if ($rbM.Success) {
            $devRb = $rbM.Groups[1].Value.ToLower()
            $fs = [System.IO.File]::OpenRead($localPath)
            $buf = New-Object byte[] 65536
            $read = $fs.Read($buf, 0, 65536)
            $fs.Close()
            $md5 = [System.Security.Cryptography.MD5]::Create()
            $localRb = ([BitConverter]::ToString($md5.ComputeHash($buf[0..($read - 1)])) -replace '-', '').ToLower()
            if ($devRb -ne $localRb) { Bad "回读不一致: 设备 $devRb / 本地 $localRb"; throw '回读校验失败' }
            Ok "回读一致 ($devRb)"
        } else { Warn '回读没有输出 md5，跳过比对' }
    } else { Warn '设备缺 dd/md5sum，跳过回读比对' }

    # ------------------------------------------------------------- [4] 重启
    Send-Line $stream 'reboot'
    Start-Sleep -Milliseconds 600
    try { $client.Close() } catch { }

    Phase 4 '重启并等待 initramfs 起来'
    Note 'U-Boot 顺序：UBI（空）-> USB（没插）-> TFTP，所以会自己来取镜像'
    if (-not (Wait-Port -IP $DeviceIp -PortNo 22 -TimeoutSec $BootTimeoutSec -Label 'initramfs ssh')) {
        Bad '等不到设备的 22 端口'
        Note '检查：服务是否还在、网线是否在 LAN 口、U-Boot 是否真的写进去了'
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
        $pattern = if ($variant -eq 'a0') { 'openwrt-*-meraki_mx64-a0-squashfs.sysupgrade.bin' }
                   else { 'openwrt-*-meraki_mx64-squashfs.sysupgrade.bin' }
        $cand = Get-ChildItem (Join-Path $filesDir $pattern) -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
        if (-not $cand) { throw "files/ 里找不到 $pattern" }
        $img = $cand.FullName
    }
    if (-not (Test-Path $img)) { throw "找不到 sysupgrade 文件: $img" }

    KeyVal 'Image' (Split-Path $img -Leaf)
    KeyVal 'Size'  ('{0:N1} MB' -f ((Get-Item $img).Length / 1MB))

    $scpOpts = @('-O', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')
    $sshOpts = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')

    Step 'scp 上传到 /tmp'
    $remote = '/tmp/' + (Split-Path $img -Leaf)
    & scp @scpOpts $img "root@${DeviceIp}:$remote" 2>&1 | ForEach-Object { Note $_ }
    if ($LASTEXITCODE -ne 0) { throw 'scp 上传失败' }
    Ok '上传完成'

    Step 'sysupgrade -n（不保留配置）'
    Note '设备会校验镜像然后自己重启，SSH 断开是正常的'
    & ssh @sshOpts "root@$DeviceIp" "sysupgrade -n $remote" 2>&1 | ForEach-Object { Note $_ }
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { Warn "sysupgrade 返回 $rc（连接被断开时也常见，看下面能否重新连上）" }
    else { Ok 'sysupgrade 已下发' }

    Step '等待系统重新起来'
    Start-Sleep -Seconds 8
    if (Wait-Port -IP $DeviceIp -PortNo 22 -TimeoutSec $SshTimeoutSec -Label 'OpenWrt ssh') {
        Ok 'OpenWrt 已启动（ssh 端口打开）'
    } else {
        Warn '等不到 ssh；可能还在写 flash，稍等再试 ping/ssh'
    }

    Write-Host ''
    Rule 'DarkGreen'
    Write-Host '  完成' -ForegroundColor Green
    Rule 'DarkGreen'
    KeyVal 'Elapsed' (Now2)
    KeyVal 'U-Boot'  $target
    KeyVal 'Image'   (Split-Path $img -Leaf)
    KeyVal 'Device'  $DeviceIp
    Write-Host ''
    Note '下一步：ssh root@192.168.1.1 设密码；可选做第 10 节释放 flash 空间'
    Rule 'DarkGreen'
}
catch {
    Write-Host ''
    Rule 'DarkRed'
    Write-Host ("  中断: " + $_.Exception.Message) -ForegroundColor Red
    Rule 'DarkRed'
    Note ("日志: $httpLog" + $(if ($logs['tftp']) { "  " + $logs['tftp'] } else { '' }))
    Stop-Servers
    exit 1
}
finally {
    Stop-Servers
}
