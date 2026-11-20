# MX64 一键刷机（PC 侧编排）：起文件服务 + telnet 注入 one-shot-diag.sh。
#
#   powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -Transport tftp   # 需要管理员
#   powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -DryRun           # 只看计划
#
# 前提：
#   1) 设备已经在 diagnostic mode（按住 reset 上电，白灯闪两下后松手，等灯变绿）
#   2) PC 网卡设成 192.168.1.2/24，网线接设备 LAN 口
#   3) Windows 的 telnet 客户端已启用（脚本用的是原始 TCP，不需要装 telnet 命令）
#
# 这个脚本只负责"把脚本送进去并跑起来"，真正的判断/校验/写入都在设备的
# one-shot-diag.sh 里完成；日志会完整打印出来。

param(
    [string]$ServerIp = '192.168.1.2',
    [string]$DeviceIp = '192.168.1.1',
    [int]$Port = 8000,
    [ValidateSet('http', 'tftp')]
    [string]$Transport = 'http',
    [int]$TimeoutSec = 600,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$kitRoot = Split-Path -Parent $PSScriptRoot

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }

# ---------------------------------------------------------------- 1. 环境检查
$hasIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -eq $ServerIp }
if (-not $hasIp) {
    Say "本机没有 $ServerIp 这个地址。" 'Yellow'
    Say "先执行（管理员 PowerShell）:" 'Yellow'
    Say "  Get-NetAdapter | Format-Table Name,InterfaceIndex,Status" 'Yellow'
    Say "  New-NetIPAddress -InterfaceIndex <索引> -IPAddress $ServerIp -PrefixLength 24" 'Yellow'
    if (-not $DryRun) { throw "缺少 $ServerIp" }
}

$filesDir = Join-Path $kitRoot 'files'
$stage = Join-Path $env:TEMP 'mx64-http'
if (-not $DryRun) {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory $stage | Out-Null
    Copy-Item (Join-Path $filesDir '*') $stage -Force
    Copy-Item (Join-Path $PSScriptRoot '*.sh') $stage -Force
}

$base = if ($Transport -eq 'tftp') { "tftp://$ServerIp" } else { "http://${ServerIp}:$Port" }
$bootstrap = "cd /tmp && wget http://${ServerIp}:$Port/one-shot-diag.sh && sh one-shot-diag.sh $base"

Say ""
Say "==== 计划 ====" 'Cyan'
Say "  服务目录 : $stage"
Say "  传输方式 : $Transport  ($base)"
Say "  设备     : $DeviceIp (telnet 23)"
Say "  注入命令 : $bootstrap"
Say ""

if ($DryRun) {
    Say "DryRun: 不做任何实际操作。" 'Yellow'
    return
}

# ---------------------------------------------------------------- 2. 起服务
$servers = @()
$logs = @{}
try {
    $httpLog = Join-Path $env:TEMP 'mx64-http.log'
    $servers += Start-Process python -ArgumentList '-m', 'http.server', "$Port", '--bind', '0.0.0.0', '--directory', $stage `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $httpLog -RedirectStandardError "$httpLog.err"
    $logs['http'] = $httpLog
    Say "HTTP 服务已启动 (pid $($servers[-1].Id), 端口 $Port)"

    if ($Transport -eq 'tftp') {
        $tftpLog = Join-Path $env:TEMP 'mx64-tftp.log'
        $servers += Start-Process python -ArgumentList (Join-Path $PSScriptRoot '70-tftp-server.py'), '--dir', $stage, '--port', '69' `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput $tftpLog -RedirectStandardError "$tftpLog.err"
        $logs['tftp'] = $tftpLog
        Say "TFTP 服务已启动 (pid $($servers[-1].Id), UDP 69；失败说明没管理员权限)"
        Start-Sleep -Seconds 1
        if ($servers[-1].HasExited) {
            Say "TFTP 起不来，日志:" 'Red'
            Get-Content $tftpLog -ErrorAction SilentlyContinue | ForEach-Object { Say "  $_" }
            throw "TFTP 启动失败（UDP 69 需要管理员权限）"
        }
    }
    Start-Sleep -Seconds 2

    # ------------------------------------------------------------ 3. telnet
    Say ""
    Say "连接 $DeviceIp`:23 ..." 'Cyan'
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect($DeviceIp, 23)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 1000

    function Read-Available([System.IO.Stream]$s, [int]$ms = 1000) {
        $buf = New-Object byte[] 4096
        $sb = New-Object System.Text.StringBuilder
        $deadline = (Get-Date).AddMilliseconds($ms)
        while ((Get-Date) -lt $deadline) {
            try {
                $n = $s.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
            } catch { }
        }
        # 去掉 telnet 协商和退格噪声
        $text = $sb.ToString() -replace "`0", ''
        $text = [regex]::Replace($text, "\xFF[\xFB-\xFE].|\xFF\xFA.*?\xFF\xF0", '', 'Singleline')
        return $text -replace "`b", ''
    }

    function Send-Line([System.IO.Stream]$s, [string]$line) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($line + "`r`n")
        $s.Write($bytes, 0, $bytes.Length)
        $s.Flush()
    }

    Say "等待 shell 提示符 ..."
    Start-Sleep -Seconds 2
    Send-Line $stream ""
    $text = Read-Available $stream 2500
    Say "---- 设备输出 ----"
    Say $text
    Say "------------------"

    Say "注入一键脚本 ..." 'Cyan'
    Send-Line $stream $bootstrap

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $done = $false
    $all = New-Object System.Text.StringBuilder
    while ((Get-Date) -lt $deadline) {
        $chunk = Read-Available $stream 1500
        if ($chunk) {
            [void]$all.Append($chunk)
            Write-Host $chunk -NoNewline
            if ($chunk -match '====\s*完成\s*====') { $done = $true; break }
            if ($chunk -match '!!') { }
        }
    }

    Say ""
    if ($done) {
        Say "==== 脚本跑完了 ====" 'Green'
    } else {
        Say "==== 没等到完成标记（超时或被中断）====" 'Yellow'
    }

    $out = $all.ToString()
    if ($out -match 'TARGET=(\S+)') { Say "写入目标: $($matches[1])" }
    if ($out -match 'SHA512 正确')   { Say "校验: SHA512 通过" 'Green' }
    if ($out -match '_mtd-rw: mtd0: setting writeable flag_') { Say "mtd0 已解锁" 'Green' }
    if ($out -match '回读和文件不一致') { Say "回读不一致，需要重刷！" 'Red' }

    $client.Close()

    Say ""
    Say "下一步：设备断电，然后用 U 盘或直接上电让 U-Boot 自动走 TFTP 引导 initramfs。" 'Cyan'
    Say "（我们的 U-Boot：UBI 起不来会自动 usbload，再不行自动 tftp_boot，不用按 reset）"
}
finally {
    foreach ($p in $servers) {
        if ($p -and -not $p.HasExited) {
            try { $p.Kill() } catch { }
        }
    }
    Say ""
    Say "服务已停止（日志: $env:TEMP\mx64-http.log）"
}
