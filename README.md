# Meraki MX64 / MX64W OpenWrt 刷机包

依据 <https://openwrt.org/toh/meraki/mx64> 整理，并把每一步做成了可复制的脚本。
**刷 U-Boot 有变砖风险**，动手前请先读完「0. 先决策」和「故障排查」。

本仓库: <https://github.com/FusionPlmH/mx64-openwrt-flash>
配套 U-Boot 源码: <https://github.com/FusionPlmH/mx64-uboot-refresh>

## 我该用哪个镜像？（先看这张表）

关键只有一件事：**你的 `mtd0` 有多大**（`cat /proc/mtd`，diagnostic mode 或 OpenWrt 里都能看）。

| 你的 mtd0 | 刷的 U-Boot | 引导进 OpenWrt 用的文件 | 需要 `-initramfs-kernel.bin` 吗 |
|---|---|---|---|
| `00100000`（1 MiB）**大多数机器** | `uboot_mx64` 或 `uboot_ng.bin` | `openwrt-bcm53xx-generic-meraki_mx64[-a0]-initramfs.bin`（FIT，`bootm`） | **不需要** |
| `00080000`（512 KiB） | `uboot_mx64_small` | `openwrt-bcm5862x-generic-meraki_mx64[a0]-initramfs-kernel.bin`（SPIM，`bootbk`） | **需要**，只用来把 boot 分区换成 1 MiB 布局 |

这两类文件是完全不同的容器格式，不是同一个东西的两种版本：

| 文件 | 容器 | 谁引导它 | 干什么用 |
|---|---|---|---|
| `openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin` | **FIT**（首字节 `d0 0d fe ed`） | U-Boot `bootm` | 正常的 OpenWrt RAM 系统，装完 sysupgrade 就完整了 |
| `openwrt-bcm5862x-generic-meraki_mx64-initramfs-kernel.bin` | **SPIM**（首字节 `53 50 49 4d`） | Meraki loader / U-Boot `bootbk` | 只有 512 KiB 的老机器需要：里面带着 1 MiB 版 `uboot_mx64`，用来 `mtd write` 换布局 |

所以：**刷过 U-Boot（`uboot_mx64`）之后，只需要 `openwrt-bcm53xx-...-initramfs.bin` + sysupgrade**，
`-initramfs-kernel.bin` 那个只跟"512 KiB → 1 MiB"的升级有关，正常路径用不到（放着也没关系，
两个文件同时存在时代码会先试 FIT，不会选错）。

## 不确定自己刷到哪一步了？几条命令看清楚

诊断模式或 OpenWrt 的 shell 里：

```sh
cat /proc/mtd                 # mtd0 多大 -> 决定 uboot_mx64 还是 uboot_mx64_small
cat /sys/block/mtdblock0/ro   # 1 = 写保护没解，0 = 可写
```

已经能 SSH 进 OpenWrt 的话：

```sh
cat /proc/cmdline             # root= 后面是 /dev/ubiblock0_0 => 装进 NAND 了
                              # root=/dev/ram0 或 ramdisk    => 还在 RAM 里（initramfs）
df -h /overlay                # 有 /overlay 且大小 ~数百 MB => sysupgrade 过
ubinfo -a                     # 有 rootfs_data 卷 = 已经装好；只剩 part.*/storage => 还没装
```

在 U-Boot 提示符里：

```sh
version                       # clayface 版不带 tag；本项目的带 "mx64-ng-2012.10-v2"
mx64info                      # 本项目的 U-Boot 才有这条命令
```

判断口诀：**能 `df -h` 看到 `/overlay` 有几百 MB，就说明 OpenWrt 已经落到 NAND 上了**，
那 `-initramfs-kernel.bin` 这一整套过渡流程你已经走完（或者根本不需要走）。

## 脚本已经替你做掉的判断

`one-shot-diag.sh` 会自己按下表决定，**不需要你选任何东西**：

