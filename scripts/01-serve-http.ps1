# 在 PC 上起一个 HTTP 服务器，给 MX64 的 diagnostic mode 用 wget 拉文件。
#   powershell -ExecutionPolicy Bypass -File scripts\01-serve-http.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\01-serve-http.ps1 -ServerIp 192.168.1.50 -Port 8000
#
# 前提：PC 网卡与设备同网段（-ServerIp 不指定时自动选本机 192.168.1.x），网线接 MX64 的 LAN 口。
#
# 脚本会把 files\ 与 scripts\ 里的 *.sh 汇总到一个临时目录再对外提供，
# 这样设备上的路径是平的：http://<PC_IP>:8000/<文件名>

param(
    [string]$ServerIp = '',
    [string]$DeviceIp = '192.168.1.1',
    [int]$Port = 8000
)

$ErrorActionPreference = 'Stop'

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
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw '找不到 python，无法启动 HTTP 服务'
}

$kitRoot  = Split-Path -Parent $PSScriptRoot
$filesDir = Join-Path $kitRoot 'files'
if (-not (Test-Path $filesDir)) { throw "找不到 $filesDir" }

$stage = Join-Path $env:TEMP "mx64-http-$Port"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null

Copy-Item (Join-Path $filesDir '*') $stage -Force
Copy-Item (Join-Path $PSScriptRoot '*.sh') $stage -Force

$base = "http://${ServerIp}:$Port"

Write-Host "服务目录: $stage"
Write-Host ""
Write-Host "本机 IPv4:"
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    ForEach-Object { Write-Host ("  {0}  ({1})" -f $_.IPAddress, $_.InterfaceAlias) }
if (-not (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.IPAddress -eq $ServerIp })) {
    Write-Warning "$ServerIp 不在本机网卡上，设备可能连不上"
}
Write-Host ""
Write-Host "设备侧（telnet $DeviceIp 之后）示例:"
Write-Host "  cd /tmp"
Write-Host "  wget $base/40-backup-flash.sh && sh 40-backup-flash.sh"
Write-Host "  wget $base/60-reclaim-space.sh && sh 60-reclaim-space.sh"
Write-Host "  任意文件同理：wget $base/<files 或 scripts 里的文件名>"
Write-Host ""
Write-Host "Ctrl-C 结束。"
Write-Host ""

Set-Location $stage
python -m http.server $Port --bind 0.0.0.0
