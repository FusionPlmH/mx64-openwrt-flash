#!/bin/sh
# 在「过渡固件」（openwrt-bcm5862x-generic-meraki_mx64-initramfs-kernel.bin）启动后执行。
# 用途：把 512 KiB 的 small U-Boot 换成 1 MiB 布局的 uboot_mx64。
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

echo "== 写入 mtd0 =="
mtd write "$IMG" /dev/mtd0 || { echo "!! mtd write 失败"; exit 1; }
sync

echo "== 回读校验 =="
dd if=/dev/mtdblock0 bs=1024 count=64 2>/dev/null | md5sum
dd if="$IMG" bs=1024 count=64 2>/dev/null | md5sum
echo "   两行相同即写入成功"

echo
echo "== 完成：不要在这里重启就绪前拔电 =="
echo "   下一步直接做 sysupgrade（README 第 9 节），不要单独 reboot 去测 U-Boot"
