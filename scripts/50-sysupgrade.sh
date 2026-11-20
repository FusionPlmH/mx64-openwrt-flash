#!/bin/sh
# 在 OpenWrt 里执行 sysupgrade。
#   cd /tmp && wget http://<PC_IP>/50-sysupgrade.sh
#   sh 50-sysupgrade.sh /tmp/openwrt-<版本>-bcm53xx-generic-meraki_mx64-squashfs.sysupgrade.bin
#
# -n 表示不保留旧配置（全新安装）。想保留就把它去掉。

IMG="$1"
if [ -z "$IMG" ]; then
	echo "用法: sh 50-sysupgrade.sh /tmp/openwrt-...sysupgrade.bin"
	exit 1
fi
if [ ! -f "$IMG" ]; then
	echo "!! 找不到 $IMG（先用 scp 传到 /tmp）"
	exit 1
fi

size=$(wc -c < "$IMG")
echo "== 镜像 $IMG ($size 字节) =="
if [ "$size" -lt 1000000 ]; then
	echo "!! 文件太小，像是没传完整，停止"
	exit 1
fi

echo "== 当前分区表 =="
cat /proc/mtd

echo "== 开始 sysupgrade -n =="
echo "   完成后设备会自动重启，SSH 会断开"
sysupgrade -n "$IMG"
