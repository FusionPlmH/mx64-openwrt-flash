# =============================================================================
#  在 OpenWrt 里重新刷 U-Boot（不接串口、不拆机）
#
#    powershell -ExecutionPolicy Bypass -File scripts\05-reflash-uboot.ps1
#    powershell -ExecutionPolicy Bypass -File scripts\05-reflash-uboot.ps1 -UbootFile files\uboot_mx64
#    powershell -ExecutionPolicy Bypass -File scripts\05-reflash-uboot.ps1 -DryRun
#
#  OpenWrt 下 mtd0 是 DTS 只读的，diag 也随原厂 bootloader 一起没了，所以让 U-Boot 自己刷自己：
#    [1] mkenv.py 生成带 flash_uboot 的 bootcmd -> scp 上传 -> 写 mtd3（u-boot-env）
#    [2] PC 起 TFTP，提示断电再上电
#    [3] U-Boot 自己 TFTP 取镜像、校验、擦写 mtd0、回读 CRC，然后继续正常启动
#    [4] 设备回来后核对 mtd0 前 N 字节的 md5
#    [5] 把 bootcmd 恢复成默认再写一次 mtd3（避免每次开机都重刷）
# =============================================================================

param(
    [string]$DeviceIp = '192.168.1.1',
    [string]$ServerIp = '',
    [string]$UbootFile = '',
    [int]$BootTimeoutSec = 600,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$kitRoot = Split-Path -Parent $PSScriptRoot
$filesDir = Join-Path $kitRoot 'files'
$mkenvPy = Join-Path $kitRoot 'tools\mkenv.py'
$tftpSrv = Join-Path $kitRoot 'scripts\70-tftp-server.py'

function Rule { param([string]$Color = 'DarkGray') Write-Host ('-' * 68) -ForegroundColor $Color }
function Step([string]$m) { Write-Host ("        {0} ..." -f $m) -ForegroundColor Gray }
function Ok([string]$m)   { Write-Host ("   [ ok ] {0}" -f $m) -ForegroundColor Green }
function Warn([string]$m) { Write-Host ("   [ !  ] {0}" -f $m) -ForegroundColor Yellow }
function Bad([string]$m)  { Write-Host ("   [fail] {0}" -f $m) -ForegroundColor Red }
function Note([string]$m) { Write-Host ("          {0}" -f $m) -ForegroundColor DarkGray }

function Test-Port {
    param([string]$IP, [int]$PortNo, [int]$Ms = 1200)
    $c = New-Object Net.Sockets.TcpClient
    try { $ok = $c.ConnectAsync($IP, $PortNo).Wait($Ms); return [bool]$ok }
    catch { return $false }
    finally { $c.Close() }
}

function Wait-Port {
    param([string]$IP, [int]$PortNo, [int]$TimeoutSec, [string]$Label)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (Test-Port -IP $IP -PortNo $PortNo -Ms 800) {
            Write-Host ("`r" + (' ' * 72) + "`r") -NoNewline
            return $true
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

# ----------------------------------------------------------------- 准备
if (-not $UbootFile) { $UbootFile = Join-Path $filesDir 'uboot_ng.bin' }
$UbootFile = (Resolve-Path -LiteralPath $UbootFile).Path
$ubootName = Split-Path -Leaf $UbootFile
$ubootSize = (Get-Item $UbootFile).Length
$ubootMd5 = (Get-FileHash $UbootFile -Algorithm MD5).Hash.ToLower()

foreach ($exe in @('python', 'ssh', 'scp')) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { throw "找不到 $exe" }
}

# 没显式给 -ServerIp 时，优先用本机已有的 192.168.1.x 地址（没有就按惯例回退到 .2）。
if (-not $ServerIp) {
    $autoIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -match '^192\.168\.1\.' -and $_.IPAddress -ne $DeviceIp } |
        Sort-Object { if ($_.IPAddress -eq '192.168.1.2') { 0 } else { 1 } } |
        Select-Object -First 1
    $ServerIp = if ($autoIp) { $autoIp.IPAddress } else { '192.168.1.2' }
}
if (-not ($ServerIp -match '^\d+\.\d+\.\d+\.\d+$')) { throw "-ServerIp 不是合法 IPv4 地址: $ServerIp" }

# U-Boot 自己的地址：和 PC 同网段，避开设备与 PC
$serverPrefix = ($ServerIp -split '\.')[0..2] -join '.'
$ubootIp = "$serverPrefix.10"
if ($ubootIp -eq $DeviceIp) { $ubootIp = "$serverPrefix.11" }

$work = Join-Path $env:TEMP ("mx64-uboot-{0}" -f (Get-Random -Minimum 1000 -Maximum 9999))
$tftpDir = Join-Path $work 'tftp'
New-Item -ItemType Directory -Path $tftpDir -Force | Out-Null
Copy-Item -LiteralPath $UbootFile -Destination (Join-Path $tftpDir $ubootName) -Force
$envFlash = Join-Path $work 'env-flash.bin'
$envDefault = Join-Path $work 'env-default.bin'
$tftpLog = Join-Path $work 'tftp.log'
$tftpErr = Join-Path $work 'tftp.err'

trap {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    break
}

$bootcmd = "run soc_dtscheck; mx64init; flash_uboot $ubootName 100000 confirm; " +
           "run ubi_checkboot; run usb_checkboot; run tftp_checkboot; run meraki_checkboot"

Write-Host ''
Write-Host '  MX64：在 OpenWrt 里重新刷 U-Boot' -ForegroundColor Cyan
Rule 'DarkCyan'
Note "设备    : $DeviceIp"
Note "PC/TFTP : ${ServerIp}:69"
Note "U-Boot  : $ubootName ($ubootSize 字节, md5 $ubootMd5)"
Note "临时目录: $work"
Rule 'DarkCyan'

$scpOpts = @('-O', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')
$sshOpts = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')
$sshTarget = "root@$DeviceIp"

function Invoke-Ssh {
    param([string]$Command)
    $out = & ssh @sshOpts $sshTarget $Command 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($out)) {
        if ("$line".Trim()) { Note ("  " + "$line".Trim()) }
    }
    return $code
}

function Push-Env {
    param([string]$LocalPath, [string]$RemotePath)
    & scp @scpOpts $LocalPath "${sshTarget}:$RemotePath" 2>&1 | ForEach-Object { if ("$_".Trim()) { Note ("  " + "$_".Trim()) } }
    if ($LASTEXITCODE -ne 0) { throw "scp 上传 $LocalPath 失败" }
}

function Write-Env {
    param([string]$RemotePath)
    $code = Invoke-Ssh "mtd erase u-boot-env && dd if=$RemotePath of=/dev/mtd3 bs=4096 && sync"
    if ($code -ne 0) { throw '写 mtd3 失败（mtd erase u-boot-env 报错？）' }
}

# ----------------------------------------------------------------- [1] 生成 env
Step '生成带 flash_uboot 的 bootcmd'
& python $mkenvPy $UbootFile $envFlash "config_dts=config@4" "ipaddr=$ubootIp" "serverip=$ServerIp" "bootcmd=$bootcmd"
if ($LASTEXITCODE -ne 0) { throw 'mkenv.py 生成 env 失败' }
$envMd5 = (Get-FileHash $envFlash -Algorithm MD5).Hash.ToLower()
Ok "环境变量块已生成（md5 $envMd5）"

Step '生成恢复用的默认 env'
& python $mkenvPy $UbootFile $envDefault "config_dts=config@4" "ipaddr=$ubootIp" "serverip=$ServerIp"
if ($LASTEXITCODE -ne 0) { throw 'mkenv.py 生成默认 env 失败' }
$envDefaultMd5 = (Get-FileHash $envDefault -Algorithm MD5).Hash.ToLower()
Ok '默认环境变量块已生成'

if ($DryRun) {
    Write-Host ''
    Rule 'DarkYellow'
    Write-Host '  DryRun：真跑时会在设备上执行这些（env 已在临时目录生成好）' -ForegroundColor Yellow
    Note "scp $envFlash root@${DeviceIp}:/tmp/uboot-env-flash.bin"
    Note 'ssh root@...  "mtd erase u-boot-env && dd if=/tmp/uboot-env-flash.bin of=/dev/mtd3 bs=4096 && sync"'
    Note "python 70-tftp-server.py --dir <临时目录，里面只有 $ubootName>"
    Note '（提示拔电上电，U-Boot 自己 TFTP 取镜像 -> 校验 -> 擦写 mtd0 -> 回读 CRC）'
    Note "scp $envDefault root@${DeviceIp}:/tmp/uboot-env-default.bin   # 恢复 bootcmd"
    Rule 'DarkYellow'
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    return
}

# ----------------------------------------------------------------- [2] 写 mtd3
Step '上传并写入 mtd3（u-boot-env）'
Push-Env $envFlash '/tmp/uboot-env-flash.bin'
Write-Env '/tmp/uboot-env-flash.bin'
Ok 'bootcmd 已改成 flash_uboot'

Step '回读 mtd3 核对'
$remoteEnvMd5 = (& ssh @sshOpts $sshTarget 'dd if=/dev/mtd3 bs=4096 count=64 2>/dev/null | md5sum') -join ''
$remoteEnvMd5 = ($remoteEnvMd5 -split '\s+')[0].ToLower()
if ($remoteEnvMd5 -ne $envMd5) { throw "mtd3 回读 md5 不一致（设备 $remoteEnvMd5，本地 $envMd5）" }
Ok 'mtd3 内容一致'

# ----------------------------------------------------------------- [3] TFTP + 断电
$tftpProc = $null
$flashOk = $false
try {
    Step '启动 TFTP 服务'
    $tftpProc = Start-Process -FilePath 'python' `
        -ArgumentList @($tftpSrv, '--dir', $tftpDir) `
        -RedirectStandardOutput $tftpLog -RedirectStandardError $tftpErr `
        -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 900
    if ($tftpProc.HasExited) {
        Bad "TFTP 起不来（UDP 69 被占用？）: $(Get-Content $tftpErr -Raw -ErrorAction SilentlyContinue)"
        throw 'TFTP 启动失败'
    }
    Ok "TFTP 已启动（pid $($tftpProc.Id)，UDP 69）"

    Write-Host ''
    Write-Host '  现在做这一步：' -ForegroundColor Yellow
    Write-Host '    1) 拔掉 MX64 的电源' -ForegroundColor Yellow
    Write-Host '    2) 等 5 秒再插上' -ForegroundColor Yellow
    Write-Host '  上电后 U-Boot 会自己取镜像、刷 mtd0，然后继续启动系统。' -ForegroundColor Yellow

    $logPos = 0
    $lastBeat = -1
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $up = $false
    while ($sw.Elapsed.TotalSeconds -lt $BootTimeoutSec) {
        if (Test-Path $tftpLog) {
            $lines = @(Get-Content $tftpLog)
            if ($lines.Count -gt $logPos) {
                $lines[$logPos..($lines.Count - 1)] | ForEach-Object { if ("$_".Trim()) { Note ("  TFTP: " + "$_".Trim()) } }
                $logPos = $lines.Count
            }
        }
        if (Test-Port -IP $DeviceIp -PortNo 22 -Ms 800) { $up = $true; break }
        $sec = [int]$sw.Elapsed.TotalSeconds
        if ($sec -ne $lastBeat -and ($sec % 15) -eq 0) {
            $lastBeat = $sec
            Note ("  等待设备启动… {0}s / {1}s" -f $sec, $BootTimeoutSec)
        }
        Start-Sleep -Milliseconds 900
    }

    if (-not $up) {
        Bad "等了 $BootTimeoutSec 秒，$DeviceIp`:22 还是没起来"
        if (Test-Path $tftpLog) {
            Note 'TFTP 日志最后几行：'
            Get-Content $tftpLog -Tail 15 | ForEach-Object { Note ("  " + $_) }
        }
        Note '如果设备停在 U-Boot 提示符，接串口看 mx64info，或重跑本脚本'
        throw '设备没有回来'
    }
    Ok '设备已回到 OpenWrt'

    Step '核对 mtd0 前 N 字节（确认真的写进去了）'
    $remoteMtd0Md5 = (& ssh @sshOpts $sshTarget "dd if=/dev/mtd0 bs=$ubootSize count=1 2>/dev/null | md5sum") -join ''
    $remoteMtd0Md5 = ($remoteMtd0Md5 -split '\s+')[0].ToLower()
    if ($remoteMtd0Md5 -ne $ubootMd5) {
        Warn "mtd0 和 $ubootName 不一致（设备 $remoteMtd0Md5，本地 $ubootMd5）"
        Note '这次没刷成功；先把 bootcmd 恢复掉，重跑脚本或接串口处理'
        $flashOk = $false
    } else {
        Ok 'mtd0 内容一致，U-Boot 已更新'
        $flashOk = $true
    }
} finally {
    if ($tftpProc -and -not $tftpProc.HasExited) {
        Stop-Process -Id $tftpProc.Id -ErrorAction SilentlyContinue
        Ok 'TFTP 已停止'
    }

    # ------------------------------------------------------------- [4] 恢复 bootcmd
    if (-not $DryRun -and (Test-Port -IP $DeviceIp -PortNo 22 -Ms 1500)) {
        try {
            Step '恢复默认 bootcmd'
            Push-Env $envDefault '/tmp/uboot-env-default.bin'
            Write-Env '/tmp/uboot-env-default.bin'
            $check = (& ssh @sshOpts $sshTarget 'dd if=/dev/mtd3 bs=4096 count=64 2>/dev/null | md5sum') -join ''
            $check = ($check -split '\s+')[0].ToLower()
            if ($check -eq $envDefaultMd5) { Ok 'bootcmd 已恢复，不会再每次开机重刷' }
            else { Warn "mtd3 回读不一致（$check），重启前再跑一次脚本或手动写一次" }
        } catch {
            Warn "恢复 bootcmd 失败: $($_.Exception.Message)"
            Note '设备能 ssh 时重跑本脚本，否则每次开机都会重刷 U-Boot'
        }
    } elseif (-not $DryRun) {
        Warn '设备 ssh 不通，跳过恢复 bootcmd'
        Note '下次能 ssh 时务必重跑本脚本，否则每次开机都会重刷 U-Boot'
    }

    if ($flashOk) { Write-Host '  完成：U-Boot 已更新。' -ForegroundColor Green }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $flashOk) { exit 1 }
}
