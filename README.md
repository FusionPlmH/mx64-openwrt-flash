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

本工具只覆盖 **mtd0 = 1 MiB** 的机器；`00080000`（512 KiB）的机器不在支持范围内，
脚本会在检测到它时直接停下。

引导用的 initramfs 是 FIT 容器（首字节 `d0 0d fe ed`），就是正常的 OpenWrt RAM 系统，之后 sysupgrade 进 NAND。

A0 / B0+ 由脚本读 `devmem 0x18000000` 自动判断（`0x3F00`–`0x3F03` 为 A0），镜像选错内核起不来。

## 一键刷机

前置只有两条：

1. 设备进 diagnostic mode：按住 reset 上电 → 前灯橙色 → **白灯闪两下**时松手 → 等约 15 秒灯变绿（变彩虹色就断电重来）
2. PC 网卡与设备同网段（默认 `192.168.1.2/24`），网线插 LAN 口

```powershell
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -DryRun   # 只看计划，不碰设备
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1 -Check    # 只读体检：环境 + 设备探测 + mtd 工具验证，不写 NAND
powershell -ExecutionPolicy Bypass -File scripts\00-flash.ps1           # 真刷
```

脚本会自动完成：

1. 环境检查：python ≥ 3.7、`ssh`/`scp`、端口 8000/69 是否被占、`files/` 逐个 SHA256 校验
2. 起 HTTP（给 diag 下载）和 TFTP（给 U-Boot）两个服务
3. telnet 进 diag 刷 U-Boot：读 `mtd0`/写保护/SoC → 下载 → 校验长度和 md5 → 按需 `insmod mtd-rw.ko` → `mtd write` 或 `dd` → **整份镜像回读逐字节比对**
4. 提示拔电冷启动，等 22 端口打开（默认 900 秒）
5. 设备一上线就关掉 HTTP/TFTP，并打印 `Boot via` 说明这次走的是 U 盘还是 TFTP
6. `scp` 上传 sysupgrade → `ssh sysupgrade -n` → 等系统重启回来

设备地址固定 `192.168.1.1`，PC 地址默认自动选本机 `192.168.1.x`。网卡没有同网段地址时，按脚本提示用
`New-NetIPAddress` 加一个。

### 常用开关

| 开关 | 作用 |
|---|---|
| `-Check` | 只读体检：环境检查 + 设备探测 + `mtd` 工具验证（含 `unlock` 参数），不写 NAND |
| `-DryRun` | 只打印计划，不碰设备 |
| `-SkipSysupgrade` | 进了 initramfs 就停，不装进 NAND |
| `-Uboot clayface` | 改刷 clayface 的 `uboot_mx64`（默认 `uboot_ng.bin`） |
| `-NoTftp` | 不起 TFTP，只留 U 盘一条路（UDP 69 被占用时） |
| `-WarmReboot` | 先试软重启（实测多半起不来），90 秒后仍提示拔电 |

### 必须拔电冷启动

写完 mtd0 再发 `reboot`，两台真机都回不来（常亮橙、网络全死）；拔电源冷启动约 77 秒进 initramfs。
只有第一次刷 U-Boot 需要按 reset 进 diag，之后都不用。

### U 盘（可选）

TFTP 覆盖同样的路径，**不插 U 盘也能起**；U-Boot 顺序是 UBI → USB → TFTP。要插就先准备：

- 单个分区、**FAT16/FAT32**（MBR），文件放**分区根目录**
- 文件名必须一字不差：B0+ 用 `openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin`，
  A0 用 `openwrt-bcm53xx-generic-meraki_mx64-a0-initramfs.bin`
- 把 `files\` 里对应的那个文件**手动拷到 U 盘根目录**（约 6 MB，其他文件不用拷，改名就找不到）

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

OpenWrt 下 mtd0 是 DTS 只读的，diag 也没了，只能让 U-Boot 自己刷自己。一条命令搞定：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\05-reflash-uboot.ps1
powershell -ExecutionPolicy Bypass -File scripts\05-reflash-uboot.ps1 -UbootFile files\uboot_mx64   # 换镜像
powershell -ExecutionPolicy Bypass -File scripts\05-reflash-uboot.ps1 -DryRun                        # 只看计划
```

脚本做的事：

1. `mkenv.py` 生成一份把 `flash_uboot` 塞进 `bootcmd` 的环境变量块，`scp` 上去写进 `mtd3`（`u-boot-env`）
2. 起 TFTP（`70-tftp-server.py`），提示你拔电再上电
3. U-Boot 自己取镜像 → 校验 → 擦写 mtd0 → 回读 CRC，然后继续正常启动
4. 设备回来后核对 mtd0 前 N 字节的 md5，确认真的写进去了
5. 把 `bootcmd` 恢复成默认再写一次 mtd3 —— 不会每次开机都重刷

任一步不满足，U-Boot 会打印 `TFTP failed, nothing was written` 跳过，不会留下半写的 mtd0。

<details>
<summary>不用脚本时的手动做法</summary>

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

让 `python scripts\70-tftp-server.py` 跑着、`uboot_ng.bin` 放在服务目录里，断电重启。
刷完用 `mkenv.py` 不带 `bootcmd=` 再生成一份（或直接用 `files\uboot-env.bin`）写回 mtd3，
否则每次开机都会重刷。`mtd` 工具只认 label（`u-boot-env`），传 `mtd3` 会报错。

</details>

## 目录内容

```
files/                    刷机用到的全部文件（SHA256SUMS 逐个校验）
  uboot_ng.bin            本项目 U-Boot v6（598,488 B，需 1 MiB 分区）
  uboot_mx64               clayface U-Boot（587,312 B，1 MiB 分区）
  uboot-env.bin            默认 U-Boot 环境变量块（config_dts=config@4）
  mtd-rw.ko                mtd0 写保护解锁（只对原厂 2.6.36 内核有效）
  mtd                      busybox mtd 工具（解锁后用 mtd write）
  *-initramfs.bin          FIT RAM 系统（B0+ / A0）
  *-sysupgrade.bin         装进 NAND 的系统（B0+ / A0）
scripts/
  00-flash.ps1             一键刷机（PC 驱动 telnet，全自动）
  01-serve-http.ps1        只起 HTTP 服务
  70-tftp-server.py        只读 TFTP 服务器（给 U-Boot 用）
  03-fetch-backup.ps1      把设备 /tmp/backup 拉回 PC
  05-reflash-uboot.ps1     OpenWrt 里重新刷 U-Boot（TFTP + flash_uboot）
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
