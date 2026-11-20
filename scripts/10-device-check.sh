# 在 MX64 diagnostic mode 里执行（telnet 192.168.1.1 之后 sh 10-device-check.sh）
# 判断 SoC 版本 / mtd0 大小 / mtd0 是否只读，并把结论写到 /tmp/mx64-check.env

ENVFILE=/tmp/mx64-check.env

echo "== 1. SoC revision =="
raw=""
if command -v devmem >/dev/null 2>&1; then
	raw=$(devmem 0x18000000 2>/dev/null)
elif command -v devmem2 >/dev/null 2>&1; then
	raw=$(devmem2 0x18000000 2>/dev/null | awk '{print $NF}')
fi

if [ -z "$raw" ]; then
	echo "   !! devmem/devmem2 都没有，无法判断 SoC 版本"
	echo "   !! 只能靠标签/出厂时间猜：2022 年前的机器多为 A0"
	VARIANT=unknown
else
	# 0x3F00..0x3F03 => A0，其余 => B0+
	rev="$(echo "$raw" | sed -n 's/.*\(0x[0-9A-Fa-f]*\).*/\1/p')"
	case "$rev" in
	0x3F00*|0x3F01*|0x3F02*|0x3F03*) VARIANT=a0 ;;
	*) VARIANT=b0 ;;
	esac
	echo "   0x18000000 = $rev -> $([ "$VARIANT" = a0 ] && echo 'A0（用 -a0- 镜像）' || echo 'B0+（用常规镜像）')"
fi

echo "== 2. mtd0 大小 =="
mtd0size=$(awk '/^mtd0:/ {print $2}' /proc/mtd)
echo "   /proc/mtd mtd0 size = $mtd0size"
case "$mtd0size" in
00080000) TARGET=uboot_mx64_small; echo "   512 KiB -> 只能先刷 uboot_mx64_small（见 README 第 6 节）" ;;
*)        TARGET=uboot_mx64;       echo "   >= 1 MiB -> 直接刷 uboot_mx64" ;;
esac

echo "== 3. mtd0 是否只读 =="
ro=$(cat /sys/block/mtdblock0/ro 2>/dev/null)
echo "   /sys/block/mtdblock0/ro = ${ro:-unknown}"
if [ "$ro" = "1" ]; then
	NEED_UNLOCK=yes
	echo "   被锁 -> 需要 mtd-rw.ko + mtd"
else
	NEED_UNLOCK=no
fi

cat > "$ENVFILE" <<EOF
VARIANT=$VARIANT
TARGET=$TARGET
NEED_UNLOCK=$NEED_UNLOCK
EOF

echo
echo "== 结论 =="
echo "VARIANT=$VARIANT TARGET=$TARGET NEED_UNLOCK=$NEED_UNLOCK"
echo "已写入 $ENVFILE"
case "$VARIANT" in
a0) echo "initramfs : openwrt-bcm53xx-generic-meraki_mx64-a0-initramfs.bin" ;;
b0) echo "initramfs : openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin" ;;
esac
