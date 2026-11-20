# Meraki MX64 / MX64W OpenWrt 刷机包

按 <https://openwrt.org/toh/meraki/mx64> 整理的**PC 侧全自动**刷机流程：判断、校验、比对都在笔记本上做，
设备上只执行一条条原始 shell 命令（`cat` / `wget` / `dd` …），**不往设备里塞脚本**——
原厂 diagnostic mode 的 `busybox 1.7.2` 连 `sed`/`awk` 都没有，塞脚本只会踩坑。

- 本仓库: <https://github.com/FusionPlmH/mx64-openwrt-flash>
- 配套 U-Boot 源码: <https://github.com/FusionPlmH/mx64-uboot-refresh>

## 我该用哪个镜像？

关键只有一件：**你的 `mtd0` 有多大**（`cat /proc/mtd`，脚本会自动读）。

| 你的 mtd0 | 刷的 U-Boot | 引导进 OpenWrt 用的文件 | 需要 `-initramfs-kernel.bin` 吗 |
|---|---|---|---|
| `00100000`（1 MiB）**大多数机器** | `uboot_ng.bin` 或 `uboot_mx64` | `openwrt-bcm53xx-generic-meraki_mx64[-a0]-initramfs.bin`（FIT，`bootm`） | **不需要** |
| `00080000`（512 KiB） | `uboot_mx64_small` | `openwrt-bcm5862x-generic-meraki_mx64[a0]-initramfs-kernel.bin`（SPIM，`bootbk`） | **需要**，只用来把 boot 分区换成 1 MiB 布局 |

两种 initramfs 是完全不同的容器，不是同一东西的两个版本：

| 文件 | 容器（首字节） | 谁引导 | 用途 |
|---|---|---|---|
| `openwrt-bcm53xx-...-initramfs.bin` | FIT `d0 0d fe ed` | `bootm` | 正常的 OpenWrt RAM 系统 → 之后 sysupgrade |
| `openwrt-bcm5862x-...-initramfs-kernel.bin` | SPIM `53 50 49 4d` | `bootbk` | 只有 512 KiB 老机器要，里面带 1 MiB 版 `uboot_mx64` |

## 不确定自己刷到哪一步了？

```sh
cat /proc/mtd                 # mtd0 大小 -> 决定用哪个 U-Boot
cat /sys/block/mtdblock0/ro   # 1 = 写保护，0 = 可写
```

已经进 OpenWrt 后：

```sh
cat /proc/cmdline             # root=/dev/ubiblock0_0 => 装进 NAND 了；/dev/ram0 => 还在 RAM
df -h /overlay                # 有 /overlay 且几百 MB => sysupgrade 过了
ubinfo -a                     # 有 rootfs_data 卷 => 已装好
```

## 刷哪个 U-Boot

| 选项 | 刷什么 | 大小 | 说明 |
|---|---|---|---|
| **默认** | `uboot_ng.bin`（本项目编） | 598,172 B，需 1 MiB 分区 | 带 `bootimg` / `flash_uboot` / TFTP 自动引导 |
| `-Uboot clayface` | `uboot_mx64` / `uboot_mx64_small` | 587,312 / 524,288 B | wiki 上大量机器验证过的版本 |

两个自动保护：

- `mtd0` 只有 `0x80000` 时 `uboot_ng.bin` 装不下 → **自动改用 `uboot_mx64_small`** 并提示
- `uboot_ng.bin` 至今**没有在真机上启动过**（编译、静态检查、镜像格式、CRC 都验过，但没人按过电源键）。
  第一次刷它建议接着串口

## 常见问题

| 问题 | 答案 |
|---|---|
| 第一次装 U-Boot 要按 reset 吗？ | **要**。原厂固件只有 diagnostic mode 给 shell |
| 之后刷 initramfs 还要按 reset 吗？ | **不用**（用本项目的 U-Boot）。引导顺序 UBI → USB → TFTP，前一个失败自动试下一个 |
| 刷机脚本默认走什么传输？ | **TFTP**；起不来或设备没有 tftp 时自动回退 HTTP |
| 备份原厂分区吗？ | **默认跳过**（见「备份」一节，要备份需手动做） |
| 一条命令能刷完吗？ | 能：`scripts\00-flash.ps1` 一路到 sysupgrade |

## 目录内容

