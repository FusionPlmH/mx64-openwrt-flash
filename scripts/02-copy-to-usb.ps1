# 把 files\ 里的文件拷到 U 盘根目录，并逐个校验 SHA256。
#   powershell -ExecutionPolicy Bypass -File scripts\02-copy-to-usb.ps1 -Drive E:\
#
# 不格式化！U 盘需要提前分好一个 FAT16/FAT32 分区（MBR）。
# 如果 U 盘只有一个分区，-Drive 直接给盘符就行。

param(
    [Parameter(Mandatory = $true)]
    [string]$Drive
)

$ErrorActionPreference = 'Stop'

if (-not $Drive.EndsWith('\')) { $Drive += '\' }
if (-not (Test-Path $Drive)) { throw "找不到 $Drive" }

$kitRoot = Split-Path -Parent $PSScriptRoot
$filesDir = Join-Path $kitRoot 'files'

$vol = Get-Volume -DriveLetter ($Drive.TrimEnd('\').TrimEnd(':')) -ErrorAction SilentlyContinue
if ($vol) {
    Write-Host ("目标: {0}  文件系统 {1}  可用 {2:N1} GB" -f $vol.DriveLetter, $vol.FileSystem, ($vol.SizeRemaining / 1GB))
    if ($vol.FileSystem -notin @('FAT32', 'FAT', 'FAT16')) {
        Write-Warning "U 盘不是 FAT 文件系统（当前 $($vol.FileSystem)），U-Boot 只认 FAT，可能引导不了"
    }
}

Write-Host ""
Get-ChildItem $filesDir | Where-Object { $_.Name -notlike '*.sha512' -and $_.Name -ne 'uboot_ng.bin.sha256' } | ForEach-Object {
    $src = $_.FullName
    $dst = Join-Path $Drive $_.Name
    Copy-Item $src $dst -Force
    $h1 = (Get-FileHash $src -Algorithm SHA256).Hash.ToLower()
    $h2 = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
    $ok = if ($h1 -eq $h2) { 'OK' } else { 'MISMATCH' }
    "{0,-72} {1,7:N1} MB  {2}" -f $_.Name, ($_.Length / 1MB), $ok
}

Write-Host ""
Write-Host "完成。检查:"
Write-Host "  - 根目录文件名必须完全一致（尤其 openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin）"
Write-Host "  - 根目录不要放旧的 openwrt-*.bin，避免引导到错误镜像"
Write-Host "  - 出现 MISMATCH 就重新拷一次，或换 U 盘"
