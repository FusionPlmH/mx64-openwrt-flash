# =============================================================================
#  MX64 一键刷机（全部逻辑在 PC 侧）
#
#    powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1              # 默认：HTTP 下载 + U 盘冷启动
#    powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -Check      # 只看结论（含 mtd 工具验证）
#    powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -DryRun     # 只看计划
#
#  设备上不落任何脚本：PC 通过 telnet 一条一条发原始命令（cat / wget / dd ...），
#  解析、判断、校验全在 PC 完成。所以不依赖设备上的 sed / awk / 脚本能力。
#
#  流程（6 个阶段）：
#    [1] 环境检查    网卡 / python / ssh+scp / 暂存文件
#    [2] 起服务      只起 -Transport 那一种（默认 HTTP），给 diag 下载用
#    [3] 刷 U-Boot   探测能力 -> 读分区/写保护/SoC -> 下载 -> 校验 -> 写入 -> 整镜像回读
#    [4] 冷启动      提示拔电 -> 插 U 盘 -> 上电，然后等设备自己起来
#    [5] 关服务      HTTP 已经没用了
#    [6] sysupgrade  scp 上传 + ssh 执行，等系统回来
#
#  第 4 阶段为什么是拔电、而不是 reboot：
#    两台真机实测，写 mtd0 之后发 `reboot`，设备都回不来（常亮橙、网络全死），
#    而拔电源冷启动 + 插 U 盘一次就成功（约 77 秒起 initramfs）。
#    所以脚本不再负责重启，只负责在正确时刻让你拔电。
#
#  前提：设备已在 diagnostic mode；PC 网卡与设备同网段。
#        -ServerIp 不指定时自动选本机 192.168.1.x 地址，没有才回退到 192.168.1.2。
# =============================================================================

param(
    [string]$ServerIp = '',
    [string]$DeviceIp = '192.168.1.1',
    [string]$StockLanIp = '192.168.0.1',
    [int]$PrefixLength = 24,
    [int]$Port = 8000,
    [ValidateSet('http', 'tftp')]
    [string]$Transport = 'http',
    [ValidateSet('both', 'usb', 'tftp')]
    [string]$BootMedia = 'both',
    [switch]$NoTftp,
    [switch]$WarmReboot,
    [ValidateSet('ng', 'clayface')]
    [string]$Uboot = 'ng',
    [string]$SysupgradeFile = '',
    [int]$BootTimeoutSec = 900,
    [int]$HintSec = 120,
    [int]$SshTimeoutSec = 240,
    [switch]$Check,
    [switch]$SkipSysupgrade,
    [switch]$DryRun,
    [switch]$Probe
)

$ErrorActionPreference = 'Stop'
$kitRoot = Split-Path -Parent $PSScriptRoot
$filesDir = Join-Path $kitRoot 'files'

# 没显式给 -ServerIp 时，优先用本机已有的 192.168.1.x 地址（没有就按惯例回退到 .2）。
if (-not $ServerIp) {
    $autoIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -match '^192\.168\.1\.' -and $_.IPAddress -ne $DeviceIp } |
        Sort-Object { if ($_.IPAddress -eq '192.168.1.2') { 0 } else { 1 } } |
        Select-Object -First 1
    $ServerIp = if ($autoIp) { $autoIp.IPAddress } else { '192.168.1.2' }
}
$parsedIp = $null
if (-not [System.Net.IPAddress]::TryParse($ServerIp, [ref]$parsedIp)) {
    throw "-ServerIp 不是合法 IPv4 地址: $ServerIp"
}
$parsedDevIp = $null
if (-not [System.Net.IPAddress]::TryParse($DeviceIp, [ref]$parsedDevIp)) {
    throw "-DeviceIp 不是合法 IPv4 地址: $DeviceIp"
}

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