```
README.md                    本文件
SHA256SUMS                   files/ 下所有文件的校验值（00-flash.ps1 第 1 阶段会逐个核对）
files/
  uboot_ng.bin               本项目的 U-Boot v5（598,268 B，需 1 MiB 分区）
  uboot-env.bin              U-Boot 环境变量块（含 config_dts=config@4，给老版本兜底）
  uboot_mx64                 1 MiB boot 分区用的 clayface U-Boot（587,312 B）
  uboot_mx64_small           512 KiB boot 分区用的 clayface U-Boot（524,288 B）
  mtd-rw.ko                  mtd0 写保护解锁模块（仅 ro=1 时需要，只对原厂 2.6.36 内核有效）
  mtd                        busybox mtd 工具（解锁后用 mtd write）
  openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin        OpenWrt RAM 系统 B0+（FIT）
  openwrt-bcm53xx-generic-meraki_mx64-a0-initramfs.bin     OpenWrt RAM 系统 A0（FIT）
  openwrt-25.12.6-bcm53xx-generic-meraki_mx64-squashfs.sysupgrade.bin    装到 NAND B0+
  openwrt-25.12.6-bcm53xx-generic-meraki_mx64-a0-squashfs.sysupgrade.bin 装到 NAND A0
  openwrt-bcm5862x-generic-meraki_mx64-initramfs-kernel.bin   ★ 只有 512 KiB 机器要（SPIM）
  openwrt-bcm5862x-generic-meraki_mx64a0-initramfs-kernel.bin ★ 只有 512 KiB 机器要（SPIM）
scripts/
  00-flash.ps1               PC 一键：起服务 + telnet 驱动设备，全自动（见下）
  01-serve-http.ps1          只想起 HTTP 服务（手动敲命令时用）
  70-tftp-server.py          只读 TFTP 服务器（UDP 69，支持 blksize 协商，给 U-Boot 用）
  02-copy-to-usb.ps1         把 files/ 拷到 U 盘并校验
  03-fetch-backup.ps1        把设备 /tmp/backup 拉回 PC
  30-write-uboot-from-openwrt.sh  过渡固件里把 512 KiB 布局换成 1 MiB（会先探 mtd0 可写性）
  40-backup-flash.sh         OpenWrt 里备份原厂分区（可选）
  50-sysupgrade.sh           OpenWrt 里执行 sysupgrade
  60-reclaim-space.sh        OpenWrt 里删掉原厂 UBI 卷，扩 rootfs_data
  90-uboot-tftp.txt          U-Boot 提示符下的命令清单（TFTP 引导 / flash_uboot）
tools/
  mkenv.py                   从 U-Boot 二进制生成带正确 CRC 的 u-boot-env 块
backup/                      -Check 时自动存的原厂 mtd0 头部（.gitignore 忽略）
```

## 一键刷机（PC 驱动）

前置只有两条：

1. 设备已进 diagnostic mode（按住 reset 上电，白灯闪两下后松手，等灯变绿）
2. PC 网卡 `192.168.1.2/24`，网线接设备 LAN 口

```powershell
cd "C:\Users\Peter\Desktop\cisco mx64\mx64-openwrt-flash-kit"

powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -DryRun     # 看计划
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -Check      # 只读设备、出结论
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -Probe      # 只验证 mtd 工具，不擦不写
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1             # 真刷（默认 TFTP）
```

TFTP 会**无条件启动**（刷完重启后是 U-Boot 去拉 initramfs，而 U-Boot 只会 TFTP）。
Windows 上绑 UDP 69 不需要管理员权限，但网卡若在「公用网络」配置下，防火墙可能拦入站。
`-Transport` 只决定 diag 模式里设备用哪种方式下载。

### [1] 环境检查查什么

跑之前先把这些挑出来，省得刷到一半才发现：

