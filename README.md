# Meraki MX64 / MX64W OpenWrt 刷机包

按 <https://openwrt.org/toh/meraki/mx64> 整理的 PC 侧全自动刷机流程。判断、校验、比对都在 PC 上做，
设备只执行原始 shell 命令（`cat` / `wget` / `dd` …），不往设备里塞脚本——原厂 diagnostic mode 的
busybox 1.7.2 连 `sed` / `awk` 都没有。

- 本仓库：<https://github.com/FusionPlmH/mx64-openwrt-flash>
- 配套 U-Boot 源码：<https://github.com/FusionPlmH/mx64-uboot-refresh>

下文默认 **设备 `192.168.1.1`、PC `192.168.1.2`**，网线接设备的 LAN 口。

## 第一步：确认 mtd0 大小

关键只有一件：**`mtd0` 有多大**（`cat /proc/mtd`，一键脚本会自动读）。

| 你的 mtd0 | 刷的 U-Boot | 引导进 OpenWrt 用 |
|---|---|---|
| `00100000`（1 MiB，**大多数机器**） | `uboot_ng.bin`（本项目）或 `uboot_mx64`（clayface） | `openwrt-bcm53xx-generic-meraki_mx64[-a0]-initramfs.bin`（FIT，`bootm`） |
| `00080000`（512 KiB） | `uboot_mx64_small` | `openwrt-bcm5862x-generic-meraki_mx64[a0]-initramfs-kernel.bin`（SPIM，`bootbk`）——只用来换成 1 MiB 布局 |

两种 initramfs 是完全不同的容器，不是同一东西的两个版本：
FIT（首字节 `d0 0d fe ed`）是正常的 OpenWrt RAM 系统，之后 sysupgrade 进 NAND；
SPIM（`53 50 49 4d`）只有 512 KiB 老机器要，里面带 1 MiB 版 `uboot_mx64`。

A0 / B0+ 由脚本读 `devmem 0x18000000` 自动判断（`0x3F00`–`0x3F03` 为 A0），镜像选错内核起不来。

## 一键刷机

前置只有两条：

1. 设备进 diagnostic mode：按住 reset 上电 → 前灯橙色 → **白灯闪两下**时松手 → 等约 15 秒灯变绿（变彩虹色就断电重来）
2. PC 网卡与设备同网段（默认 `192.168.1.2/24`），网线插 LAN 口

```powershell
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -DryRun   # 只看计划
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -Check    # 只读设备、出结论，不写 NAND
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -Probe    # 只验证 mtd 工具，不擦不写
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1           # 真刷
```

脚本会自动完成：

1. 环境检查：python ≥ 3.7、`ssh`/`scp`、端口 8000/69 是否被占、`files/` 逐个 SHA256 校验
2. 起 HTTP（给 diag 下载）和 TFTP（给 U-Boot）两个服务
3. telnet 进 diag 刷 U-Boot：读 `mtd0`/写保护/SoC → 下载 → 校验长度和 md5 → 按需 `insmod mtd-rw.ko` → `mtd write` 或 `dd` → **整份镜像回读逐字节比对**
4. 提示拔电冷启动，等 22 端口打开（默认 900 秒）
5. 设备一上线就关掉 HTTP/TFTP，并打印 `Boot via` 说明这次走的是 U 盘还是 TFTP
6. `scp` 上传 sysupgrade → `ssh sysupgrade -n` → 等系统重启回来

`-ServerIp` 不指定时自动选本机 `192.168.1.x` 地址。网卡没有同网段地址时，按脚本提示用
`New-NetIPAddress` 加一个。

### 常用开关