Write-Host ''
Write-Host '  这次的配置' -ForegroundColor White
KeyVal 'Device'     "$DeviceIp (telnet 23)"
KeyVal 'Server'     "$ServerIp  (diag 下载走 $Transport)"
KeyVal 'Boot'       $(if ($NoTftp) { 'U 盘冷启动（-NoTftp，不起 TFTP）' } elseif ($BootMedia -eq 'tftp') { 'TFTP 自动取 initramfs（不提示 U 盘）' } else { 'U 盘 + TFTP 双通道（U-Boot 自己选，先 USB 再 TFTP）' })
KeyVal 'U-Boot'     $(if ($Uboot -eq 'ng') { 'uboot_ng.bin（本项目，需 1 MiB 分区）' } else { 'clayface uboot_mx64 / uboot_mx64_small（按 mtd0 自动选）' })
KeyVal 'Sysupgrade' $(if ($SkipSysupgrade) { '跳过' } elseif ($SysupgradeFile) { $SysupgradeFile } else { '自动选最新的（按 A0/B0+ 匹配）' })
KeyVal 'Backup'     '跳过（默认）。要备份见 README「可选步骤」，在 initramfs 里用 scp 拉'
KeyVal 'Mode'       $(if ($Check) { '仅检测（含 mtd 工具验证，不写 NAND）' } elseif ($Probe) { '仅探测 mtd 工具（不擦不写）' } elseif ($DryRun) { '只看计划' } else { '真刷' })

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
    Note 'dd if=/dev/mtd0 bs=65536 skip=<n> count=1    # 整镜像回读（10 块，PC 逐字节比对）'
    Note '（不发 reboot）-> 提示你拔电、插 U 盘、上电'
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
    Note "  New-NetIPAddress -InterfaceIndex <索引> -IPAddress $ServerIp -PrefixLength $PrefixLength"
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

# ---- python 版本（http.server --directory 要 3.7+）----
$pyVerTxt = (& python --version 2>&1) -join ' '
$pyM = [regex]::Match($pyVerTxt, '(\d+)\.(\d+)')
if ($pyM.Success) {
    $pyMajor = [int]$pyM.Groups[1].Value
    $pyMinor = [int]$pyM.Groups[2].Value
    if ($pyMajor -lt 3 -or ($pyMajor -eq 3 -and $pyMinor -lt 7)) {
        Bad "python $pyMajor.$pyMinor 太老（http.server 的 --directory 需要 3.7+）"
        throw 'python 版本过低'
    }
    Ok "python $pyMajor.$pyMinor 可用"
}

# ---- 权限 / 防火墙：设备要从 PC 下载，入站端口被拦就前功尽弃 ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) { Ok '以管理员运行' }
else { Note '  非管理员运行（Windows 上绑 UDP 69 不需要管理员，一般没问题）' }

$nicAlias = ($hasIp | Select-Object -First 1).InterfaceAlias
if ($nicAlias) {
    $prof = Get-NetConnectionProfile -InterfaceAlias $nicAlias -ErrorAction SilentlyContinue
    if ($prof) {
        if ($prof.NetworkCategory -eq 'Public') {
            Warn "$nicAlias 是「公用网络」配置 -> Windows 防火墙可能拦入站 TCP/UDP"
            Note '  症状：设备 telnet/HTTP 连不上，或 U-Boot 的 TFTP 收不到回复'
            Note '  处理：把该网卡改成「专用」，或临时放行 python.exe'
        } else {
            Ok "$nicAlias 防火墙配置 = $($prof.NetworkCategory)"
        }
    }
}

# ---- 端口占用：上一轮没退干净的 python 服务会让本轮第 2 阶段直接失败 ----
# 只检查这轮真的要用到的端口：HTTP 给 diag 下载；TFTP 默认也起，让 U-Boot 能 USB/TFTP 二选一。
# （diag 模式的设备只有一个 wget、没有 tftp 客户端，所以下载一律走 HTTP）
if ($Transport -eq 'tftp') { Warn '-Transport tftp 无效：diag 的 busybox 没有 tftp 客户端，下载仍走 HTTP' }
if ($BootMedia -eq 'usb' -and -not $NoTftp) { Warn '-BootMedia usb 已过时：现在默认同时提供 USB 与 TFTP；只想提供 U 盘请用 -NoTftp' }
$needTftp = (-not $NoTftp) -and ($BootMedia -ne 'usb')
$busy = @()
if ($needTftp) {
    $udp69 = @(Get-NetUDPEndpoint -LocalPort 69 -ErrorAction SilentlyContinue)
    if ($udp69.Count -gt 0) { $busy += "UDP 69 被 pid $((($udp69 | Select-Object -ExpandProperty OwningProcess) -join ',')) 占用（TFTP）" }
}
$tcpPort = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
if ($tcpPort.Count -gt 0) { $busy += "TCP $Port 被 pid $((($tcpPort | Select-Object -ExpandProperty OwningProcess) -join ',')) 占用（HTTP）" }
if ($busy.Count -gt 0) {
    Bad '端口已被占用：'
    foreach ($b in $busy) { Note "  $b" }
    Note '多半是上一轮留下的 python 服务。先清理：'
    Note '  Get-CimInstance Win32_Process -Filter "Name=''python.exe''" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }'
    throw '端口被占用'
}
Ok ("端口空闲（{0}）" -f $(if ($needTftp) { "UDP 69 / TCP $Port" } else { "TCP $Port" }))