| 检查 | 为什么 |
|---|---|
| 本机有 `192.168.1.2` 这个地址 | 没地址设备连不上，脚本会给出 `New-NetIPAddress` 的命令 |
| python >= 3.7 | `http.server --directory` 需要 3.7 |
| ssh / scp 存在 | 第 6 阶段要用；没有就自动跳过 sysupgrade |
| 是否管理员 | Windows 绑 UDP 69 **不需要**管理员，只是提示 |
| 网卡防火墙配置 | 若是「公用网络」会警告 —— U-Boot 的 TFTP 回复可能被拦 |
| **UDP 69 / TCP 8000 是否被占用** | 上一轮没退干净的 python 服务会让第 2 阶段直接失败 |
| **`files/` 里所有镜像的校验和** | 逐个比对 `*.sha256` / `*.sha512`，防止刷进旧版本或下坏的镜像 |
| **U-Boot 版本 tag** | 从 `uboot_ng.bin` 里抓 `mx64-ng-*`，一眼确认刷的是哪个构建 |
| C 盘剩余空间 | 暂存要 ~35 MB |

第 3 阶段连不上 telnet 时也会自动探测：

```
[ !  ] 但是 192.168.1.1:80 是通的 -> 80 开着（LuCI/OpenWrt，或原厂固件的管理页面 —— 都不是 diagnostic mode）
[ !  ] 但是 192.168.1.1:22 是通的 -> 设备已经在跑 OpenWrt（不是 diagnostic mode）

[ ok ] 192.168.1.1:22 开着，说明 OpenWrt 已经装好了 —— 这个脚本没事可做
        如果只是想确认系统状态：ssh root@192.168.1.1
        如果是要换 U-Boot：mtd0 在 OpenWrt 下是只读的，得让 U-Boot 自己刷自己
```

还会顺带查 `192.168.0.1`（原厂固件的默认 LAN 地址），提示你把网线插对。

### 6 个阶段

| 阶段 | 干什么 |
|---|---|
| [1] 环境检查 | 见上表 |
| [2] 起服务 | TFTP(UDP 69) + HTTP 备用 |
| [3] 刷 U-Boot | telnet 进设备，逐条发命令：能力探测 → 读 `mtd0`/写保护/SoC → 决定刷哪个 → 设备 `wget` 下载 → PC 比对长度和 md5 → （按需）`insmod mtd-rw.ko` 解锁 → `dd` 或 `mtd write` → 回读前 64 KiB 比对 |
| [4] 重启 | 发 `reboot`，U-Boot 自动 UBI→USB→TFTP 拉 initramfs，等 22 端口 |
| [5] 关服务 | 停掉 TFTP/HTTP（系统已在 RAM 里跑） |
| [6] sysupgrade | `scp` 上传 → `ssh sysupgrade -n` → 等系统重启回来 |

第 3 阶段设备上实际执行的命令（就是这么几条，逻辑都在 PC）：

```
for t in wget wc dd md5sum insmod chmod devmem devmem2; do ... done   # 能力探测
cat /proc/mtd
cat /sys/block/mtdblock0/ro
devmem 0x18000000
cd /tmp && wget http://192.168.1.2:8000/uboot_ng.bin
wc -c < /tmp/uboot_ng.bin
md5sum /tmp/uboot_ng.bin
insmod /tmp/mtd-rw.ko i_want_a_brick=1          # 仅当 ro=1
cd /tmp && ./mtd write /tmp/uboot_ng.bin /dev/mtd0    # 或 dd if=/tmp/uboot_ng.bin of=/dev/mtdblock0
dd if=/dev/mtdblock0 bs=1024 count=64 | md5sum
reboot
```

### 开关

| 开关 | 作用 |
|---|---|
| `-Check` | 只探测并给出结论，**不写 NAND** |
| `-Probe` | 只验证设备上的 `mtd` 工具（跑 `unlock`，不擦不写），确认参数写法 |
| `-DryRun` | 只打印计划 |
| `-SkipSysupgrade` | 刷完 U-Boot、进了 initramfs 就停 |
| `-Uboot clayface` | 改刷 clayface 的 `uboot_mx64`（默认 `uboot_ng.bin`） |
| `-Transport http` | 不用 TFTP，免管理员 |
| `-SysupgradeFile <路径>` | 指定 sysupgrade 镜像（默认按 A0/B0+ 自动挑最新的） |

### 输出长这样