| 开关 | 作用 |
|---|---|
| `-Check` / `-Probe` / `-DryRun` | 只出结论 / 只验证 `mtd` 工具 / 只打印计划 |
| `-SkipSysupgrade` | 进了 initramfs 就停，不装进 NAND |
| `-Uboot clayface` | 改刷 clayface 的 `uboot_mx64`（默认 `uboot_ng.bin`） |
| `-NoTftp` | 不起 TFTP，只留 U 盘一条路（UDP 69 被占用时） |
| `-WarmReboot` | 先试软重启（实测多半起不来），90 秒后仍提示拔电 |
| `-BootTimeoutSec <秒>` | 冷启动后等设备上线的超时，默认 900 |
| `-SysupgradeFile <路径>` | 指定 sysupgrade 镜像（默认按 A0/B0+ 自动挑最新的） |
| `-ServerIp` / `-DeviceIp` / `-Port` | PC 地址（自动探测）/ 设备地址 / HTTP 端口 `8000` |

### 必须拔电冷启动

写完 mtd0 再发 `reboot`，两台真机都回不来（常亮橙、网络全死）；拔电源冷启动约 77 秒进 initramfs。
只有第一次刷 U-Boot 需要按 reset 进 diag，之后都不用。

### U 盘（可选）

TFTP 覆盖同样的路径，**不插 U 盘也能起**；U-Boot 顺序是 UBI → USB → TFTP。要插就先准备：

- 单个分区、**FAT16/FAT32**（MBR），文件放**分区根目录**
- 文件名必须一字不差：B0+ 用 `openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin`，
  A0 用 `openwrt-bcm53xx-generic-meraki_mx64-a0-initramfs.bin`
- `powershell -File scripts\02-copy-to-usb.ps1 -Drive E:\` 会拷过去并校验

U-Boot 只 `fatload` + `bootm`，从不写 NAND；sysupgrade 放 U 盘上不会被自动安装。

## 手动刷机（脚本不适用时）

PC 上起服务（另开窗口别关）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\01-serve-http.ps1   # HTTP :8000
python scripts\70-tftp-server.py                                     # 可选，TFTP :69（Windows 不需要管理员）
```

设备 `telnet 192.168.1.1` 进去后：

```sh
cat /proc/mtd                      # mtd0 大小
cat /sys/block/mtdblock0/ro        # 1 = 有写保护
devmem 0x18000000                  # 0x3F00-0x3F03 = A0，否则 B0+

cd /tmp
rm -f uboot_ng.bin                 # 原厂 wget 不覆盖已有文件
wget http://192.168.1.2:8000/uboot_ng.bin

# 仅 ro=1 需要解锁
rm -f mtd-rw.ko mtd
wget http://192.168.1.2:8000/mtd-rw.ko
wget http://192.168.1.2:8000/mtd && chmod +x mtd
insmod mtd-rw.ko i_want_a_brick=1
cat /proc/modules | head -20      # 有 mtd_rw 这行就算成功（ro 仍是 1，正常）

./mtd write /tmp/uboot_ng.bin /dev/mtd0     # mtd 只认 /dev/mtd0 全路径
# 或 mtd0 本来可写时：dd if=/tmp/uboot_ng.bin of=/dev/mtdblock0

dd if=/dev/mtd0 bs=65536 skip=0 count=1 2>/dev/null    # skip=0..9，十块读回 PC 逐字节比对
sync
```

然后**拔电源**（不要 `reboot`）→ 插 U 盘或用 PC 上的 TFTP → 上电。

## 512 KiB 机器（过渡固件换成 1 MiB 布局）

1. 把 `openwrt-bcm5862x-generic-meraki_mx64-initramfs-kernel.bin`（A0 用 `..._mx64a0-...`）放进 U 盘或 TFTP 根目录
2. 按住 reset 上电，引导进过渡固件（`uboot_mx64_small` 是按键触发的）
3. `ssh root@192.168.1.1`，跑 `scripts/30-write-uboot-from-openwrt.sh`
   （会先探 mtd0 可写性；出厂带写保护的机器在 OpenWrt 下写不了，只能走「重新刷 U-Boot」那节）
