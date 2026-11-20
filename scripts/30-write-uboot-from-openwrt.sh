#!/bin/sh
# 在 OpenWrt 里把 U-Boot 写进 mtd0。
#
# 只在 mtd0 可写时才行。出厂固件带写保护的机器（cat /sys/block/mtdblock0/ro == 1）
# 进了 OpenWrt 之后 mtd0 依然是 read-only，两种写法都会失败：
#
#     dd: can't open '/dev/mtd0': Permission denied
#     dd: error writing '/dev/mtdblock0': Operation not permitted
#     mtd: Could not open mtd device: /dev/mtd0
#
# 这种机器只能让 U-Boot 自己刷自己 —— 见 README
# 「需要刷 mtd0 时：让 U-Boot 自己刷自己」。
#
# 用法（设备上，ssh root@192.168.1.1）：
#   sh 30-write-uboot-from-openwrt.sh              # 用过渡固件自带的 /root/uboot_mx64
#   sh 30-write-uboot-from-openwrt.sh /tmp/x.bin   # 用自己传上去的镜像（例如 uboot_ng.bin）
#
# 千万不要在 UBI 引导失败的时候反复刷 U-Boot。

IMG="${1:-/root/uboot_mx64}"

if [ ! -f "$IMG" ]; then
	echo "!! 找不到 $IMG"
	echo "   过渡固件里自带 /root/uboot_mx64；也可以先 scp 一个上去再传路径"
	exit 1
fi

size=$(wc -c < "$IMG")
echo "== 镜像 $IMG ($size 字节) =="
if [ "$size" -gt 1048576 ]; then
	echo "!! 超过 1 MiB，boot 分区放不下，停止"
	exit 1
fi

echo "== 当前分区表 =="
cat /proc/mtd

echo "== 探测 mtd0 可写性 =="
if ! dd if=/dev/zero of=/dev/mtd0 bs=1 count=0 2>/dev/null; then
	echo
	echo "!! mtd0 是只读的，没法从 OpenWrt 写入"
	echo
	echo "   这是出厂固件带写保护的机器。换 U-Boot 只能让 U-Boot 自己刷自己："
	echo "     1) PC 上生成带 flash_uboot 的 env: python tools/mkenv.py ..."
	echo "     2) 把它写进 mtd3 (u-boot-env)，TFTP 服务端跑着，然后断电重启"
	echo "     3) U-Boot 会自己 TFTP 拉镜像、校验、写 mtd0、回读 CRC"
	echo
	echo "   详见 README「需要刷 mtd0 时：让 U-Boot 自己刷自己」"
	exit 1
fi
echo "   mtd0 可写，继续"

echo "== 写入 mtd0 =="
# 有的 mtd 只认 /dev/mtd0，有的只认 label，两种都试
if mtd write "$IMG" /dev/mtd0 2>/dev/null; then
	echo "   写入完成 (mtd write /dev/mtd0)"
elif mtd write "$IMG" u-boot 2>/dev/null; then
	echo "   写入完成 (mtd write u-boot)"
else
	echo "!! mtd write 失败"
	exit 1
fi
sync

echo "== 回读校验 =="
dd if=/dev/mtd0 bs=1024 count=64 2>/dev/null | md5sum
dd if="$IMG" bs=1024 count=64 2>/dev/null | md5sum
echo "   两行相同即写入成功"

echo
echo "== 完成 =="
echo "   下一步直接做 sysupgrade（README 第 7 节），不要单独 reboot 去测 U-Boot"