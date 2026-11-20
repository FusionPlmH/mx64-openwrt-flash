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
    [switch]$DryRun,
    [switch]$Probe
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

function Read-Bytes {
    param([System.IO.Stream]$Stream, [int]$Ms = 1000)
    $buf = New-Object byte[] 8192
    $list = New-Object System.Collections.Generic.List[byte]
    $deadline = (Get-Date).AddMilliseconds($Ms)
    while ((Get-Date) -lt $deadline) {
        try {
            $n = $Stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            for ($i = 0; $i -lt $n; $i++) { $list.Add($buf[$i]) }
        } catch { }
    }
    return ,$list.ToArray()
}

function Read-Available {
    param([System.IO.Stream]$Stream, [int]$Ms = 1000, [System.Text.Decoder]$Decoder)
    $arr = Read-Bytes -Stream $Stream -Ms $Ms
    if ($arr.Length -eq 0) { return '' }
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
KeyVal 'Mode'       $(if ($Check) { '仅检测（不写 NAND）' } elseif ($Probe) { '仅探测 mtd 工具（不擦不写）' } elseif ($DryRun) { '只看计划' } else { '真刷' })

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
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    function Invoke-Dev {
        param([string]$Command, [int]$TimeoutSec = 120, [switch]$Binary)
        $id = Get-Random -Minimum 100000 -Maximum 999999
        $begin = "B$id"
        $end = "E$id"
        Send-Line -Stream $stream -Line "echo $begin; $Command; echo $end`$?"
        $acc = New-Object System.Collections.Generic.List[byte]
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $code = $null
        $payload = @()
        while ((Get-Date) -lt $deadline) {
            $chunk = Read-Bytes -Stream $stream -Ms 700
            if ($chunk.Length -gt 0) { foreach ($b in $chunk) { $acc.Add($b) } }
            if ($acc.Count -eq 0) { continue }
            # 用 latin1 做字节安全的文本匹配（1 字节 = 1 字符），再切回字节
            $s = $latin1.GetString($acc.ToArray())
            $ms = [regex]::Matches($s, "(?s)$begin\r?\n(.*?)\r?\n?$end(\d+)")
            if ($ms.Count -gt 0) {
                $hit = $ms[$ms.Count - 1]      # 命令回显那行也含标记，取最后一次
                $payload = $latin1.GetBytes($hit.Groups[1].Value)
                $code = [int]$hit.Groups[2].Value
                break
            }
        }
        if ($null -eq $code) { $code = -1 }
        # telnet 会把 0xFF 转义成 0xFF 0xFF，还原回来
        $out = New-Object System.Collections.Generic.List[byte]
        $i = 0
        while ($i -lt $payload.Length) {
            if ($payload[$i] -eq 0xFF -and ($i + 1) -lt $payload.Length -and $payload[$i + 1] -eq 0xFF) {
                $out.Add(0xFF); $i += 2
            } else {
                $out.Add($payload[$i]); $i += 1
            }
        }
        $bytes = $out.ToArray()
        if ($Binary) { return @{ Code = $code; Bytes = $bytes } }
        return @{ Code = $code; Output = [System.Text.Encoding]::UTF8.GetString($bytes) }
    }

    # busybox 1.7.2 的 wget 不覆盖已存在文件（报 "can't open ...: File exists" 并 exit 1），
    # 所以每次都先删再下，否则重跑脚本必挂。
    function Invoke-Fetch {
        param([string]$Name, [int]$TimeoutSec = 300, [switch]$Exec)
        $tail = if ($Exec) { " && chmod +x /tmp/$Name" } else { '' }
        Invoke-Dev "cd /tmp && rm -f $Name && wget $httpBase/$Name$tail" -TimeoutSec $TimeoutSec
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

    # 布局安全校验：不看分区名（各家 diag 的分区表不一样），直接看 mtd0 里装的是什么
    $names = @([regex]::Matches($mtdTxt, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $mtd0Name = ''
    $m0 = [regex]::Match($mtdTxt, '(?m)^mtd0:\s*[0-9a-fA-F]+\s+[0-9a-fA-F]+\s+"([^"]+)"')
    if ($m0.Success) { $mtd0Name = $m0.Groups[1].Value }
    Ok ("mtd0 名称 = '$mtd0Name'，分区: $($names -join ', ')")

    Step '读 mtd0 前 512 字节（确认它真的是 bootloader）'
    $head = Invoke-Dev 'dd if=/dev/mtdblock0 bs=512 count=1 2>/dev/null' -TimeoutSec 60 -Binary
    if ($head.Code -ne 0 -or $head.Bytes.Length -lt 64) {
        Bad "读不到 mtd0 头部（exit=$($head.Code), $($head.Bytes.Length) 字节）"
        Note '不敢凭空写入，已停止'
        throw '无法确认 mtd0 内容'
    }
    $headAscii = -join ($head.Bytes | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
    $isArmBranch = ($head.Bytes.Length -ge 4 -and $head.Bytes[3] -eq 0xEA)
    $looksUboot = ($headAscii -match 'U-Boot') -or ($headAscii -match 'Meraki')
    Note ("头 4 字节: " + (($head.Bytes[0..3] | ForEach-Object { '{0:x2}' -f $_ }) -join ' '))
    if ($headAscii -match '[\x20-\x7e]{8,}') {
        $strs = @([regex]::Matches($headAscii, '[\x20-\x7e]{8,}') | ForEach-Object { $_.Value } | Select-Object -First 3)
        foreach ($s in $strs) { Note ("文本: " + $s) }
    }
    if (-not $isArmBranch -or -not $looksUboot) {
        Bad 'mtd0 里的内容不像 U-Boot（不是 ARM 跳转指令 / 没有 U-Boot 字符串）'
        Note '这台设备的 boot 分区可能不是 bootloader，写进去会变砖，已停止'
        throw 'mtd0 内容不符'
    }
    Ok 'mtd0 里确实是 U-Boot'
    $backupDir = Join-Path $kitRoot 'backup'
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory $backupDir | Out-Null }
    $headFile = Join-Path $backupDir ("mtd0-head-{0}.bin" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [System.IO.File]::WriteAllBytes($headFile, $head.Bytes)
    Ok ("原 mtd0 头部已存: $headFile")

    # 3) 写保护
    Step '读 mtd0 写保护状态'
    $roTxt = ((Invoke-Dev 'cat /sys/block/mtdblock0/ro').Output).Trim()
    $needUnlock = ($roTxt -match '^\s*1\s*$')
    $rwLoaded = $false
    if ($needUnlock) {
        # /sys/block/mtdblock0/ro 是块设备属性，mtd-rw 不会改它，所以它永远是 1；
        # 真正要看的是模块有没有加载。
        $mods = (Invoke-Dev 'cat /proc/modules' -TimeoutSec 30).Output
        $rwLoaded = ($mods -match '(?m)^mtd_rw\s')
        if ($rwLoaded) { Ok 'mtd0 已解锁（mtd_rw 已在 /proc/modules 里，ro=1 是块设备的静态属性，正常）' }
        else { Warn 'mtd0 有写保护（ro=1，且 mtd_rw 未加载）-> 需要 mtd-rw.ko' }
    }
    else { Ok "mtd0 可写（ro=$roTxt）" }

    # 3b) mtd 工具要 /dev/mtd0 字符设备（不是 mtdblock）；没有就试着 mknod
    Step '检查 /dev/mtd0 字符设备'
    $dev0 = ((Invoke-Dev 'ls /dev/mtd0 2>&1' -TimeoutSec 30).Output).Trim()
    $hasMtd0 = ($dev0 -match '^/dev/mtd0')
    if ($hasMtd0) { Ok '/dev/mtd0 存在' }
    else {
        $r = Invoke-Dev 'mknod /dev/mtd0 c 90 0 2>&1; ls /dev/mtd0 2>&1' -TimeoutSec 30
        $hasMtd0 = ($r.Output -match '^/dev/mtd0')
        if ($hasMtd0) { Ok '已用 mknod 建出 /dev/mtd0' }
        else { Warn "没有 /dev/mtd0 也建不出来: $($r.Output.Trim())" }
    }
    $mtdNodes = ((Invoke-Dev 'ls /dev/mtd* 2>&1' -TimeoutSec 30).Output).Trim() -replace '\s+', ' '
    Note "  /dev: $mtdNodes"

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
        $fitName = if ($variant -eq 'a0') { 'openwrt-bcm53xx-generic-meraki_mx64-a0-initramfs.bin' }
                   else { 'openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin' }
        $transName = if ($variant -eq 'a0') { 'openwrt-bcm5862x-generic-meraki_mx64a0-initramfs-kernel.bin' }
                     else { 'openwrt-bcm5862x-generic-meraki_mx64-initramfs-kernel.bin' }
        $sysPat = if ($variant -eq 'a0') { 'openwrt-*-meraki_mx64-a0-squashfs.sysupgrade.bin' }
                  else { 'openwrt-*-meraki_mx64-squashfs.sysupgrade.bin' }
        $sysCand = Get-ChildItem (Join-Path $filesDir $sysPat) -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending | Select-Object -First 1
        $sysName = if ($sysCand) { $sysCand.Name } else { "（files/ 里没有 $sysPat）" }
        $needTrans = ($target -eq 'uboot_mx64_small')

        Write-Host ''
        Rule 'DarkYellow'
        Write-Host '  -Check：结论如下，什么都没写' -ForegroundColor Yellow
        Rule 'DarkYellow'
        KeyVal 'SoC'       $(if ($variant -eq 'a0') { 'A0' } elseif ($variant -eq 'b0') { 'B0+' } else { '未知（按 B0+ 处理）' })
        KeyVal 'mtd0'      ("0x{0} ({1} 字节)" -f $mtd0Hex, $mtd0Size)
        KeyVal 'DevNodes'  $mtdNodes
        KeyVal 'Target'    $target
        KeyVal 'Unlock'    $(if (-not $needUnlock) { '不需要（直接 dd）' } elseif ($rwLoaded) { '已解锁（mtd_rw 已在运行，直接 mtd write）' } else { '需要（insmod mtd-rw.ko + mtd write）' })
        if ($needTrans) {
            KeyVal 'Transition' "需要 -> $transName"
            KeyVal 'Initramfs'  '先用过渡固件换 1 MiB 布局，之后不需要 FIT initramfs'
        } else {
            KeyVal 'Transition' '不需要（mtd0 >= 1 MiB，直接引导 FIT initramfs）'
            KeyVal 'Initramfs'  $fitName
        }
        KeyVal 'Sysupgrade'  $sysName
        Write-Host ''
        Write-Host '  刷完之后的路径：' -ForegroundColor White
        if ($needTrans) {
            Note '1) 过渡固件 openwrt-bcm5862x-...-initramfs-kernel.bin（SPIM，bootbk）'
            Note '2) 里面跑 30-write-uboot-from-openwrt.sh 换成 1 MiB 布局'
            Note '3) sysupgrade（不要单独重启去测 U-Boot）'
        } else {
            Note '1) 重启 -> U-Boot 自动 UBI->USB->TFTP，拉 FIT initramfs（bootm）'
            Note '2) scp sysupgrade 到 /tmp'
            Note '3) ssh 里 sysupgrade -n'
        }
        Rule 'DarkYellow'
        Send-Line $stream 'exit'
        Start-Sleep -Milliseconds 300
        $client.Close()
        return
    }

    # 5b) -Probe：安全地验证 mtd 工具（只跑 unlock，不擦不写）
    if ($Probe) {
        Step '下载 mtd 工具'
        $r = Invoke-Fetch 'mtd' -Exec -TimeoutSec 120
        if ($r.Code -ne 0) {
            Bad "mtd 下载失败: $((($r.Output -split "`n") | Where-Object { $_.Trim() }) -join ' | ')"
            throw '下载失败'
        }
        Ok 'mtd 已下载'

        Step './mtd（确认能跑起来，动态库齐全）'
        $u = Invoke-Dev 'cd /tmp && ./mtd 2>&1' -TimeoutSec 60
        ($u.Output -split "`n") | Where-Object { $_.Trim() } | ForEach-Object { Note ("  " + $_.Trim()) }
        if ($u.Output -match 'Usage: mtd') { Ok 'mtd 可以执行' } else { Bad 'mtd 跑不起来（可能是 uClibc 版本/AArch 不对）' }

        # unlock 只是清 flash 的保护位，不擦不写，拿来试参数名最安全
        Step '试参数名：./mtd unlock <arg>'
        foreach ($arg in @('/dev/mtd0', 'mtd0', 'boot', '__nope__')) {
            $p = Invoke-Dev "cd /tmp && ./mtd unlock $arg 2>&1" -TimeoutSec 60
            $txt = (($p.Output -split "`n") | Where-Object { $_.Trim() }) -join ' | '
            if ($p.Output -match 'Could not open mtd device') { Warn "  $arg -> $txt（不认这个写法）" }
            else { Ok "  $arg -> $txt" }
        }

        Step 'dd 直读 /dev/mtd0（备用通路）'
        $d = Invoke-Dev 'dd if=/dev/mtd0 bs=4 count=1 2>&1' -TimeoutSec 60 -Binary
        if ($d.Code -eq 0 -and $d.Bytes.Length -ge 4) {
            Ok ("/dev/mtd0 可读，前 4 字节: " + (($d.Bytes[0..3] | ForEach-Object { '{0:x2}' -f $_ }) -join ' '))
        } else { Warn "/dev/mtd0 读不了（exit $($d.Code)）" }

        Rule 'DarkYellow'
        Note 'Probe 结束：没有擦除、没有写入'
        Send-Line $stream 'exit'
        Start-Sleep -Milliseconds 300
        $client.Close()
        return
    }

    # 6) 下载
    Step "设备下载 $target"
    $r = Invoke-Fetch $target -TimeoutSec 300
    ($r.Output -split "`n") | Where-Object { $_.Trim() } | ForEach-Object { Note ("  " + $_.Trim()) }
    if ($r.Code -ne 0) { Bad "wget 失败 (exit $($r.Code))"; throw '下载失败' }

    # 7) 校验长度（wget 的进度条不一定给 saved[]，设备也没有 wc，就用 dd 在 EOF 边界探测）
    Step '校验设备上的文件长度'
    $savedM = [regex]::Match($r.Output, 'saved\s*\[(\d+)\]')
    if ($savedM.Success) {
        $savedSize = [int64]$savedM.Groups[1].Value
        if ($savedSize -ne $localSize) { Bad "设备只收到 $savedSize 字节，本地是 $localSize（下载不完整）"; throw '长度校验失败' }
        Ok "长度一致 ($savedSize 字节，来自 wget)"
    } elseif ($caps['wc']) {
        $r2 = Invoke-Dev "wc -c < /tmp/$target" -TimeoutSec 30
        $szM = [regex]::Match($r2.Output, '(\d+)')
        if ($r2.Code -ne 0 -or -not $szM.Success) { Bad "取长度失败: $($r2.Output.Trim())"; throw '长度读取失败' }
        $devSize = [int64]$szM.Groups[1].Value
        if ($devSize -ne $localSize) { Bad "长度不一致: 设备 $devSize / 本地 $localSize"; throw '长度校验失败' }
        Ok "长度一致 ($devSize 字节)"
    } else {
        # 精确探测 EOF：skip 到 localSize-1 能读到 1 条、skip 到 localSize 读到 0 条 => 长度正好
        $p1 = Invoke-Dev "dd if=/tmp/$target bs=1 skip=$($localSize - 1) count=1 2>&1" -TimeoutSec 90
        $p2 = Invoke-Dev "dd if=/tmp/$target bs=1 skip=$localSize count=1 2>&1" -TimeoutSec 90
        $m1 = [regex]::Match($p1.Output, '(\d+)\+(\d+) records in')
        $m2 = [regex]::Match($p2.Output, '(\d+)\+(\d+) records in')
        if (-not ($m1.Success -and $m2.Success)) {
            Warn "长度探测没有输出 records（$($p1.Output.Trim()) / $($p2.Output.Trim())），改看内容比对"
        } elseif ([int64]$m1.Groups[1].Value -ge 1 -and [int64]$m2.Groups[1].Value -eq 0) {
            Ok "长度精确匹配 ($localSize 字节，dd EOF 探测)"
        } else {
            Bad "长度不符：skip $($localSize - 1) -> $($m1.Groups[1].Value) 条，skip $localSize -> $($m2.Groups[1].Value) 条（期望 1 / 0）"
            throw '长度校验失败'
        }
    }

    # 7b) 校验内容：有 md5sum 就比 md5，没有就比前 512 字节
    Step '校验设备上的文件内容'
    $headLen = [Math]::Min(512, $localSize)
    $localHead = New-Object byte[] $headLen
    $fsLocal = [System.IO.File]::OpenRead($localPath)
    [void]$fsLocal.Read($localHead, 0, $headLen)
    $fsLocal.Close()
    $localHeadHex = (($localHead | ForEach-Object { '{0:x2}' -f $_ }) -join '')

    if ($caps['md5sum']) {
        $r3 = Invoke-Dev "md5sum /tmp/$target" -TimeoutSec 60
        $md5M = [regex]::Match($r3.Output, '([0-9a-fA-F]{32})')
        if ($r3.Code -ne 0 -or -not $md5M.Success) { Bad "md5sum 失败: $($r3.Output.Trim())"; throw 'md5 读取失败' }
        $devMd5 = $md5M.Groups[1].Value.ToLower()
        if ($devMd5 -ne $localMd5) { Bad "md5 不一致: 设备 $devMd5 / 本地 $localMd5"; throw 'md5 校验失败' }
        Ok "md5 一致 ($devMd5)"
    } else {
        $dh = Invoke-Dev "dd if=/tmp/$target bs=512 count=1 2>/dev/null" -TimeoutSec 60 -Binary
        if ($dh.Code -ne 0 -or $dh.Bytes.Length -lt $headLen) {
            Bad "读设备文件头失败（exit=$($dh.Code), $($dh.Bytes.Length) 字节）"; throw '内容校验失败'
        }
        $devHeadHex = (($dh.Bytes[0..($headLen - 1)] | ForEach-Object { '{0:x2}' -f $_ }) -join '')
        if ($devHeadHex -ne $localHeadHex) {
            Bad "前 $headLen 字节不一致"
            Note ("设备: " + $devHeadHex.Substring(0, [Math]::Min(64, $devHeadHex.Length)) + '...')
            Note ("本地: " + $localHeadHex.Substring(0, [Math]::Min(64, $localHeadHex.Length)) + '...')
            throw '内容校验失败'
        }
        Ok "前 $headLen 字节一致（设备没有 md5sum，用逐字节比对）"
    }

    # 8) 解锁（只在必要时）+ 取 mtd 工具（擦写都要它）
    Step '下载 mtd 工具'
    $r = Invoke-Fetch 'mtd' -Exec -TimeoutSec 120
    if ($r.Code -ne 0) { Bad 'mtd 下载失败'; throw '下载失败' }

    if ($needUnlock) {
        Step '下载 mtd-rw.ko'
        $r = Invoke-Fetch 'mtd-rw.ko' -TimeoutSec 120
        if ($r.Code -ne 0) { Bad 'mtd-rw.ko 下载失败'; throw '下载失败' }

        Step 'insmod mtd-rw.ko i_want_a_brick=1'
        $r = Invoke-Dev 'cd /tmp && insmod mtd-rw.ko i_want_a_brick=1 2>&1; echo rc=$?' -TimeoutSec 60
        ($r.Output -split "`n") | Where-Object { $_.Trim() } | ForEach-Object { Note ("  " + $_.Trim()) }

        # 判断依据：模块是否在内核里 + dmesg 有没有那行。
        # 不能用 /sys/block/mtdblock0/ro：那是块设备属性，mtd-rw 改的是 mtd->flags，不会同步。
        $mods = (Invoke-Dev 'cat /proc/modules' -TimeoutSec 30).Output
        $loaded = ($mods -match '(?m)^mtd_rw\s')
        $dmesgTxt = (Invoke-Dev 'dmesg' -TimeoutSec 30).Output
        $flagSet = ($dmesgTxt -match 'mtd\d*: setting writeable flag')

        if ($loaded) { Ok 'mtd_rw 已加载（/proc/modules）' }
        if ($flagSet) { Ok 'dmesg 里看到 "setting writeable flag"' }
        if (-not ($loaded -or $flagSet)) {
            Bad 'mtd-rw.ko 没生效'
            Note '这个 .ko 的 vermagic 是 2.6.36.4brcmarm SMP preempt modversions ARMv7，和设备内核匹配，'
            Note '所以失败要多看上面的报错（符号 CRC 不匹配会报 disagrees about version of symbol）'
            throw '解锁失败'
        }
        Warn '注意：/sys/block/mtdblock0/ro 仍会显示 1，这是正常的，别拿它判断'
    }

    # 9) 写入
    Step '写入 mtd0'
    # 实测（-Probe）：这个 mtd 只认 /dev/mtd0 全路径，传 mtd0 / boot 都报
    # "Could not open mtd device"。加 -f 跳过 trx 校验（我们的镜像是裸 U-Boot，不是 TRX）。
    $pre = Invoke-Dev 'cd /tmp && ./mtd 2>&1' -TimeoutSec 60
    if ($pre.Output -notmatch 'Usage: mtd') {
        Warn "mtd 工具跑不起来: $((($pre.Output -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' / ')"
        Warn '改用 dd 直写 /dev/mtdblock0（mtdblock 会按块擦写，慢但可用）'
        $candidates = @()
    } else {
        Ok 'mtd 工具可用'
        $candidates = @('/dev/mtd0', 'mtd0', 'boot')
    }

    $wrote = $false
    foreach ($arg in $candidates) {
        if (-not $arg) { continue }
        Note "  试 ./mtd -f write /tmp/$target $arg"
        $r = Invoke-Dev "cd /tmp && ./mtd -f write /tmp/$target $arg 2>&1" -TimeoutSec 900
        ($r.Output -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 4 | ForEach-Object { Note ("    " + $_.Trim()) }
        if ($r.Code -eq 0) { Ok "写入完成（mtd $arg）"; $wrote = $true; break }
        Warn "  这个参数名不行（exit $($r.Code)），换下一个"
    }
    if (-not $wrote) {
        Warn 'mtd 写不进去，改用 dd'
        $r = Invoke-Dev "dd if=/tmp/$target of=/dev/mtdblock0" -TimeoutSec 900
        ($r.Output -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 3 | ForEach-Object { Note ("  " + $_.Trim()) }
        if ($r.Code -ne 0) { throw '写入失败' }
        Ok '写入完成（dd）'
    }

    # 10) 回读比对
    Step '回读 mtd0 前 512 字节比对'
    # 从字符设备读，避开 mtdblock 的页缓存（否则可能读到写之前的旧数据）
    $rbSrc = if ($hasMtd0) { '/dev/mtd0' } else { '/dev/mtdblock0' }
    $rb = Invoke-Dev "dd if=$rbSrc bs=512 count=1 2>/dev/null" -TimeoutSec 120 -Binary
    if ($rb.Code -ne 0 -or $rb.Bytes.Length -lt $headLen) {
        Warn "回读失败（exit=$($rb.Code), $($rb.Bytes.Length) 字节），无法确认，请自己核对"
    } else {
        $rbHex = (($rb.Bytes[0..($headLen - 1)] | ForEach-Object { '{0:x2}' -f $_ }) -join '')
        if ($rbHex -ne $localHeadHex) {
            Bad '回读和镜像不一致！'
            Note ("nand: " + $rbHex.Substring(0, [Math]::Min(64, $rbHex.Length)) + '...')
            Note ("file: " + $localHeadHex.Substring(0, [Math]::Min(64, $localHeadHex.Length)) + '...')
            throw '回读校验失败'
        }
        Ok "回读一致（前 $headLen 字节）"
    }

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