4. **不要重启**，直接 sysupgrade

## sysupgrade 装进 NAND

自动流程第 6 阶段会做，手动时：

```powershell
scp -O files\openwrt-25.12.6-bcm53xx-generic-meraki_mx64-squashfs.sysupgrade.bin root@192.168.1.1:/tmp/
```

```sh
ssh root@192.168.1.1
sysupgrade -n /tmp/openwrt-25.12.6-bcm53xx-generic-meraki_mx64-squashfs.sysupgrade.bin
```

装完地址是 `192.168.1.1`，`root` 无密码，**立刻设密码**。

## 可选步骤

**备份原厂分区**：只能在 initramfs 里做（diag 没有 `scp`）。引导 initramfs 后跑 `scripts/40-backup-flash.sh`，
再用 `powershell -File scripts\03-fetch-backup.ps1` 拉回 PC。自动流程默认跳过备份。

**释放原厂占用的 flash**（装完只有 ~370 MiB 可用时）：

```sh
wget http://192.168.1.2:8000/60-reclaim-space.sh && sh 60-reclaim-space.sh
```

删掉 `part.old` / `storage` / `diagnostic1` / `part.safe`（**不要动 `board-config`**），再跑一次 sysupgrade，
`rootfs_data` 会扩到剩余全部空间。

## 进了 OpenWrt 之后重新刷 U-Boot

OpenWrt 下 mtd0 是 DTS 只读的，diag 也没了。让 U-Boot 自己刷自己：

```powershell
python tools\mkenv.py files\uboot_ng.bin files\uboot-env-flash.bin `
    config_dts=config@4 ipaddr=192.168.1.10 serverip=192.168.1.2 `
    "bootcmd=run soc_dtscheck; mx64init; flash_uboot uboot_ng.bin 100000 confirm; run ubi_checkboot; run usb_checkboot; run tftp_checkboot; run meraki_checkboot"
scp -O files\uboot-env-flash.bin root@192.168.1.1:/tmp/
```

```sh
mtd erase u-boot-env                              # 必须先擦再写
dd if=/tmp/uboot-env-flash.bin of=/dev/mtd3 bs=4096
sync
```

让 `python scripts\70-tftp-server.py` 跑着、`uboot_ng.bin` 放在服务目录里，然后断电重启。
U-Boot 会 TFTP 取镜像 → 校验 → 擦写 mtd0 → 回读 CRC；任一步不满足就打印
`TFTP failed, nothing was written` 跳过，不会留下半写的 mtd0。

刷完把 `bootcmd` 改回默认（去掉 `flash_uboot`），否则每次开机都会重刷。
其他环境变量（`ipaddr` / `serverip` / `config_dts`）同样用 `tools\mkenv.py` 生成后写 mtd3，
`files/uboot-env.bin` 就是默认那份。`mtd` 工具只认 label（`u-boot-env`），传 `mtd3` 会报错。

## 确认设备现在处于哪一步

```sh
cat /proc/cmdline             # root=/dev/ubiblock0_0 = 已装进 NAND；/dev/ram0 = 还在 RAM
df -h /overlay                # 有 /overlay 且几百 MB = sysupgrade 过了
ubinfo -a                     # 有 rootfs_data 卷 = 已装好
```

## 故障排查