| 判断项 | 依据 | 结果 |
|---|---|---|
| 刷哪个 U-Boot | `awk '/^mtd0:/{print $2}' /proc/mtd` | `≥ 0x100000` → `uboot_mx64`；否则 → `uboot_mx64_small` |
| 要不要解锁 mtd0 | `cat /sys/block/mtdblock0/ro` | `1` → `insmod mtd-rw.ko i_want_a_brick=1` 并回读确认变成 `0`；`0` → 直接 `dd` |
| 写还是 dd | 上一条的结论 | 解锁过 → `mtd write`；没锁 → `dd of=/dev/mtdblock0` |
| A0 还是 B0+ | `devmem 0x18000000` 的 `0x3F00`–`0x3F03` | 只影响**之后**用哪个 initramfs 文件名（U-Boot 镜像本身不分 A0/B0+） |
| 传输方式 | 命令行参数 / 默认值 | 先 TFTP，失败回退 HTTP；两个都失败才退出 |
| 文件对不对 | 内嵌的期望长度 + SHA512 | 不符就 `!!` 停在第 3 步，绝不写 |
| 写完对不对 | 回读前 64 KiB 比对 | 不一致 → `!!` 让你重刷 |

想先看结论再决定要不要刷，用 `--check`（只读，不写任何东西）：

```sh
sh one-shot-diag.sh --check
```

输出示例：

```
==== 1/6 检测设备 ====
   chip 0x18000000 = 0x3F040000 -> b0
   mtd0 size       = 00100000 (1048576 bytes)
   mtd0 read-only  = 1
   决定: TARGET=uboot_mx64 NEED_UNLOCK=yes

==== --check：只看结论，什么都没写 ====
  SoC      : B0+ -> initramfs 用 openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin
  mtd0     : 00100000 (1048576 字节)
  刷哪个   : uboot_mx64 (587312 字节, 会用内嵌 SHA512 校验)
  解锁     : 需要（insmod mtd-rw.ko i_want_a_brick=1），之后用 mtd write
  后续     : 断电后直接引导 openwrt-bcm53xx-...-initramfs.bin（第 7 节），不需要过渡固件
```

PC 侧也能只看：`00-flash.ps1 -Check`（同样的结论，走 telnet 拿回来）。

## 先回答几个常见问题

| 问题 | 答案 |
|---|---|
| 第一次装 U-Boot 要按 reset 吗？ | **要**。原厂固件只有 diagnostic mode 才给 shell，没有别的入口（这部分没法绕）。 |
| 之后刷 initramfs 还要按 reset 吗？ | **不用**，只要用的是本仓库的 `uboot_ng.bin`。引导顺序是 UBI → USB → TFTP（USB 和 TFTP 都默认开），前一个失败自动试下一个，全程不碰按键。 |
| 刷机脚本默认走什么传输？ | **TFTP**（`00-flash.ps1` 默认，PC 上要管理员权限起 UDP 69）。TFTP 不可用时设备端会自动回退到 HTTP。 |
| 能不能一条命令刷完？ | 能。`scripts\00-flash.ps1` 在 PC 上起好服务并 telnet 注入 `one-shot-diag.sh`，设备端检测/校验/写入/回读全自动。 |

## 目录内容

