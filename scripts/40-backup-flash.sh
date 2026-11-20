#!/bin/sh
# 在 OpenWrt 里执行（initramfs 或已装好的系统均可），备份原厂分区到 /tmp/backup。
#   cd /tmp && wget http://<PC_IP>/40-backup-flash.sh && sh 40-backup-flash.sh
# 然后用 PC 侧 scripts/03-fetch-backup.ps1 拉回来。

OUT=/tmp/backup
mkdir -p "$OUT"
cd "$OUT" || exit 1

echo "== 分区表 =="
cat /proc/mtd | tee proc-mtd.txt

echo "== UBI 卷信息 =="
ubinfo -a > ubinfo.txt 2>&1 || echo "   (ubinfo 不可用)"

# 前 5 个分区都很小（1 MiB / 512 KiB / 3 MiB），直接 dd 出镜像
for i in 0 1 2 3 4; do
	dev="/dev/mtdblock$i"
	[ -e "$dev" ] || continue
	name=$(awk -v n="mtd$i:" '$1==n {print $4}' /proc/mtd | tr -d '"')
	echo "== 备份 $dev (${name:-unknown}) =="
	dd if="$dev" of="mtd$i.bin" 2>/dev/null || { echo "   读取失败，跳过"; rm -f "mtd$i.bin"; continue; }
	gzip -9 "mtd$i.bin"
done

# board-config 卷是设备身份信息，绝对不要删，单独打包一份
echo "== 备份 board-config 卷 =="
# ubi 分区的 mtd 编号各家不同（clayface 布局是 mtd6），按名字找
UBI_MTD=$(awk '$4 ~ /"ubi"/ {sub(/mtd/,"",$1); sub(/:/,"",$1); print $1; exit}' /proc/mtd)
[ -n "$UBI_MTD" ] || UBI_MTD=6
echo "   ubi 在 mtd$UBI_MTD"
ubiattach -m "$UBI_MTD" 2>/dev/null
mkdir -p /mnt/bc
if mount -t ubifs ubi0:board-config /mnt/bc 2>/dev/null; then
	tar czf board-config.tar.gz -C /mnt/bc . 2>/dev/null
	umount /mnt/bc
	echo "   board-config.tar.gz 已生成"
else
	echo "   !! 挂载失败（卷名可能不同，看 ubinfo.txt）。没备份到 board-config 时不要删这个卷"
fi

echo
echo "== /tmp/backup 内容 =="
ls -l
echo
echo "== 下一步：PC 上执行 scripts/03-fetch-backup.ps1 拉回去 =="