# ---- 本地镜像完整性：避免刷进旧版本或下坏的镜像 ----
# 优先用 SHA256SUMS（覆盖 files/ 下全部文件）；没有它才退回逐个 sidecar
$sumsFile = Join-Path $kitRoot 'SHA256SUMS'
if (Test-Path $sumsFile) {
    $badSum = @()
    $checked = 0
    foreach ($line in Get-Content $sumsFile) {
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+(.+)$') { continue }
        $want = $matches[1].ToLower()
        $rel = $matches[2].Trim()
        $tgt = Join-Path $kitRoot ($rel -replace '/', '\')
        if (-not (Test-Path $tgt)) { $badSum += "$rel 不存在"; continue }
        $checked++
        if ((Get-FileHash $tgt -Algorithm SHA256).Hash.ToLower() -ne $want) { $badSum += "$rel SHA256 不符" }
    }
    if ($badSum.Count -gt 0) {
        Bad 'SHA256SUMS 校验失败：'
        foreach ($b in $badSum) { Note "  $b" }
        Note '镜像被改过或下载不完整。别刷，先把 files/ 恢复成仓库里的版本'
        throw '镜像校验失败'
    }
    Ok "SHA256SUMS 覆盖的 $checked 个文件全部匹配"
} else {
    $sidecars = @(Get-ChildItem $filesDir -File | Where-Object { $_.Name -match '\.sha(256|512)$' })
    $badSum = @()
    foreach ($sc in $sidecars) {
        $tgt = Join-Path $filesDir $sc.BaseName
        if (-not (Test-Path $tgt)) { $badSum += "$($sc.Name) 对应的 $($sc.BaseName) 不存在"; continue }
        $alg = if ($sc.Extension -eq '.sha256') { 'SHA256' } else { 'SHA512' }
        $want = (((Get-Content $sc.FullName -Raw) -split '\s+') | Where-Object { $_ }) | Select-Object -First 1
        $got = (Get-FileHash $tgt -Algorithm $alg).Hash
        if ($got -ne $want.ToUpper()) { $badSum += "$($sc.BaseName) $alg 不符" }
    }
    if ($badSum.Count -gt 0) {
        Bad '镜像校验失败：'
        foreach ($b in $badSum) { Note "  $b" }
        throw '镜像损坏或版本不符'
    }
    Warn "没有 SHA256SUMS，只校验了 $($sidecars.Count) 个带 sidecar 的文件"
    Ok ("{0} 个镜像的校验和都对得上" -f $sidecars.Count)
}

# ---- U-Boot 版本标记：一眼确认刷进去的是哪个构建 ----
$ngPath = Join-Path $filesDir 'uboot_ng.bin'
if (Test-Path $ngPath) {
    $ngBytes = [System.IO.File]::ReadAllBytes($ngPath)
    $ngTxt = [System.Text.Encoding]::ASCII.GetString($ngBytes)
    $tagM = [regex]::Match($ngTxt, 'mx64-ng-[0-9a-zA-Z\.\-]+')
    $tag = if ($tagM.Success) { $tagM.Value } else { '（没找到 tag）' }
    KeyVal 'U-Boot 版本' ("$tag, {0:N0} 字节" -f $ngBytes.Length)
    if (-not $tagM.Success) { Warn 'uboot_ng.bin 里没有 mx64-ng tag，这镜像可能不是本项目构建的' }
}

# ---- 磁盘空间（暂存要 ~35 MB；跟随 %TEMP% 所在盘，不假定 C:）----
$tempDrive = (Split-Path -Qualifier $env:TEMP)
$freeMB = $null
if ($tempDrive -match '^[A-Za-z]:$') {
    $pd = Get-PSDrive -Name ($tempDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($pd -and $pd.Free) { $freeMB = [math]::Round($pd.Free / 1MB) }
}
if ($null -eq $freeMB) { Note "无法读取 $env:TEMP 所在盘的剩余空间，跳过检查" }
elseif ($freeMB -lt 200) { Warn "$tempDrive 盘只剩 $freeMB MB，暂存镜像可能失败" }
else { Ok "$tempDrive 盘剩余 $freeMB MB" }

$stage = Join-Path $env:TEMP "mx64-http-$Port"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory $stage | Out-Null
Copy-Item (Join-Path $filesDir '*') $stage -Force
Ok ("暂存 {0} 个文件 -> {1}" -f (Get-ChildItem $stage).Count, $stage)

# ----------------------------------------------------------------- [2] 服务
Phase 2 '启动传输服务'

$servers = @()
$logs = @{}
$keepServers = $false
$httpLog = Join-Path $env:TEMP "mx64-http-$Port.log"
# $stage 可能在带空格的用户名目录下（C:\Users\John Doe\...），Start-Process 不自动加引号
$httpArgs = @('-m', 'http.server', "$Port", '--bind', '0.0.0.0', '--directory', "`"$stage`"")
$servers += Start-Process python -ArgumentList $httpArgs `
    -PassThru -WindowStyle Hidden -RedirectStandardOutput $httpLog -RedirectStandardError "$httpLog.err"
$logs['http'] = $httpLog
Ok "HTTP  $httpBase  (pid $($servers[-1].Id))"

function Stop-Servers {
    foreach ($p in $servers) {
        if ($p -and -not $p.HasExited) { try { $p.Kill() } catch { } }
    }
}

# TFTP 默认和 HTTP 一起起：U-Boot 的引导链是 UBI -> USB -> TFTP，
# 两条路同时准备好，插不插 U 盘都能起，最后由日志判断到底走的哪条。
$tftpOk = $false
$tftpLog = Join-Path $env:TEMP "mx64-tftp-$Port.log"
if ($needTftp) {
    # 注意：$PSScriptRoot 里可能有空格（cisco mx64），Start-Process 的 -ArgumentList 不自动加引号
    $tftpPy = '"{0}"' -f (Join-Path $PSScriptRoot '70-tftp-server.py')
    $servers += Start-Process python -ArgumentList $tftpPy, '--dir', "`"$stage`"", '--port', '69' `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $tftpLog -RedirectStandardError "$tftpLog.err"
    $logs['tftp'] = $tftpLog
    Start-Sleep -Milliseconds 900
    if ($servers[-1].HasExited) {
        Bad 'TFTP 起不来（UDP 69 被占用或被防火墙拦）'
        Note "详情: $tftpLog.err"
        Note '可以用 -NoTftp 只用 U 盘继续（U-Boot 走到 TFTP 那步会自己失败跳过）'
        throw 'TFTP 服务启动失败'
    }
    $tftpOk = $true
    Ok "TFTP  $tftpBase  (pid $($servers[-1].Id), UDP 69)"
} else {
    Note '不启动 TFTP（-NoTftp 或 -BootMedia usb）：启动只靠 U 盘'
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
            @{ ip = $DeviceIp;     port = 80; hint = '80 开着（LuCI/OpenWrt，或原厂固件的管理页面 —— 都不是 diagnostic mode）' },
            @{ ip = $DeviceIp;     port = 22; hint = '设备已经在跑 OpenWrt（不是 diagnostic mode）' },
            @{ ip = $StockLanIp; port = 23; hint = "原厂固件 LAN 默认地址是 $StockLanIp" },
            @{ ip = $StockLanIp; port = 80; hint = "原厂固件 LAN 默认地址是 $StockLanIp" }
        )
        $found = $false
        $looksInstalled = $false
        foreach ($p in $probes) {
            if (Test-Port -IP $p.ip -PortNo $p.port -Ms 800) {
                $found = $true
                Warn ("但是 {0}:{1} 是通的 -> {2}" -f $p.ip, $p.port, $p.hint)
                if ($p.ip -eq $DeviceIp -and $p.port -eq 22) { $looksInstalled = $true }
            }
        }
        if ($looksInstalled) {
            Write-Host ''
            Ok "$DeviceIp`:22 开着，说明 OpenWrt 已经装好了 —— 这个脚本没事可做"
            Note "如果只是想确认系统状态：ssh root@$DeviceIp"
            Note '如果是要换 U-Boot：mtd0 在 OpenWrt 下是只读的，得让 U-Boot 自己刷自己 ——'
            Note '  见 README「进了 OpenWrt 之后重新刷 U-Boot」'
            throw "OpenWrt 已安装，跳过刷机"
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

    # 验证设备上的 mtd 工具：能不能跑、unlock 认哪种写法、dd 直读通不通。
    # 只清保护位和读数据，不擦不写 NAND；-Check 和 -Probe 共用。
    function Test-MtdTool {
        $res = @{ Downloaded = $false; RunOk = $false; UnlockArg = ''; DdOk = $false; DdHead = '' }

        Step '下载 mtd 工具'
        $r = Invoke-Fetch 'mtd' -Exec -TimeoutSec 120
        if ($r.Code -ne 0) {
            Warn "mtd 下载失败: $((($r.Output -split "`n") | Where-Object { $_.Trim() }) -join ' | ')"
            return $res
        }
        $res.Downloaded = $true
        Ok 'mtd 已下载'

        Step './mtd（确认能跑起来，动态库齐全）'
        $u = Invoke-Dev 'cd /tmp && ./mtd 2>&1' -TimeoutSec 60
        ($u.Output -split "`n") | Where-Object { $_.Trim() } | ForEach-Object { Note ("  " + $_.Trim()) }
        $res.RunOk = ($u.Output -match 'Usage: mtd')
        if ($res.RunOk) { Ok 'mtd 可以执行' } else { Bad 'mtd 跑不起来（可能是 uClibc 版本/AArch 不对）' }

        # unlock 只是清 flash 的保护位，不擦不写，拿来试参数名最安全
        Step '试参数名：./mtd unlock <arg>'
        foreach ($arg in @('/dev/mtd0', 'mtd0', 'boot', '__nope__')) {
            $p = Invoke-Dev "cd /tmp && ./mtd unlock $arg 2>&1" -TimeoutSec 60
            $txt = (($p.Output -split "`n") | Where-Object { $_.Trim() }) -join ' | '
            if ($p.Output -match 'Could not open mtd device') {
                Warn "  $arg -> $txt（不认这个写法）"
            } else {
                Ok "  $arg -> $txt"
                if (-not $res.UnlockArg) { $res.UnlockArg = $arg }
            }
        }

        Step 'dd 直读 /dev/mtd0（备用通路）'
        $d = Invoke-Dev 'dd if=/dev/mtd0 bs=4 count=1 2>&1' -TimeoutSec 60 -Binary
        if ($d.Code -eq 0 -and $d.Bytes.Length -ge 4) {
            $res.DdOk = $true
            $res.DdHead = (($d.Bytes[0..3] | ForEach-Object { '{0:x2}' -f $_ }) -join ' ')
            Ok ("/dev/mtd0 可读，前 4 字节: " + $res.DdHead)
        } else {
            Warn "/dev/mtd0 读不了（exit $($d.Code)）"
        }
        return $res
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

    # FIT initramfs 的文件名必须和 U-Boot 内置的 initramfs_filename / initramfs_filename_a0 完全一致
    $fitName = if ($variant -eq 'a0') { 'openwrt-bcm53xx-generic-meraki_mx64-a0-initramfs.bin' }
               else { 'openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin' }

    if ($Check) {
        # -Check 顺带跑 mtd 工具验证（原 -Probe 的内容），仍然不擦不写
        $mtdTest = Test-MtdTool

        $transName = if ($variant -eq 'a0') { 'openwrt-bcm5862x-generic-meraki_mx64a0-initramfs-kernel.bin' }
                     else { 'openwrt-bcm5862x-generic-meraki_mx64-initramfs-kernel.bin' }
        $sysPat = if ($variant -eq 'a0') { 'openwrt-*-meraki_mx64-a0-squashfs.sysupgrade.bin' }
                  else { 'openwrt-*-meraki_mx64-squashfs.sysupgrade.bin' }
        $sysCand = Get-ChildItem (Join-Path $filesDir $sysPat) -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending | Select-Object -First 1
        $sysName = if ($sysCand) { $sysCand.Name } else { "（files/ 里没有 $sysPat）" }
        $needTrans = ($target -eq 'uboot_mx64_small')

        $mtdToolTxt =
            if (-not $mtdTest.Downloaded) { '没验证（mtd 下载失败）' }
            elseif (-not $mtdTest.RunOk) { '跑不起来（uClibc/AArch 不匹配）' }
            else {
                $argTxt = if ($mtdTest.UnlockArg) { "unlock 认 $($mtdTest.UnlockArg)" } else { 'unlock 打不开 mtd0（只读或节点缺失）' }
                $ddTxt = if ($mtdTest.DdOk) { "dd 直读 $($mtdTest.DdHead)" } else { 'dd 直读失败' }
                "可执行，$argTxt，$ddTxt"
            }

        Write-Host ''
        Rule 'DarkYellow'
        Write-Host '  -Check：结论如下，什么都没写' -ForegroundColor Yellow
        Rule 'DarkYellow'
        KeyVal 'SoC'       $(if ($variant -eq 'a0') { 'A0' } elseif ($variant -eq 'b0') { 'B0+' } else { '未知（按 B0+ 处理）' })
        KeyVal 'mtd0'      ("0x{0} ({1} 字节)" -f $mtd0Hex, $mtd0Size)
        KeyVal 'DevNodes'  $mtdNodes
        KeyVal 'MtdTool'   $mtdToolTxt
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
            Note '1) 拔电 -> 插 U 盘 -> 上电（U-Boot 走 USB，白灯闪三下后加载）'
            Note '2) scp sysupgrade 到 /tmp'
            Note '3) ssh 里 sysupgrade -n'
        }
        Rule 'DarkYellow'
        Send-Line $stream 'exit'
        Start-Sleep -Milliseconds 300
        $client.Close()
        return
    }

    # 5b) -Probe：只跑 mtd 工具验证（-Check 已包含，保留兼容）
    if ($Probe) {
        Test-MtdTool | Out-Null

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

    # 8) 解锁（只在必要时）+ 取 mtd 工具
    if ($needUnlock) {
        Step '下载 mtd-rw.ko'
        $r = Invoke-Fetch 'mtd-rw.ko' -TimeoutSec 120
        if ($r.Code -ne 0) { Bad 'mtd-rw.ko 下载失败'; throw '下载失败' }

        Step '下载 mtd'
        $r = Invoke-Fetch 'mtd' -Exec -TimeoutSec 120
        if ($r.Code -ne 0) { Bad 'mtd 下载失败'; throw '下载失败' }

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

    # 9) 写入 —— 严格按 OpenWrt wiki 的两种写法
    Step '写入 mtd0'
    if ($needUnlock) {
        # wiki: wget mtd && chmod +x mtd && ./mtd write uboot_mx64 /dev/mtd0
        $pre = Invoke-Dev 'cd /tmp && ./mtd 2>&1' -TimeoutSec 60
        if ($pre.Output -match 'Usage: mtd') {
            Ok 'mtd 工具可用'
            $r = Invoke-Dev "cd /tmp && ./mtd write /tmp/$target /dev/mtd0" -TimeoutSec 900
        } else {
            Warn "mtd 跑不起来: $((($pre.Output -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' / ')"
            Warn '退回 dd 写 /dev/mtdblock0'
            $r = Invoke-Dev "dd if=/tmp/$target of=/dev/mtdblock0" -TimeoutSec 900
        }
    } else {
        # wiki: dd if=uboot_mx64 of=/dev/mtdblock0（mtd0 本来就可写时）
        $r = Invoke-Dev "dd if=/tmp/$target of=/dev/mtdblock0" -TimeoutSec 900
    }
    ($r.Output -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 4 | ForEach-Object { Note ("  " + $_.Trim()) }
    if ($r.Code -ne 0) { Bad "写入失败 (exit $($r.Code))"; throw '写入失败' }
    Ok '写入完成'

    # 10) 回读比对
    # 只比前 512 字节不够：真机上出现过头部对、后面是垃圾的情况。这里把整份镜像读回来逐字节比。
    # 从字符设备读，避开 mtdblock 的页缓存（否则可能读到写之前的旧数据）
    $rbSrc = if ($hasMtd0) { '/dev/mtd0' } else { '/dev/mtdblock0' }
    $localAll = [System.IO.File]::ReadAllBytes($localPath)
    $chunkSize = 65536
    $chunks = [int][Math]::Ceiling($localAll.Length / [double]$chunkSize)
    Step "回读 mtd0 整镜像比对（$localSize 字节，$chunks 块）"

    $got = New-Object byte[] $localAll.Length
    $firstBad = -1
    $readProblem = $null
    for ($ci = 0; $ci -lt $chunks; $ci++) {
        $off = $ci * $chunkSize
        $want = [Math]::Min($chunkSize, $localAll.Length - $off)
        $rb = Invoke-Dev "dd if=$rbSrc bs=$chunkSize skip=$ci count=1 2>/dev/null" -TimeoutSec 180 -Binary
        if ($rb.Code -ne 0 -or $rb.Bytes.Length -lt $want) {
            $readProblem = ("第 {0}/{1} 块回读不足（exit={2}，拿到 {3} 字节，期望 {4}）" -f ($ci + 1), $chunks, $rb.Code, $rb.Bytes.Length, $want)
            break
        }
        [Array]::Copy($rb.Bytes, 0, $got, $off, $want)
        for ($k = 0; $k -lt $want; $k++) {
            if ($got[$off + $k] -ne $localAll[$off + $k]) { $firstBad = $off + $k; break }
        }
        if ($firstBad -ge 0) { break }
        Write-Host ("`r          {0}/{1} 块一致" -f ($ci + 1), $chunks) -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ''

    if ($firstBad -ge 0) {
        Bad ("回读和镜像不一致，第一个不同的字节在 0x{0:x}（NAND 0x{1:x2} / 文件 0x{2:x2}）" -f $firstBad, $got[$firstBad], $localAll[$firstBad])
        Note '不要拔电重启 —— 这段就是起不来的原因。重跑本脚本再写一次'
        throw '回读校验失败'
    }
    if ($readProblem) {
        Warn "整镜像回读没做完：$readProblem"
        Note '写入本身已成功（上面 mtd/dd 没报错），只是没法全量确认，继续'
    } else {
        Ok "回读一致（整份 $localSize 字节，$chunks 块逐字节比对）"
    }

    # ------------------------------------------------------------- [4] 启动
    # U-Boot 的引导链是 UBI -> USB -> TFTP。脚本默认把两条路都准备好：
    # 插着 U 盘就走 USB，没插就让 U-Boot 自己 TFTP 取，用户不用先决定。
    Phase 4 $(if ($needTftp) { '冷启动：拔电 -> (可选)插 U 盘 -> 上电（U 盘 / TFTP 双通道）' } else { '冷启动：拔电 -> 插 U 盘 -> 上电' })

    Write-Host ''
    Write-Host '  mtd0 已写入并整份回读一致。' -ForegroundColor White
    Write-Host '  两台真机实测：写完 mtd0 发 reboot，设备都不回来（常亮橙、网络全死）；' -ForegroundColor White
    Write-Host '                拔电源冷启动才进得去 U-Boot。' -ForegroundColor White
    Write-Host ''
    Write-Host '  请按这个顺序做：' -ForegroundColor Yellow
    Write-Host '    1) 拔掉 MX64 的电源，等 3 秒' -ForegroundColor Yellow
    if ($needTftp) {
        Write-Host '    2) 想要更快就插上 U 盘；不想插也行，U-Boot 会自己 TFTP' -ForegroundColor Yellow
    } else {
        Write-Host '    2) 把 U 盘插到 MX64 的 USB 口' -ForegroundColor Yellow
    }
    Write-Host '    3) 插上电源' -ForegroundColor Yellow
    Write-Host ''
    Note 'U-Boot 顺序：UBI（起不来）-> USB（有盘就加载）-> TFTP（盘没有就用网络）'
    if ($needTftp) { Note "TFTP 服务已在 $tftpBase 跑着，U 盘和 TFTP 谁先成都行，日志会写清楚走的哪条" }
    if ($BootMedia -ne 'tftp') {
        Note 'U 盘要求（可选；脚本不替你写盘）：'
        Note '  - 单个分区，FAT16 或 FAT32'
        Note '  - 文件放在分区根目录（不要放进子目录）'
        Note "  - 文件名必须一字不差：$fitName"
        $usbSrc = Join-Path $filesDir $fitName
        if (Test-Path $usbSrc) {
            Note ("  - 源文件就是：files\$fitName  ({0:N1} MB)" -f ((Get-Item $usbSrc).Length / 1MB))
        } else {
            Warn "files\ 里没有 $fitName —— TFTP 那条路仍可用"
        }
    }
    Write-Host ''

    if ($WarmReboot) {
        Note '-WarmReboot：先试软重启（实测多数起不来，失败就拔电）'
        try { Send-Line $stream 'reboot' } catch { }
        Start-Sleep -Milliseconds 600
        try { $client.Close() } catch { }
    } else {
        try { Send-Line $stream 'exit' } catch { }
        Start-Sleep -Milliseconds 300
        try { $client.Close() } catch { }
    }

    # 等设备把系统跑起来：唯一判据是 22 端口
    $t0 = Get-Date
    $sawTftp = $false
    $tftpDone = $false
    $tftpFile = ''
    $warmHinted = $false
    $hinted = $false
    $booted = $false
    while (((Get-Date) - $t0).TotalSeconds -lt $BootTimeoutSec) {
        $el = [int]((Get-Date) - $t0).TotalSeconds

        if ($needTftp -and (Test-Path $tftpLog)) {
            $lines = @(Get-Content $tftpLog -EA SilentlyContinue)
            if (-not $sawTftp) {
                # 日志格式：  <文件名> -> <设备IP> (bytes, blksize, blocks)
                $hit = $lines | Where-Object { $_ -match ('->\s*' + [regex]::Escape($DeviceIp)) -or $_ -match 'NOT FOUND' } |
                       Select-Object -Last 1
                if ($hit) {
                    $sawTftp = $true
                    $mFile = [regex]::Match($hit, '^\s+(\S+)\s+->')
                    if ($mFile.Success) { $tftpFile = $mFile.Groups[1].Value }
                    Ok ("U-Boot 来取文件了: " + $hit.Trim())
                }
            }
            if (-not $tftpDone) {
                $done = $lines | Where-Object { $_ -match '^\s+(\S+)\s+done\s*$' } | Select-Object -Last 1
                if ($done) {
                    $tftpDone = $true
                    if (-not $tftpFile) { $tftpFile = ([regex]::Match($done, '^\s+(\S+)\s+done')).Groups[1].Value }
                    Ok ("TFTP 传输完成: " + $tftpFile)
                }
            }
        }

        if (Test-Port -IP $DeviceIp -PortNo 22 -Ms 800) { $booted = $true; break }

        if ($WarmReboot -and -not $warmHinted -and $el -ge 90) {
            $warmHinted = $true
            Write-Host ''
            Warn 'WarmReboot 90 秒还没起来 —— 和真机实测一致（软重启进不去 U-Boot）'
            Note '现在拔一次电源（等 3 秒再插上），脚本继续等'
            Write-Host ''
        }

        if (-not $hinted -and $el -ge $HintSec) {
            $hinted = $true
            Write-Host ''
            Warn ("已经 $el 秒还没等到 $DeviceIp`:22 打开")
            Note '按顺序查这几条：'
            Note '  1) 是拔电源冷启动的吗？只按 reboot 起不来，必须拔电'
            if ($BootMedia -ne 'tftp') {
                Note '  2) U 盘是 FAT16/FAT32、单分区、文件在根目录吗？'
                Note "     文件名一字不差吗？$fitName"
                Note '     白灯闪三下了吗？闪了=U-Boot 找到盘开始加载'
            }
            if ($needTftp) {
                Note '  3) TFTP 服务还活着吗（UDP 69 在监听）、网线在 LAN 口吗、防火墙放行了吗'
            }
            Note '  4) 白灯一次都不闪 = U-Boot 没走到任何一种恢复路径，只能接串口'
            Note '接串口 J1（115200 8N1, 3.3V TTL）能直接看到 U-Boot 每一句输出'
            Note '继续等待中……'
            Write-Host ''
        }

        if ($el % 15 -eq 0) {
            $state = if ($tftpDone) { 'TFTP 已传完，等系统起来' }
                     elseif ($sawTftp) { 'TFTP 传输中' }
                     else { '等设备启动（USB/TFTP 都会试）' }
            Note ("  {0,4}s  {1}" -f $el, $state)
        }
        Start-Sleep -Milliseconds 1000
    }

    if (-not $booted) {
        Bad ("等了 $BootTimeoutSec 秒，$DeviceIp`:22 还是连不上")
        Note 'mtd0 里确实写进了 U-Boot（整镜像逐字节回读一致），所以问题在"没冷启动"或"两种恢复路径都没成功"'
        if ($tftpDone) {
            Warn "TFTP 已经把 $tftpFile 传完，但系统没起来（内核/DTB 与 SoC 版本不匹配？）"
            Note '接串口看 bootm/bootbk 之后的输出'
        } elseif ($sawTftp) {
            Warn 'TFTP 收到过请求但没传完 —— 多半是链路/丢包，或服务端被防火墙拦'
            Note '先拔电重上电再试一次；仍不行接串口'
        } else {
            Note '全程没有 TFTP 请求，说明 U-Boot 没走到网络那一步'
            Note '先只做一件事：拔电源 -> 插 U 盘 -> 插电源，盯前面板的灯看一遍'
            Note '白灯一次都不闪 => 只能接串口 J1 查（115200 8N1, 3.3V TTL）'
        }
        # 别把服务关掉：超时可能只是人工操作慢，用户想马上再试一次
        $keepServers = $true
        throw '第 4 阶段失败'
    }

    # 判断这次到底是哪条路进来的（只靠 TFTP 日志 + 是否插了 U 盘无法区分 USB/UBI）
    $bootVia = if ($tftpDone) { "TFTP（$tftpFile）" }
               elseif ($sawTftp) { 'TFTP（传输未确认）' }
               elseif ($BootMedia -eq 'tftp') { 'TFTP 未使用 / 未知（无传输记录）' }
               else { 'USB 或 UBI（TFTP 无传输记录）' }
    Ok "initramfs 已启动（ssh 端口打开）"

    # ------------------------------------------------------------- [5] 关服务
    Phase 5 '关闭传输服务'
    # 拿到系统就立刻关 TFTP/HTTP：设备已经把这几个文件读进 RAM 了
    Stop-Servers
    Ok "传输服务已停止（HTTP + TFTP）"
    KeyVal 'Boot via' $bootVia
    if ($needTftp -and -not $tftpDone) {
        Note 'TFTP 日志里没有任何完成的传输 —— 这次是从 U 盘（或 NAND 里已装的系统）进来的'
    }

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
    KeyVal 'Boot via' $bootVia
    Write-Host ''
    Note "下一步：ssh root@$DeviceIp 设密码；可选做第 10 节释放 flash 空间"
    Rule 'DarkGreen'
}
catch {
    Write-Host ''
    Rule 'DarkRed'
    Write-Host ("  中断: " + $_.Exception.Message) -ForegroundColor Red
    Rule 'DarkRed'
    Note ("日志: $httpLog" + $(if ($logs['tftp']) { "  " + $logs['tftp'] } else { '' }))
    if (-not $keepServers) { Stop-Servers }
    else { Warn 'HTTP/TFTP 服务还在跑（想马上重试就直接再跑一遍脚本）' }
    exit 1
}
finally {
    # 第 4 阶段超时不关服务：那种情况多半是人工操作慢，用户会想立刻再试
    if (-not $keepServers) { Stop-Servers }
}
