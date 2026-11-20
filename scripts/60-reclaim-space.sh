#!/bin/sh
# 在 OpenWrt 里执行，删掉原厂留下的无用 UBI 卷，把空间还给 rootfs_data。
#   cd /tmp && wget http://<PC_IP>/60-reclaim-space.sh && sh 60-reclaim-space.sh
#
# 删完要再跑一次 sysupgrade（同一个镜像），OpenWrt 才会扩建 rootfs_data。
# 绝对不要删 board-config。

echo "== 删除前 =="
ubinfo -a

for v in part.old storage diagnostic1 part.safe; do
	if ubirmvol /dev/ubi0 -N "$v" 2>/dev/null; then
		echo "   已删除卷 $v"
	else
		echo "   跳过 $v（不存在或未挂载）"
	fi
done

echo
echo "== 删除后 =="
ubinfo -a

echo
echo "board-config 必须还在。确认无误后执行:"
echo "  sysupgrade -n /tmp/openwrt-...-squashfs.sysupgrade.bin"
echo "重启后 rootfs_data 会自动占满剩余空间，用 df -h 复查"
