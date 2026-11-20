# Meraki MX64 / MX64W OpenWrt 刷机包

依据 <https://openwrt.org/toh/meraki/mx64> 整理，并把每一步做成了可复制的脚本。
**刷 U-Boot 有变砖风险**，动手前请先读完「0. 先决策」和「故障排查」。

本仓库: <https://github.com/FusionPlmH/mx64-openwrt-flash>
配套 U-Boot 源码: <https://github.com/FusionPlmH/mx64-uboot-refresh>

## 先回答三个常见问题

| 问题 | 答案 |
|---|---|
| 第一次装 U-Boot 要按 reset 吗？ | **要**。原厂固件只有 diagnostic mode 才给 shell，没有别的入口（这部分没法绕）。 |
| 之后刷 initramfs 还要按 reset 吗？ | **不用**，只要用的是本仓库的 `uboot_ng.bin`。引导顺序是 UBI → USB → TFTP，前一个失败自动试下一个，全程不碰按键。 |
| 能不能一条命令刷完？ | 能。`scripts\00-flash.ps1` 在 PC 上起好服务并 telnet 注入 `one-shot-diag.sh`，设备端检测/校验/写入/回读全自动。 |

## 目录内容

```
README.md                    本文件
SHA256SUMS                   所有文件的校验值
files/                       设备要用的文件（拷到 U 盘根目录 / HTTP 服务器根目录）
  uboot_mx64                 1 MiB boot 分区用的 U-Boot（clayface，U-Boot 2012.10）
  uboot_mx64_small           512 KiB boot 分区用的 U-Boot（同上，裁剪版）
  uboot_ng.bin               本项目的 U-Boot（含 bootimg/flash_uboot/TFTP，597,636 B）
  mtd                        busybox mtd 工具（解锁写保护后写分区用）
  mtd-rw.ko                  mtd0 写保护解锁模块（仅 mtd0 只读时需要）
  openwrt-bcm5862x-generic-meraki_mx64-initramfs-kernel.bin    过渡固件 B0+
  openwrt-bcm5862x-generic-meraki_mx64a0-initramfs-kernel.bin  过渡固件 A0
  openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin            OpenWrt initramfs B0+
  openwrt-bcm53xx-generic-meraki_mx64-a0-initramfs.bin         OpenWrt initramfs A0
  openwrt-25.12.6-bcm53xx-generic-meraki_mx64-squashfs.sysupgrade.bin     B0+
  openwrt-25.12.6-bcm53xx-generic-meraki_mx64-a0-squashfs.sysupgrade.bin  A0
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
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1           # 真跑
```

`00-flash.ps1` 会自动：把 `files/` + `*.sh` 摊到一个临时目录 → 起 HTTP 服务 →
连 `192.168.1.1:23` → 注入一行命令让设备跑 `one-shot-diag.sh` → 把设备输出实时打出来 →
结束后关掉服务。

设备端的 `one-shot-diag.sh` 自己完成：判定 A0/B0+ 和 `mtd0` 大小 → 决定刷
`uboot_mx64` 还是 `uboot_mx64_small` → （需要时）`insmod mtd-rw.ko` 解锁 →
下载 → 长度 + SHA512 校验 → 写 `mtd0` → 回读前 64 KiB 比对。任何一步不符合预期就
`!!` 报错停下，不会乱写。

想用 TFTP 而不是 HTTP 传输（同一个脚本，换协议）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -Transport tftp
```

TFTP 需要 UDP 69，**必须以管理员身份运行**。也可以手动来：

```powershell
python scripts\70-tftp-server.py            # 服务 files/，UDP 69
```

设备侧：

```sh
sh one-shot-diag.sh tftp://192.168.1.2
```

> 原厂 diagnostic mode 的 busybox 不一定带 `tftp` applet。脚本会先检查，没有就让你
> 改用 HTTP。**真正的 TFTP 主场是刷完 U-Boot 之后**（见第 11 节），U-Boot 的
> `tftpboot` 是原生支持的。

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
cd /tmp && wget http://192.168.1.2:8000/20-install-uboot.sh && sh 20-install-uboot.sh http://192.168.1.2:8000
```

脚本做的事：
1. 从 HTTP 服务器 `wget` 对应镜像到 `/tmp`；
2. 用**内嵌的 SHA512 期望值**校验（设备上没 `sha512sum` 时退化为长度校验并警告）；
3. 只读时先 `insmod mtd-rw.ko i_want_a_brick=1`，再从 `dmesg` 确认
   `_mtd-rw: mtd0: setting writeable flag_`；