| 现象 | 处理 |
|---|---|
| `192.168.1.1:23` 连不上 | 没进 diag（正常启动时 LAN 是 `192.168.0.1`）；网线插 LAN1-4 不是 WAN；进 diag 要 20~30 秒 |
| 白灯闪两下后一直橙 | diag Linux 没起来，断电重试 2-3 次；仍不行接串口 J1（115200 8N1） |
| `wget` 404 | HTTP 服务目录不对，或文件名打错 |
| `wget: can't open 'xxx': File exists` | 原厂 `wget` 不覆盖，先 `rm -f` 再下 |
| `mtd-rw.ko` insmod 报错 | 内核不匹配，看 dmesg 的 vermagic / 符号版本 |
| insmod 报 `File exists` | 之前已加载，**不是失败**；看 `/proc/modules` 有没有 `mtd_rw` |
| 解锁后 `ro` 还是 1 | **正常**。判据是 `/proc/modules` 有 `mtd_rw` 或 dmesg 有 `setting writeable flag` |
| `Could not open mtd device: mtd0` | `mtd` 只认 `/dev/mtd0` 全路径，不认 `mtd0` 或 label |
| 回读和镜像不一致 | **不要断电重启**，重跑脚本再写一次 |
| 写完 mtd0 设备不回来 | 别用 `reboot`，拔电源冷启动 + 插 U 盘 |
| TFTP 有请求但没 `done` | 传输中断：查防火墙（公用网络会拦）、丢包、网线；重试即可，NAND 没被动过 |
| 插了 U 盘白灯一次都不闪 | U-Boot 没走到 `usb_boot`：确认 FAT16/FAT32 单分区、文件名一字不差，换个 U 盘；仍不行接串口 |
| 白灯闪三下后又常亮橙 | `fatload` 成功但 `bootm` 失败——文件名对、内容不对（比如放成了 sysupgrade） |
| 装完只有 ~370 MiB 可用 | 见「释放原厂占用的 flash」 |
| 进了系统却反复掉回 USB/TFTP | `config_dts` 选错（A0/B0+ 镜像不匹配），重刷对应的 sysupgrade |
| 首次冷启动 U 盘能起、TFTP 完全没动静 | 先在 U-Boot 里 `printenv enable_tftp_boot`，缺了就 `setenv enable_tftp_boot 1; saveenv` |

## 目录内容

```
files/                    刷机用到的全部文件（SHA256SUMS 逐个校验）
  uboot_ng.bin            本项目 U-Boot v6（598,488 B，需 1 MiB 分区）
  uboot_mx64               clayface U-Boot（587,312 B，1 MiB 分区）
  uboot_mx64_small         clayface U-Boot（524,288 B，512 KiB 分区）
  uboot-env.bin            默认 U-Boot 环境变量块（config_dts=config@4）
  mtd-rw.ko                mtd0 写保护解锁（只对原厂 2.6.36 内核有效）
  mtd                      busybox mtd 工具（解锁后用 mtd write）
  *-initramfs.bin          FIT RAM 系统（B0+ / A0）
  *-initramfs-kernel.bin   SPIM 过渡固件（只有 512 KiB 机器要）
  *-sysupgrade.bin         装进 NAND 的系统（B0+ / A0）
scripts/
  00-flash.ps1             一键刷机（PC 驱动 telnet，全自动）
  01-serve-http.ps1        只起 HTTP 服务
  70-tftp-server.py        只读 TFTP 服务器（给 U-Boot 用）
  02-copy-to-usb.ps1       拷 files/ 到 U 盘并校验
  03-fetch-backup.ps1      把设备 /tmp/backup 拉回 PC
  30-write-uboot-from-openwrt.sh  512 KiB → 1 MiB 布局切换
  40-backup-flash.sh       OpenWrt 里备份原厂分区（可选）
  50-sysupgrade.sh         OpenWrt 里执行 sysupgrade
  60-reclaim-space.sh      删原厂 UBI 卷，扩 rootfs_data
  90-uboot-tftp.txt        U-Boot 提示符下的命令清单
tools/mkenv.py             生成带正确 CRC 的 U-Boot 环境变量块
```

`backup/` 是本机的设备备份，不要一起分发（`.gitignore` 已忽略）。

## 参考

- OpenWrt wiki: <https://openwrt.org/toh/meraki/mx64>
- clayface U-Boot: <https://github.com/clayface/U-Boot-MX64-20190430_MX64>
- OpenWrt PR #16634: <https://github.com/openwrt/openwrt/pull/16634>