```
[3/6] 刷 U-Boot（PC 驱动）
--------------------------------------------------------------------
   [ ok ] 已连上 diagnostic mode
   [ ok ] 有: chmod dd devmem insmod md5sum wc wget
   [ !  ] 没有: devmem2 mtd sha512sum
   [ ok ] mtd0 = 0x00100000 (1048576 字节)
   [ !  ] mtd0 有写保护（ro=1）-> 需要 mtd-rw.ko 解锁
   [ ok ] 0x18000000 = 0x3F040000 -> B0+（用常规镜像）
   [ ok ] 将刷入 uboot_ng.bin (598172 字节, md5 648a8d98...)
   [ ok ] 下载完成
   [ ok ] 长度一致 (598172 字节)
   [ ok ] md5 一致 (648a8d98...)
   [ ok ] mtd0 已解锁（ro=0）
   [ ok ] 写入完成
   [ ok ] 回读一致 (e8100695...)
```

## 手动命令（自动流程不适用时的兜底）

PC 上先起服务（别关窗口）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\01-serve-http.ps1
```

设备 `telnet 192.168.1.1` 进去，按需执行：

```sh
cat /proc/mtd
cat /sys/block/mtdblock0/ro        # 1 = 有写保护（但 mtd-rw 加载后它也不会变，见下）
devmem 0x18000000

cd /tmp
rm -f uboot_ng.bin                 # 原厂 wget 不覆盖已有文件！
wget http://192.168.1.2:8000/uboot_ng.bin
ls -l uboot_ng.bin                 # 应该是 598172 字节（没有 wc 时用这个）

# 只有 ro=1 才需要解锁
rm -f mtd-rw.ko mtd
wget http://192.168.1.2:8000/mtd-rw.ko
wget http://192.168.1.2:8000/mtd && chmod +x mtd
insmod mtd-rw.ko i_want_a_brick=1
cat /proc/modules | head -20       # 有 mtd_rw 这行就算成功（ro 仍是 1，正常）
dmesg | tail -5                    # 应该有 mtd-rw: mtd0: setting writeable flag

# 写入：mtd0 锁着就 ./mtd write /dev/mtd0，没锁就 dd 写 mtdblock0（这是 wiki 的两种写法）
./mtd write /tmp/uboot_ng.bin /dev/mtd0
# 或者（mtd0 本来可写时）
dd if=/tmp/uboot_ng.bin of=/dev/mtdblock0

