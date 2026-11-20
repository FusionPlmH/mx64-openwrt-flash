# 在 PC 上起一个 HTTP 服务器，给 MX64 的 diagnostic mode 用 wget 拉文件。
#   powershell -ExecutionPolicy Bypass -File scripts\01-serve-http.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\01-serve-http.ps1 -Port 80    # 需要管理员
#
# 前提：PC 网卡设成 192.168.1.2/24（网关留空），网线接 MX64 的 LAN 口。
#
# 脚本会把 files\ 与 scripts\ 里的 *.sh 汇总到一个临时目录再对外提供，
# 这样设备上的路径是平的：http://192.168.1.2:8000/uboot_mx64

param(
    [int]$Port = 8000
)

$ErrorActionPreference = 'Stop'

$kitRoot  = Split-Path -Parent $PSScriptRoot
$filesDir = Join-Path $kitRoot 'files'
if (-not (Test-Path $filesDir)) { throw "找不到 $filesDir" }

$stage = Join-Path $env:TEMP 'mx64-http'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null

Copy-Item (Join-Path $filesDir '*') $stage -Force
Copy-Item (Join-Path $PSScriptRoot '*.sh') $stage -Force

$base = "http://192.168.1.2:$Port"

Write-Host "服务目录: $stage"
Write-Host ""
Write-Host "本机 IPv4:"
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    ForEach-Object { Write-Host ("  {0}  ({1})" -f $_.IPAddress, $_.InterfaceAlias) }
Write-Host ""
Write-Host "设备侧（telnet 192.168.1.1 之后）依次执行:"
Write-Host "  cd /tmp"
Write-Host "  wget $base/10-device-check.sh && sh 10-device-check.sh"
Write-Host "  wget $base/20-install-uboot.sh && sh 20-install-uboot.sh $base"
Write-Host ""
Write-Host "Ctrl-C 结束。"
Write-Host ""

Set-Location $stage
python -m http.server $Port --bind 0.0.0.0