4. 只读 → `mtd write <img> /dev/mtd0`；可写 → `dd if=<img> of=/dev/mtdblock0`；
5. 回读前 64 KiB 做一次比对，然后 `sync`。

完成后**断电**。

## 6. 如果只能刷 `uboot_mx64_small`（mtd0 = 0x80000）

1. 把 `openwrt-bcm5862x-generic-meraki_mx64-initramfs-kernel.bin`（A0 用 `..._mx64a0-...`）
   放在 U 盘根目录，插上设备；
2. 按住 reset 上电 → 白/橙交替快闪 → 松手，设备从 U 盘引导进过渡固件（OpenWrt）。
   （**这一步要按 reset**：`uboot_mx64_small` 是 clayface 的版本，它的引导逻辑是按键触发的；
   换成 `uboot_ng.bin` 之后就不用再按了，见第 7 节。）
3. `ssh root@192.168.1.1`（无密码）；
4. 执行 `scripts/30-write-uboot-from-openwrt.sh`，它把过渡固件里自带的 `/root/uboot_mx64`
   写到 `mtd0`，把 boot 分区换成 1 MiB 版布局；
5. **不要重启**，直接做第 9 节 sysupgrade。
6. 换完 U-Boot 后第一次启动要重做 Shmoo 校准，会**很久**（几分钟）。橙白闪说明 UBI 引导失败：
   这时用 U 盘引导 initramfs 重装 OpenWrt，**不要再刷 U-Boot**。

## 7. 启动 OpenWrt initramfs

有两种方式，**都不需要按 reset**（前提是已经刷了 `uboot_ng.bin`）。

### 7a. 从 U 盘

1. U 盘（根目录有 `openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin`）插好；
2. 上电。`uboot_ng.bin` 的引导顺序是：

   ```
   UBI 里能起内核        -> 直接起 OpenWrt，不碰 U 盘/网络
   UBI 起不来（空/坏）   -> 自动 usbload（U 盘，3 次尝试，2 条总线，2 个文件名）
   还是不行              -> 自动 tftp_boot（网络）
   ```

   所以刷完 U-Boot 第一次上电、NAND 里还没有 OpenWrt 时，它会**自己**去找 U 盘/网络，
   不用按 reset，也不用按键；
3. 白灯闪 3 下 = 开始尝试 USB；灯常橙 = 引导中；之后绿闪（先快后慢）→ 绿色常亮 = 起来了；
4. 起不来就删掉文件重拷一次，或换 U 盘 / 删掉 U 盘上其它分区。

### 7b. 走 TFTP（不用 U 盘）

PC 上（TFTP 需要管理员权限）：

```powershell
python scripts\70-tftp-server.py            # 服务 files/，UDP 69
```

设备上电后什么都不用按；如果 UBI 和 USB 都没成功，它会用
`ipaddr=192.168.1.10 / serverip=192.168.1.2` 自己 `tftp_boot`。
想手动来，就在 `BOOTDELAY` 3 秒内按任意键停在提示符，然后：

```
setenv ipaddr 192.168.1.10
setenv serverip 192.168.1.2
tftp_boot
```

`tftp_boot` 会按 SoC 版本选文件名，拉下来后交给 `bootimg`（FIT 走 `bootm`，
Meraki 的 SPIM 过渡固件走 `bootbk`）。完整命令见 `scripts/90-uboot-tftp.txt`。

关掉自动网络尝试：`setenv enable_tftp_boot 0; saveenv`
（同理 `enable_usb_boot 0` 关 U 盘、`disable_ubi_boot 1` 跳过 UBI）。

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

`uboot_ng.bin` 是 `mx64-uboot-ng` 的构建产物（GCC 5.4，597,636 B），需要 **1 MiB** 的 boot 分区，
特性：

| 命令 | 作用 |
|---|---|
| `mx64init` | 初始化外设 + 读 reset 键（开机自动执行） |
| `usbload` | 从 U 盘 FAT 里按文件名列表尝试引导 |
| `bootimg <addr> [part]` | 按镜像头自动选择 `bootm`（FIT/uImage）或 `bootbk`（Meraki SPIM 过渡固件） |
| `tftp_boot` | TFTP 拉 initramfs 并 `bootimg`（`ipaddr=192.168.1.10`，`serverip=192.168.1.2`） |
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
3 闪=文件加载了但没引导成功。

### 引导顺序（这就是"不用按 reset"的原因）

```
run soc_dtscheck; mx64init; run ubi_checkboot; run usb_checkboot; run tftp_checkboot; run meraki_checkboot
```

UBI → USB → TFTP 依次尝试，前一个失败才走下一个。完整命令清单见
[scripts/90-uboot-tftp.txt](scripts/90-uboot-tftp.txt)。

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