```
README.md                    本文件
SHA256SUMS                   所有文件的校验值
files/                       设备要用的文件（拷到 U 盘根目录 / HTTP 服务器根目录）
  uboot_mx64                 1 MiB boot 分区用的 U-Boot（clayface，U-Boot 2012.10）
  uboot_mx64_small           512 KiB boot 分区用的 U-Boot（同上，裁剪版）
  uboot_ng.bin               本项目的 U-Boot（含 bootimg/flash_uboot/TFTP，598,172 B）
  mtd                        busybox mtd 工具（解锁写保护后写分区用）
  mtd-rw.ko                  mtd0 写保护解锁模块（仅 mtd0 只读时需要）
  openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin            OpenWrt RAM 系统 B0+（FIT）
  openwrt-bcm53xx-generic-meraki_mx64-a0-initramfs.bin         OpenWrt RAM 系统 A0（FIT）
  openwrt-25.12.6-bcm53xx-generic-meraki_mx64-squashfs.sysupgrade.bin    装到 NAND 用 B0+
  openwrt-25.12.6-bcm53xx-generic-meraki_mx64-a0-squashfs.sysupgrade.bin 装到 NAND 用 A0
  openwrt-bcm5862x-generic-meraki_mx64-initramfs-kernel.bin    ★ 只有 512 KiB 机器才用（SPIM 过渡固件）B0+
  openwrt-bcm5862x-generic-meraki_mx64a0-initramfs-kernel.bin  ★ 只有 512 KiB 机器才用（SPIM 过渡固件）A0
scripts/
  00-flash.ps1               PC 侧一键：起服务 + telnet 注入 + 全程自动（-DryRun 只看计划）
  01-serve-http.ps1          PC 侧：起 HTTP 服务器（只想起服务、手动敲命令时用）
  02-copy-to-usb.ps1         PC 侧：把 files/ 拷到 U 盘并校验
  03-fetch-backup.ps1        PC 侧：把备份从设备拉回来
  70-tftp-server.py          PC 侧：只读 TFTP 服务器（UDP 69，给 U-Boot 用）
  one-shot-diag.sh           设备侧一键：检测 → 解锁 → 下载 → 校验 → 写入 → 回读（HTTP/TFTP 都行）
  10-device-check.sh         设备侧（diagnostic mode）：判断 A0/B0+、mtd0 大小、是否只读
  20-install-uboot.sh        设备侧（diagnostic mode）：写 U-Boot
  30-write-uboot-from-openwrt.sh  设备侧（过渡固件里）：换成 1 MiB 版 U-Boot
  40-backup-flash.sh         设备侧（OpenWrt 里）：备份原厂分区
  50-sysupgrade.sh           设备侧（OpenWrt 里）：sysupgrade
  60-reclaim-space.sh        设备侧（OpenWrt 里）：删掉原厂火山灰卷，扩 rootfs_data
  90-uboot-tftp.txt          U-Boot 提示符下的命令清单：TFTP 引导 initramfs / flash_uboot 重写 bootloader
```

