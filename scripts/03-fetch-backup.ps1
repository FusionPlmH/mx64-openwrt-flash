# 把设备 /tmp/backup 里的备份拉到 PC。
#   powershell -ExecutionPolicy Bypass -File scripts\03-fetch-backup.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\03-fetch-backup.ps1 -OutDir D:\mx64-backup
#
# 前提：设备已执行 scripts/40-backup-flash.sh，且能 ssh root@192.168.1.1
# Windows 10/11 自带 OpenSSH 客户端；没有的话先装:
#   dism /online /add-capability /capabilityname:OpenSSH.Client~~~~0.0.1.0

param(
    [string]$Device = '192.168.1.1',
    [string]$User = 'root',
    [string]$OutDir = (Join-Path (Get-Location) 'mx64-backup')
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
    throw '找不到 scp，先安装 OpenSSH 客户端'
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$OutDir = (Resolve-Path $OutDir).Path

Write-Host "目标目录: $OutDir"
Write-Host ""

$targets = @(
    'proc-mtd.txt',
    'ubinfo.txt',
    'board-config.tar.gz',
    'mtd0.bin.gz',
    'mtd1.bin.gz',
    'mtd2.bin.gz',
    'mtd3.bin.gz',
    'mtd4.bin.gz'
)

foreach ($t in $targets) {
    # -O 是 scp 的旧协议开关，OpenWrt 的 dropbear 需要它
    & scp -O "${User}@${Device}:/tmp/backup/$t" $OutDir 2>&1 | ForEach-Object { "  $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "跳过 $t（设备上没有或传输失败）"
        continue
    }
    $p = Join-Path $OutDir $t
    "{0,-24} {1,8:N1} KB" -f $t, ((Get-Item $p).Length / 1KB)
}

Write-Host ""
Write-Host "== 备份结果 =="
Get-ChildItem $OutDir | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize

Get-ChildItem $OutDir -Filter '*.b?n.gz' | ForEach-Object {
    "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name
} | Set-Content (Join-Path $OutDir 'SHA256SUMS')