dd if=/dev/mtd0 bs=512 count=1 | hexdump -C    # 有 hexdump 的话看头是不是 07 05 00 ea
sync
# wiki 第 8 步是"断电"。不接串口就 reboot，起不来再断电重上
reboot
```

## 分步细节（脚本不适用时逐条对着做）

### 0. 先决策

| 要确认的事 | 怎么查 | 后果 |
|---|---|---|
| A0 还是 B0+ | `devmem 0x18000000`，`0x3F00`–`0x3F03` → A0 | 用错 initramfs 内核起不来 |
| mtd0 大小 | `cat /proc/mtd` | `0x80000` 只能先刷 `uboot_mx64_small` |
| mtd0 是否只读 | `cat /sys/block/mtdblock0/ro` | 需要 `mtd-rw.ko` + `mtd` |

`00-flash.ps1` 会自动做这三件事并给出结论（`-Check` 只看不写）。

### 1. 准备 U 盘（只有走 USB 路径需要）

- MBR 分区表，第一个分区 FAT32（wiki 建议 FAT16 128 MB）
- 根目录只放本工具包的文件，不要留旧的 `openwrt-*`
- 写入：`powershell -ExecutionPolicy Bypass -File scripts\02-copy-to-usb.ps1 -Drive E:\`

### 2. PC 侧服务

一般由 `00-flash.ps1` 自动起。想单独起：

```powershell
python scripts\70-tftp-server.py                                   # TFTP，UDP 69（Windows 不需要管理员）
powershell -ExecutionPolicy Bypass -File scripts\01-serve-http.ps1 # HTTP，:8000
```

### 3. 进入 diagnostic mode

1. 网线插 LAN 口
2. 按住 reset 上电 → 前灯橙色 → **白灯闪两下**时松手
3. 松手后等约 15 秒，灯熄灭后变绿；变彩虹色就断电重来
4. `telnet 192.168.1.1`

### 4. 512 KiB 机器（过渡固件换 1 MiB 布局）

只有这一节要 `-initramfs-kernel.bin`：

1. 把 `openwrt-bcm5862x-generic-meraki_mx64-initramfs-kernel.bin`（A0 用 `..._mx64a0-...`）
   放进 U 盘或 TFTP 根目录
2. 按住 reset 上电引导进过渡固件（`uboot_mx64_small` 是按键触发的）
3. `ssh root@192.168.1.1`，跑 `scripts/30-write-uboot-from-openwrt.sh`
   （脚本会先探 mtd0 可写性；出厂带写保护的机器在 OpenWrt 下写不了，
   那种机器只能走「让 U-Boot 自己刷自己」）
4. **不要重启**，直接 sysupgrade
5. 换完第一次启动要重做 Shmoo 校准，会很慢（几分钟）

### 5. 启动 OpenWrt（正常路径）

用本项目的 U-Boot 时**不用按 reset**：

```
UBI 能起内核        -> 直接起 OpenWrt
UBI 起不来（空/坏） -> 自动 usbload（U 盘，3 次尝试 / 2 条总线 / 2 个文件名）
U 盘也不行          -> 自动 tftp_boot（网络）
```

`tftp_boot` 按顺序试：`${tftp_file}` → FIT initramfs → SPIM 过渡固件；A0/B0+ 由 `config_dts` 自动选。
`files/` 的内容原样放进 TFTP 根目录即可，不用改名。

开关：`enable_usb_boot` / `enable_tftp_boot` / `disable_ubi_boot`，`setenv` 后 `saveenv`。

### 6. 备份原厂分区（可选，**默认跳过**）

自动流程不做备份：备份只能在 initramfs 里做（diag 模式没有 scp），而自动流程第 6 阶段上传完
sysupgrade 就重启了。要备份就手动：先引导 initramfs，设备上跑 `40-backup-flash.sh`，
再用 `03-fetch-backup.ps1` 拉回 PC。

### 7. sysupgrade

`00-flash.ps1` 第 6 阶段自动完成。手动：

```powershell
scp -O "files\openwrt-25.12.6-bcm53xx-generic-meraki_mx64-squashfs.sysupgrade.bin" root@192.168.1.1:/tmp/
```

```sh
ssh root@192.168.1.1
sysupgrade -n /tmp/openwrt-25.12.6-bcm53xx-generic-meraki_mx64-squashfs.sysupgrade.bin
```

装完默认 `192.168.1.1`，`root` 无密码（立刻设密码）。

### 8. 释放被原厂占用的 flash（可选）

```sh
wget http://192.168.1.2:8000/60-reclaim-space.sh && sh 60-reclaim-space.sh
```

删掉 `part.old` / `storage` / `diagnostic1` / `part.safe`，**不要动 `board-config`**；
然后再跑一次 sysupgrade，`rootfs_data` 会扩建到剩余全部空间。

### 9. 本项目的 U-Boot 额外能力

| 命令 | 作用 |
|---|---|
| `mx64init` | 初始化外设 + 读 reset 键 |
| `tftp_boot` | TFTP 拉镜像并 `bootimg`（先 override，再 FIT，再 SPIM） |
| `usbload` | U 盘引导（默认开） |
| `bootimg <addr> [part]` | 按镜像头选 `bootm`（FIT/uImage）或 `bootbk`（SPIM） |
| `flash_uboot <file> <分区大小hex> confirm` | TFTP 取 U-Boot → 校验 → 擦/写 mtd0 → 回读 CRC |
| `bootbk <addr> <part>` | 启动 Meraki bootkernel（校验头部 CRC32） |
| `mx64info` | 打印版本、SoC、reset 状态、环境变量 |

用 TFTP 升级 U-Boot 不用 diag、不用 U 盘、也不用按 reset，走法见
[「需要刷 mtd0 时：让 U-Boot 自己刷自己」](#需要刷-mtd0-时让-uboot-自己刷自己)。

## 故障排查

| 现象 | 处理 |
|---|---|
| `192.168.1.1:23` 连不上 | 设备没进 diag（正常启动时 LAN 是 `192.168.0.1`）；网线要插 LAN1-4 不是 WAN；进 diag 要 20~30 秒 |
| 白灯闪两下后一直橙 | diag Linux 没起来；断电重试 2-3 次；仍不行请接串口（J1，115200 8N1） |
| `wget` 404 | HTTP 服务目录不对，或文件名打错 |
| `wget: can't open 'xxx': File exists` | 原厂 busybox 的 `wget` **不覆盖**已有文件。脚本已自动 `rm -f` 后重下；手敲命令时自己先删 |
| `mtd-rw.ko` insmod 报错 | 内核不匹配，看 dmesg 的 vermagic / 符号版本报错 |
| insmod 报 `File exists` | 模块之前已经加载过，**不是失败**；看 `/proc/modules` 有没有 `mtd_rw` |
| 解锁后 `/sys/block/mtdblock0/ro` 还是 1 | **正常，别管它**。那是块设备的静态属性，`mtd-rw` 改的是 `mtd->flags`，sysfs 不会跟着变。判据应该是 `/proc/modules` 里有 `mtd_rw`，或 dmesg 有 `mtd-rw: mtd0: setting writeable flag` |
| `mtd: Could not open mtd device: mtd0` | 这个 `mtd` 只认 **`/dev/mtd0` 全路径**，传 `mtd0` 或 label `boot` 都不行 |
| 回读 md5 不一致 | 不要断电，重跑一次写入 |
| 换 U-Boot 后长时间橙白闪 | Shmoo 校准中；等几分钟，不行断电再上电；仍失败用 U 盘 initramfs 重装，**别再刷 U-Boot** |
| 装完只有 ~370 MiB 可用 | 见第 8 节 |