镜像来源：
`uboot_mx64*`、`mtd`、`mtd-rw.ko`、`openwrt-bcm5862x-*`（过渡固件）来自
[clayface/U-boot-MX64-20190430_MX64](https://github.com/clayface/U-boot-MX64-20190430_MX64)；
`openwrt-bcm53xx-*-initramfs.bin` 来自 OpenWrt SNAPSHOT；
`openwrt-25.12.6-*.sysupgrade.bin` 来自 OpenWrt 25.12.6 正式版；
`uboot_ng.bin` 由本项目源码用 Bootlin `armv7-eabihf--glibc--stable`（GCC 5.4）编译。

---

## 一条命令刷完（推荐）

前提只有一条：设备已经在 diagnostic mode，PC 网卡是 `192.168.1.2/24`。

```powershell
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -DryRun   # 先看它要做什么
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1           # 真跑（默认 TFTP）
```

`00-flash.ps1` 会自动：把 `files/` + `*.sh` 摊到一个临时目录 → 起 TFTP（同时起 HTTP 作备用）→
连 `192.168.1.1:23` → 注入一行命令让设备跑 `one-shot-diag.sh <主传输> <备用传输>` →
把设备输出实时打出来 → 结束后关掉服务。

设备端的 `one-shot-diag.sh` 自己完成：判定 A0/B0+ 和 `mtd0` 大小 → 决定刷
`uboot_mx64` 还是 `uboot_mx64_small` → （需要时）`insmod mtd-rw.ko` 解锁 →
下载（**先 TFTP，取不到自动换 HTTP**）→ 长度 + SHA512 校验 → 写 `mtd0` →
回读前 64 KiB 比对。任何一步不符合预期就 `!!` 报错停下，不会乱写。

传输方式：

| 命令 | 传输 | 权限 |
|---|---|---|
| `00-flash.ps1` | 默认 **TFTP**（主）+ HTTP（备用） | TFTP 要**管理员**（UDP 69） |
| `00-flash.ps1 -Transport http` | HTTP（主）+ TFTP（备用） | 不需要管理员 |

TFTP 起不来也不影响：脚本会提示一句，然后设备端自动回退到 HTTP。
想只要服务、自己敲命令：

```powershell
python scripts\70-tftp-server.py            # 服务 files/，UDP 69
powershell -ExecutionPolicy Bypass -File scripts\01-serve-http.ps1   # 或只要 HTTP
```

设备侧手动跑一键脚本：

```sh
sh one-shot-diag.sh                                   # 默认 tftp://192.168.1.2，失败回退 http
sh one-shot-diag.sh tftp://192.168.1.2 http://192.168.1.2:8000
```

> 原厂 diagnostic mode 的 busybox 不一定带 `tftp` applet。带就用 TFTP，不带会自动走 HTTP，
> 两种都能刷。

---

## 0. 先决策（不做这三步不要动手）

| 要确认的事 | 怎么查 | 后果 |
|---|---|---|
| **A0 还是 B0+** | `devmem 0x18000000`，值 `0x3F00`–`0x3F03` → A0，其余 → B0+ | 用错镜像内核起不来 |
| **mtd0 大小** | `cat /proc/mtd`，`mtd0` 是 `00100000` 还是 `00080000` | `0x80000` 只能先刷 `uboot_mx64_small` |
| **mtd0 是否只读** | `cat /sys/block/mtdblock0/ro`，`1` = 被锁 | 需要 `mtd-rw.ko` + `mtd` 才能写 |

`10-device-check.sh` 会把这三件事一次跑完并给出结论。

## 1. 准备 U 盘

- 一个普通 U 盘，**MBR** 分区表，第一个分区 **FAT32**（wiki 建议 FAT16 128 MB；U 盘较大时 FAT32 更省事）。
- 分区里**只保留本工具包的文件**，根目录下不要有其它 `openwrt-*` 文件，避免引导到旧镜像。
- 写入：`powershell -ExecutionPolicy Bypass -File scripts\02-copy-to-usb.ps1 -Drive E:\`

为什么 initramfs 文件名不能改：clayface / 本项目的 U-Boot 都是**按固定文件名**去 FAT 里找
`openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin`，改名就找不到。
（本项目 U-Boot 支持 `bootimg` 自动识别镜像类型，可手动指定任意文件名，见第 11 节。）

## 2. PC 侧起 HTTP 服务器（diagnostic mode 用它下发文件）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\01-serve-http.ps1
```

脚本会打印本机 IPv4，例如 `192.168.1.2`。**PC 的网卡要手动设成 `192.168.1.2/24`**，
网关不填（设备在 diagnostic mode 里就是 `192.168.1.1`）。

## 3. 进入 diagnostic mode（原厂固件）

1. 网线插任一 LAN 口（可先插好）。
2. 按住 reset 键上电。前灯先橙色，然后**橙色熄灭、白灯闪两下** —— 看到白闪即可松手。
   （二手设备白灯可能看不清，那就按住约 15 秒再松。）
3. 松手后再等约 15 秒，灯熄灭后变绿。如果变成彩虹色，断电重来。
4. PC 上 `telnet 192.168.1.1`（Windows 需要先 `dism /online /enable-feature /featurename:TelnetClient`）。

> 串口也能进，但某些 USB 转串口会阻止设备启动；必要时等白灯闪起再接 TXD。

## 4. 设备检查

把 `scripts/10-device-check.sh` 的内容贴进 telnet（或用 HTTP 拉下来执行）：

```sh
cd /tmp && wget http://192.168.1.2:8000/10-device-check.sh && sh 10-device-check.sh
```

输出示例：

```
SoC revision : 0x3F04 (>= 0x3F04)  -> B0+ 机型，用常规镜像
mtd0         : 00100000 (1 MiB)    -> 可以刷 uboot_mx64
mtd0 ro      : 0                   -> 不需要解锁
结论: TARGET=uboot_mx64  NEED_UNLOCK=no
```

结论会写进 `/tmp/mx64-check.env`，后面的脚本直接读它。

## 5. 刷 U-Boot

```sh
cd /tmp && wget http://192.168.1.2:8000/20-install-uboot.sh && sh 20-install-uboot.sh
```

默认先走 TFTP（`tftp://192.168.1.2`），取不到自动回退 `http://192.168.1.2:8000`。
脚本做的事：

1. 取对应镜像到 `/tmp`；
2. 用**内嵌的 SHA512 期望值**校验（设备上没 `sha512sum` 时退化为长度校验并警告）；
3. 只读时先 `insmod mtd-rw.ko i_want_a_brick=1`，再回读 `/sys/block/mtdblock0/ro` 确认真的解锁；
4. 只读 → `mtd write <img> /dev/mtd0`；可写 → `dd if=<img> of=/dev/mtdblock0`；
5. 回读前 64 KiB 做一次比对，然后 `sync`。

刷的是 `uboot_mx64`（mtd0 = 1 MiB）就**已经完事**了，断电，直接跳到第 7 节引导
`openwrt-bcm53xx-...-initramfs.bin` → 第 9 节 sysupgrade。**不需要** `-initramfs-kernel.bin`。

## 6. 如果只能刷 `uboot_mx64_small`（mtd0 = 0x80000）

**只有这一节需要 `-initramfs-kernel.bin`**，它是"过渡固件"：一个 SPIM 容器的 Linux，
里面自带 1 MiB 版 `uboot_mx64`，专门用来把 512 KiB 的 boot 分区升级成 1 MiB 布局。

1. 把 `openwrt-bcm5862x-generic-meraki_mx64-initramfs-kernel.bin`（A0 用 `..._mx64a0-...`）
   放在 U 盘根目录（或 TFTP 根目录），插上设备；
2. 按住 reset 上电 → 白/橙交替快闪 → 松手，设备从 U 盘引导进过渡固件（OpenWrt）。
   （**这一步要按 reset**：`uboot_mx64_small` 是 clayface 的版本，它的引导逻辑是按键触发的；
   换成 `uboot_ng.bin` 之后就不用再按了，见第 7 节。）
3. `ssh root@192.168.1.1`（无密码）；
4. 执行 `scripts/30-write-uboot-from-openwrt.sh`，它把过渡固件里自带的 `/root/uboot_mx64`
   写到 `mtd0`，把 boot 分区换成 1 MiB 版布局；
5. **不要重启**，直接做第 9 节 sysupgrade。
6. 换完 U-Boot 后第一次启动要重做 Shmoo 校准，会**很久**（几分钟）。橙白闪说明 UBI 引导失败：
   这时用 U 盘引导 initramfs 重装 OpenWrt，**不要再刷 U-Boot**。
7. 换完之后这个过渡固件就再也用不到了，可以删掉。

## 7. 启动 OpenWrt（正常路径，默认走 TFTP，不用按 reset）

刷完 `uboot_mx64` / `uboot_ng.bin`（mtd0 = 1 MiB）之后，引导的是
`openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin`（FIT），**跟 `-initramfs-kernel.bin` 无关**。

默认行为：`enable_usb_boot=1`、`enable_tftp_boot=1`，引导顺序是

```
UBI 里能起内核        -> 直接起 OpenWrt（不碰 U 盘/网络）
UBI 起不来（空/坏）   -> 自动 usbload（U 盘，3 次尝试，2 条总线，2 个文件名）
U 盘也不行            -> 自动 tftp_boot（网络）
```

USB 和 TFTP 都默认开着，所以：**NAND 是空的就自己找 U 盘，找不到再上网，全程不按 reset**。

### 7a. 走 TFTP

PC 上（TFTP 需要管理员权限 / root）：

```powershell
python scripts\70-tftp-server.py            # 服务 files/，UDP 69
```

PC 网卡设成 `192.168.1.2/24`，网线接 LAN 口，然后**直接上电**（不插 U 盘就会走 TFTP）。

`tftp_boot` 会按顺序试三个文件名，第一个能加载的就引导（`bootimg` 按镜像头判断类型）：

| 顺序 | 文件名 | 类型 |
|---|---|---|
| 1 | `${tftp_file}`（你自己设的，可选） | 任意 |
| 2 | `openwrt-bcm53xx-generic-meraki_mx64[-a0]-initramfs.bin` | FIT → `bootm`（**正常路径用的就是它**） |
| 3 | `openwrt-bcm5862x-generic-meraki_mx64[a0]-initramfs-kernel.bin` | SPIM 过渡固件 → `bootbk`（只有 512 KiB 机器才需要） |

所以 `files/` 里的东西**原样放在 TFTP 根目录**就行，不需要改名。
A0/B0+ 由 `config_dts` 自动决定用哪套文件名。

想手动控制（上电后 3 秒内按任意键停在提示符）：

```
setenv ipaddr 192.168.1.10
setenv serverip 192.168.1.2
setenv ethaddr <你标签上的 MAC>
tftp_boot
```

只想刷某一个固定文件：

```
setenv tftp_file openwrt-bcm5862x-generic-meraki_mx64-initramfs-kernel.bin
tftp_boot
```

开关（两个默认都是 1，按需关掉）：

```
setenv enable_usb_boot 0      # 不想让它在 U 盘上浪费时间
setenv enable_tftp_boot 0     # 不自动走网络
setenv disable_ubi_boot 1     # 跳过 UBI，直接走 USB/TFTP
saveenv
```

### 7b. 从 U 盘

默认就开着，U 盘根目录放 `openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin`
（A0 用 `-a0-` 那个名字）。白灯闪 3 下 = 开始尝试 USB；灯常橙 = 引导中；
之后绿闪（先快后慢）→ 绿色常亮 = 起来了。

## 8. 备份原厂分区（强烈建议，先备份再 sysupgrade）

设备侧：

```sh
cd /tmp && wget http://192.168.1.2:8000/40-backup-flash.sh && sh 40-backup-flash.sh
```

会在 `/tmp/backup/` 生成 `mtd0..mtd4` 的 gzip、`proc-mtd.txt`、`ubinfo.txt`、`board-config.tar.gz`
（`board-config` 卷必须保留，里面是设备身份信息）。

PC 侧拉回：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\03-fetch-backup.ps1 -OutDir C:\mx64-backup
```

## 9. sysupgrade

把对应版本的 sysupgrade 传到设备：

```powershell
scp -O "files\openwrt-25.12.6-bcm53xx-generic-meraki_mx64-squashfs.sysupgrade.bin" root@192.168.1.1:/tmp/
```

设备侧：

```sh
cd /tmp && wget http://192.168.1.2:8000/50-sysupgrade.sh && sh 50-sysupgrade.sh /tmp/openwrt-25.12.6-bcm53xx-generic-meraki_mx64-squashfs.sysupgrade.bin
```

会自动重启。装完 OpenWrt 默认地址 `192.168.1.1`，`root` 无密码（首次登录请立刻设密码）。

## 10. 释放被原厂占用的 flash（可选，建议做）

原厂固件在 1 GiB NAND 里塞了一堆卷，不删只有约 370 MiB 可用：

```sh
cd /tmp && wget http://192.168.1.2:8000/60-reclaim-space.sh && sh 60-reclaim-space.sh
```

然后**再执行一次 sysupgrade**（同一个镜像），OpenWrt 会把 `rootfs_data` 扩建到剩余全部空间。
`ubinfo -a` 复查。**不要删 `board-config`。**

## 11. 用本项目的 U-Boot（`uboot_ng.bin`）时的额外能力

`uboot_ng.bin` 是 `mx64-uboot-ng` 的构建产物（GCC 5.4，598,172 B），需要 **1 MiB** 的 boot 分区，
特性：

| 命令 | 作用 |
|---|---|
| `mx64init` | 初始化外设 + 读 reset 键（开机自动执行） |
| `tftp_boot` | TFTP 拉镜像并 `bootimg`：先试 `${tftp_file}`，再试 FIT initramfs，再试 SPIM 过渡固件 |
| `usbload` | 从 U 盘 FAT 里按文件名列表尝试引导（默认关闭，`setenv enable_usb_boot 1` 打开） |
| `bootimg <addr> [part]` | 按镜像头自动选择 `bootm`（FIT/uImage）或 `bootbk`（Meraki SPIM 过渡固件） |
| **`flash_uboot <file> <分区大小hex> confirm`** | **TFTP 取新 U-Boot → 校验 → 擦/写 mtd0 → 回读 CRC 比对**，从此不用 diag 模式 |
| `bootbk <addr> <part>` | 启动 Meraki bootkernel（校验头部 CRC32） |
| `mx64info` | 打印版本、SoC、reset 状态、环境变量 |

### 用 TFTP 升级 U-Boot（不用按 reset、不用 U 盘、不用 diag 模式）

这是刷完第一次之后的正规升级方式：

```
# U-Boot 提示符下（上电后 3 秒内按任意键）
setenv ethaddr 0c:8d:db:90:0a:a0        # 标签上的 MAC，只需设一次
setenv ipaddr 192.168.1.10
setenv serverip 192.168.1.2
ping 192.168.1.2
flash_uboot uboot_ng.bin 100000 confirm
reset
```

参数含义：

- `uboot_ng.bin`：TFTP 服务器上的文件名（PC 上跑 `python scripts\70-tftp-server.py`）
- `100000`：**mtd0 的真实大小**，十六进制。512 KiB 的机器要写 `80000`
  （拿不准就在 OpenWrt 里 `cat /proc/mtd` 看一眼）。擦除会覆盖整个分区，
  而 shmoo 分区紧跟在 `0x80000` 后面，所以这个值必须准确。
- `confirm`：不写就拒绝执行，防止手滑。

它会做完整流程：`tftpboot` → 检查首字是 ARM 跳转指令、长度 <= 分区 → `nand erase` →
`nand write` → `nand read` 回来比 CRC32 → 只有完全一致才打印 `OK`。
**中途断电就变砖**，所以刷的时候最好接着串口。

### LED 码

琥珀=电源常亮；白灯 3 次连闪=开始 USB 尝试，1 闪=没检测到 U 盘，2 闪=有盘但没找到/加载不了文件，
3 闪=文件加载了但没引导成功。**这些只在走 USB 路径时才会出现**；如果没插 U 盘直接走 TFTP，
灯只会常橙 → 绿闪 → 绿常亮。

### 引导顺序（这就是"不用按 reset"的原因）

```
run soc_dtscheck; mx64init; run ubi_checkboot; run tftp_checkboot; run usb_checkboot; run meraki_checkboot
```

UBI → USB → **TFTP** → meraki 依次尝试，前一个失败才走下一个。
USB 和 TFTP 默认都开（`enable_usb_boot=1`、`enable_tftp_boot=1`），空 NAND 会先试 U 盘再上网。
完整命令清单见 [scripts/90-uboot-tftp.txt](scripts/90-uboot-tftp.txt)。

TFTP 恢复：

```
setenv ethaddr <你标签上的 MAC>
setenv gmac 1
setenv ipaddr 192.168.1.10
setenv serverip 192.168.1.2
ping 192.168.1.2
tftp_boot
```

写它进去：

```sh
# diagnostic mode（mtd0 必须是 1 MiB 且已解锁）
wget http://192.168.1.2:8000/uboot_ng.bin -O /tmp/uboot_ng.bin
insmod /tmp/mtd-rw.ko i_want_a_brick=1   # 只在 mtd0 只读时需要
/tmp/mtd write /tmp/uboot_ng.bin /dev/mtd0
```

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| diagnostic mode 里 `ping 192.168.1.2` 不通 | PC 网卡没设成 `192.168.1.2/24`、防火墙拦了、或网线插在 WAN 口 |
| `wget` 报 404 | HTTP 服务器目录不对，要在 `files/` 里起服务，或文件名打错 |
| `insmod mtd-rw.ko` 报错 | 内核版本不匹配（这个 ko 只对原厂 diag 内核有效）；确认 `cat /sys/block/mtdblock0/ro` 到底是不是 1 |
| U 盘引导不进去 | 文件名必须完全一致；FAT32/MBR；换 U 盘；删掉 U 盘上其它分区 |
| 换 U-Boot 后第一次开机橙白闪、很久不起来 | Shmoo 校准中；等几分钟，不行就断电再上电。仍失败则用 U 盘 initramfs 重装，**别再刷 U-Boot** |
| 装完后只有 ~370 MiB 可用 | 见第 10 节 |
| 刷完 U-Boot 完全没输出 | 上串口；确认用的是 A0/B0+ 对应镜像、mtd0 大小匹配 |

## 参考

- OpenWrt wiki: <https://openwrt.org/toh/meraki/mx64>
- clayface U-Boot 与二进制: <https://github.com/clayface/U-boot-MX64-20190430_MX64>
- OpenWrt PR #16634（MX64 支持合入）: <https://github.com/openwrt/openwrt/pull/16634>
- 本项目 U-Boot 源码: <https://github.com/FusionPlmH/mx64-uboot-refresh>
