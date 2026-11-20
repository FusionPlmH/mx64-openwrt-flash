# Meraki MX64 / MX64W OpenWrt 刷机包

依据 <https://openwrt.org/toh/meraki/mx64> 整理，并把每一步做成了可复制的脚本。
**刷 U-Boot 有变砖风险**，动手前请先读完「0. 先决策」和「故障排查」。

本仓库: <https://github.com/FusionPlmH/mx64-openwrt-flash>
配套 U-Boot 源码: <https://github.com/FusionPlmH/mx64-uboot-refresh>

## 目录内容

```
README.md                    本文件
SHA256SUMS                   所有文件的校验值
files/                       设备要用的文件（拷到 U 盘根目录 / HTTP 服务器根目录）
  uboot_mx64                 1 MiB boot 分区用的 U-Boot（clayface，U-Boot 2012.10）
  uboot_mx64_small           512 KiB boot 分区用的 U-Boot（同上，裁剪版）
  uboot_ng.bin               本项目的 U-Boot（含 bootimg/TFTP/diagnostic 增强，596,492 B）
  mtd                        busybox mtd 工具（解锁写保护后写分区用）
  mtd-rw.ko                  mtd0 写保护解锁模块（仅 mtd0 只读时需要）
  openwrt-bcm5862x-generic-meraki_mx64-initramfs-kernel.bin    过渡固件 B0+
  openwrt-bcm5862x-generic-meraki_mx64a0-initramfs-kernel.bin  过渡固件 A0
  openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin            OpenWrt initramfs B0+
  openwrt-bcm53xx-generic-meraki_mx64-a0-initramfs.bin         OpenWrt initramfs A0
  openwrt-25.12.6-bcm53xx-generic-meraki_mx64-squashfs.sysupgrade.bin     B0+
  openwrt-25.12.6-bcm53xx-generic-meraki_mx64-a0-squashfs.sysupgrade.bin  A0
scripts/
  01-serve-http.ps1          PC 侧：起 HTTP 服务器（diagnostic mode 里 wget 用）
  02-copy-to-usb.ps1         PC 侧：把 files/ 拷到 U 盘并校验
  03-fetch-backup.ps1        PC 侧：把备份从设备拉回来
  10-device-check.sh         设备侧（diagnostic mode）：判断 A0/B0+、mtd0 大小、是否只读
  20-install-uboot.sh        设备侧（diagnostic mode）：写 U-Boot
  30-write-uboot-from-openwrt.sh  设备侧（过渡固件里）：换成 1 MiB 版 U-Boot
  40-backup-flash.sh         设备侧（OpenWrt 里）：备份原厂分区
  50-sysupgrade.sh           设备侧（OpenWrt 里）：sysupgrade
  60-reclaim-space.sh        设备侧（OpenWrt 里）：删掉原厂火山灰卷，扩 rootfs_data
```

镜像来源：
`uboot_mx64*`、`mtd`、`mtd-rw.ko`、`openwrt-bcm5862x-*`（过渡固件）来自
[clayface/U-boot-MX64-20190430_MX64](https://github.com/clayface/U-boot-MX64-20190430_MX64)；
`openwrt-bcm53xx-*-initramfs.bin` 来自 OpenWrt SNAPSHOT；
`openwrt-25.12.6-*.sysupgrade.bin` 来自 OpenWrt 25.12.6 正式版；
`uboot_ng.bin` 由本项目源码用 Bootlin `armv7-eabihf--glibc--stable`（GCC 5.4）编译。

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
2. 按住 reset 上电 → 白/橙交替快闪 → 松手，设备从 U 盘引导进过渡固件（OpenWrt）；
3. `ssh root@192.168.1.1`（无密码）；
4. 执行 `scripts/30-write-uboot-from-openwrt.sh`，它把过渡固件里自带的 `/root/uboot_mx64`
   写到 `mtd0`，把 boot 分区换成 1 MiB 版布局；
5. **不要重启**，直接做第 9 节 sysupgrade。
6. 换完 U-Boot 后第一次启动要重做 Shmoo 校准，会**很久**（几分钟）。橙白闪说明 UBI 引导失败：
   这时用 U 盘引导 initramfs 重装 OpenWrt，**不要再刷 U-Boot**。

## 7. 启动 OpenWrt initramfs

1. U 盘（根目录有 `openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin`）插好；
2. 上电，正常情况下会**白灯闪 3 下**然后从 U 盘引导（本项目 U-Boot 用 3 次白闪表示开始尝试）；
3. 灯常橙 → 引导中；之后绿闪（先快后慢）→ 绿色常亮 = 起来了，约 1 分钟；
4. 起不来就把文件删掉重拷一次，或换 U 盘 / 删掉 U 盘上其它分区。

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

`uboot_ng.bin` 是 `mx64-uboot-ng` 的构建产物（GCC 5.4，596,492 B），需要 **1 MiB** 的 boot 分区，
特性：

| 命令 | 作用 |
|---|---|
| `mx64init` | 初始化外设 + 读 reset 键（开机自动执行） |
| `usbload` | 从 U 盘 FAT 里按文件名列表尝试引导 |
| `bootimg <addr> [part]` | 按镜像头自动选择 `bootm`（FIT/uImage）或 `bootbk`（Meraki SPIM 过渡固件） |
| `tftp_boot` | TFTP 拉 initramfs 并 `bootimg`（`ipaddr=192.168.1.10`，`serverip=192.168.1.2`） |
| `bootbk <addr> <part>` | 启动 Meraki bootkernel（校验头部 CRC32） |
| `mx64info` | 打印版本、SoC、reset 状态、环境变量 |

LED：琥珀=电源常亮；白灯 3 次连闪=开始 USB 尝试，1 闪=没检测到 U 盘，2 闪=有盘但没找到/加载不了文件，
3 闪=文件加载了但没引导成功。

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