## mtd0 写不进去时，改 U-Boot 环境

`mtd0` 在原厂 diag 里是 `ro=1`，进了 OpenWrt 之后又被 DTS 标成 `read-only`
（`dd of=/dev/mtd0` 直接 `Operation not permitted`）。所以 **装好系统之后就再也写不动
U-Boot 了**，除非接串口或重新进 diag。

但 U-Boot 的行为大部分在环境变量里，而 `u-boot-env` 分区可写：

```console
# 0x400000..0x440000 之外，环境实际在 0x440000，正好一个 0x40000 擦除块 = mtd3
dd if=/dev/mtd3 bs=4096 count=1 | tr -s '\000' '\n' | head    # 看当前环境
```

生成并写入（`config_dts` 就靠这个改，见下面"B0+ 的坑"）：

```powershell
python tools\mkenv.py files\uboot_ng.bin files\uboot-env.bin `
    config_dts=config@4 ipaddr=192.168.1.10 serverip=192.168.1.2
scp -O files\uboot-env.bin root@192.168.1.1:/tmp/
```

```sh
# 设备上：NAND 必须先擦后写，已写过数据时直接 dd 会 Operation not permitted
mtd erase u-boot-env
dd if=/tmp/uboot-env.bin of=/dev/mtd3 bs=4096
sync
dd if=/dev/mtd3 bs=4096 count=64 | md5sum    # 和本地比对
reboot
```

`files/uboot-env.bin` 就是这份（crc `0x7b2ae92f`，md5 `7e35ca65061087b233b093161e94ce05`），
可以直接用。注意 `mtd` 工具只认 **label**（`u-boot-env`），传 `mtd3` 会报
`Could not open mtd device`。

### 需要刷 mtd0 时：让 U-Boot 自己刷自己

进了 OpenWrt 之后 mtd0 写不动，diag 模式又随原厂 bootloader 一起没了。但 U-Boot
自带 `flash_uboot`，把它临时塞进 `bootcmd` 就行：

```powershell
python tools\mkenv.py files\uboot_ng.bin files\uboot-env-flash.bin `
    config_dts=config@4 ipaddr=192.168.1.10 serverip=192.168.1.2 `
    "bootcmd=run soc_dtscheck; mx64init; flash_uboot uboot_ng.bin 100000 confirm; run ubi_checkboot; run usb_checkboot; run tftp_checkboot; run meraki_checkboot"
```

写进 mtd3，让 TFTP 服务端（`01-serve-http.ps1` 旁边那个 `70-tftp-server.py`）跑着，
断电重启。U-Boot 会 TFTP 拉镜像、校验大小和首字（必须是 ARM 分支指令）、擦写 mtd0、
回读 CRC，然后继续正常启动。**任何一步不满足就打印 `TFTP failed, nothing was written`
直接跳过，不会留下半写的 mtd0。**

刷完记得把 `bootcmd` 换回默认（去掉 `flash_uboot`），否则每次开机都会重刷一遍。

## B0+ 的坑（OpenWrt 装完起不来的最常见原因）

U-Boot 用 `bootm ${loadaddr}#${config_dts}` 启动，而装进 NAND 的 FIT 里
**只有 `config@4`（B0+）或只有 `config@2`（A0）**，取决于你刷的 sysupgrade 镜像。
`config_dts` 选错就是无限次掉回 USB/TFTP，永远进不了装好的系统。

判断 SoC 版本的 C 代码一直是对的：

```c
uint32_t regData = __raw_readl(0x18000000);
uint32_t tmp = (regData & 0x000F0000) >> 16;
if (4 <= tmp) return 1;      /* B0+ */
else          return 0;      /* A0  */
```

坏的是**包在它外面的两个 U-Boot shell 陷阱**，它们让正确的 C 代码永远执行不到：

```c
/* 原版：hush 拿不到命令返回值，$? 永远不是 1 */
soc_dtscheck=...; getsocrev; if test $? = 1; then ... config@4; else ... config@2; fi

/* 只修了一半：变量为空时 hush 把整个引号参数丢掉，
   于是 test 只剩 "-z" 两个参数，而 common/cmd_test.c 里
       if (argc < 3) return 1;        // 返回 1 = 假
   导致 then 分支永远不执行，config_dts 一直是空的 */
soc_dtscheck=if test -z "${config_dts}"; then getsocrev set; fi
```

**v4 的写法**：把判断挪进 C，shell 里无条件调用。

```
soc_dtscheck=getsocrev set
```

```c
if (argc >= 2 && !strcmp(argv[1], "set")) {
        const char *cur = getenv("config_dts");
        if (cur && *cur) return 0;          /* 已有值就不覆盖 */
        setenv("config_dts", b0 ? "config@4" : "config@2");
}
```

教训：**U-Boot 的 `test` 在参数不足时静默返回假**，不会报错。任何"变量为空"
的判断在这种 shell 里都不可靠。v4 起即使环境被完全擦除，U-Boot 也能自己认对 SoC
版本（已在真机上把 `u-boot-env` 擦成全 0xFF 验证：零 TFTP 请求、直接从 UBI 启动）。

`files/uboot-env.bin` 里仍然带 `config_dts=config@4`，那是给老版本 U-Boot 兜底用的��
v4 下不影响（C 代码看到已有值就不覆盖）。

## U-Boot 版本历史

`files/uboot_ng.bin` 经历过的每一次修正，都是真机刷坏之后才发现的。凡是涉及 U-Boot
shell 条件判断的地方都栽过，最后关键逻辑都被挪进了 C。

| 版本 | 修了什么 | 留下的坑 |
|---|---|---|
| v2 | 初始可刷版本 | `soc_dtscheck` 用 `if test $? = 1`，而 hush 拿不到命令返回值 → 永远选 `config@2`(A0) |
| v3 | 改成 `getsocrev set`，由命令自己 `setenv` | `if test -z "${config_dts}"` 在变量为空时退化成 `test -z`（只剩 2 个参数），而 `cmd_test.c` 里 `if (argc < 3) return 1;` 返回假 → `then` 分支永不执行 |
| v4 | `soc_dtscheck=getsocrev set` 无条件调用，判断挪进 C | `ipaddr` 编译默认值 `192.168.0.1` 和 `serverip 192.168.1.2` 跨网段 → U-Boot 不 ACK OACK，TFTP 死在 `block 1/11779` |
| **v5** | 网络三件套同网段（`192.168.1.10` / `192.168.1.2` / `255.255.255.0`），并去掉 `tftp_boot` 里的 `test -z` 判断 | 当前版本 |

**通用教训**：U-Boot 的 shell 条件判断不可靠 —— `$?` 拿不到返回值，`test` 在参数不足时
静默返回假。任何"变量为空就做某事"的判断都不要写在 env 脚本里。

版本可以用 `mx64info` 的 `Tag` 行确认，或直接从设备读：

```sh
dd if=/dev/mtd0 bs=4096 count=146 2>/dev/null | strings | grep -o 'mx64-ng-[0-9a-zA-Z\.-]*'
```

## 参考

- OpenWrt wiki: <https://openwrt.org/toh/meraki/mx64>
- clayface U-Boot 与二进制: <https://github.com/clayface/U-Boot-MX64-20190430_MX64>
- OpenWrt PR #16634: <https://github.com/openwrt/openwrt/pull/16634>
