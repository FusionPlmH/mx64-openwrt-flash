#!/bin/sh
# MX64 一键脚本：在 diagnostic mode 的 telnet shell 里跑，自动完成
#   检测 SoC/分区 → (按需解锁 mtd0) → 下载 → 校验 → 写入 → 回读比对
#
# 用法（默认 TFTP，取不到自动回退 HTTP）:
#   cd /tmp && wget http://192.168.1.2:8000/one-shot-diag.sh
#   sh one-shot-diag.sh
#
#   也可以显式指定来源（第一个参数优先，第二个是备用）:
#   sh one-shot-diag.sh tftp://192.168.1.2 http://192.168.1.2:8000
#   sh one-shot-diag.sh http://192.168.1.2:8000
#
# 刷完断电，然后按 README 第 7 节引导 initramfs。
# 只写 mtd0（boot 分区），不碰其它分区。

BASE1="${1:-tftp://192.168.1.2}"
BASE2="${2:-http://192.168.1.2:8000}"

SHA512_MX64=e642976560f5eea1ec52752305a8e54c082e028ee6d68276f6f2d4439e05db75002b68b6edea80ee23d52fd1e2802876d9e881352c5d7a1aa889b208472b1758
SHA512_SMALL=34cc5396899ce445e9d296fbe9a31b1abf0aa4424036a1ed977eaeb23726c2bed69cd91028318c14bdb8b48ee4d5861bcd0ae78509762d3d410303215cb0f47d

die() { echo "!! $*"; exit 1; }

fetch_from() {	# $1 = base, $2 = 远端文件名, $3 = 本地路径；成功返回 0
	case "$1" in
	tftp://*)
		host=${1#tftp://}
		host=${host%%/*}
		command -v tftp >/dev/null 2>&1 || return 3
		rm -f "$3"
		tftp -g -l "$3" -r "$2" "$host"
		;;
	http://*)
		command -v wget >/dev/null 2>&1 || return 3
		wget "$1/$2" -O "$3"
		;;
	*)	return 3 ;;
	esac
}

fetch() {	# $1 = 远端文件名, $2 = 本地路径；按 BASE1 -> BASE2 顺序试
	for b in "$BASE1" "$BASE2"; do
		[ -n "$b" ] || continue
		echo "   取 $1 自 $b"
		if fetch_from "$b" "$1" "$2" && [ -s "$2" ]; then
			return 0
		fi
		echo "   失败，换下一个来源"
	done
	die "取不到 $1（$BASE1 和 $BASE2 都失败）"
}

echo "==== 1/6 检测设备 ===="
raw=""
if command -v devmem >/dev/null 2>&1; then
	raw=$(devmem 0x18000000 2>/dev/null)
elif command -v devmem2 >/dev/null 2>&1; then
	raw=$(devmem2 0x18000000 2>/dev/null | awk '{print $NF}')
fi
if [ -n "$raw" ]; then
	rev=$(echo "$raw" | sed -n 's/.*\(0x[0-9A-Fa-f]*\).*/\1/p')
	case "$rev" in
	0x3F00*|0x3F01*|0x3F02*|0x3F03*) VARIANT=a0 ;;
	*) VARIANT=b0 ;;
	esac
else
	rev="unknown"
	VARIANT=unknown
fi
mtd0size=$(awk '/^mtd0:/ {print $2}' /proc/mtd)
ro=$(cat /sys/block/mtdblock0/ro 2>/dev/null)
[ -n "$mtd0size" ] || die "读不到 /proc/mtd 里的 mtd0，先手动确认（不要继续）"
mtd0dec=$((0x$mtd0size))
echo "   chip 0x18000000 = $rev -> ${VARIANT}"
echo "   mtd0 size       = $mtd0size ($mtd0dec bytes)"
echo "   mtd0 read-only  = ${ro:-unknown}"

if [ "$mtd0dec" -ge 1048576 ]; then
	TARGET=uboot_mx64; EXP_SHA512=$SHA512_MX64; EXP_SIZE=587312
else
	TARGET=uboot_mx64_small; EXP_SHA512=$SHA512_SMALL; EXP_SIZE=524288
fi
NEED_UNLOCK=no
[ "$ro" = "1" ] && NEED_UNLOCK=yes
echo "   决定: TARGET=$TARGET NEED_UNLOCK=$NEED_UNLOCK"

echo "==== 2/6 下载 $TARGET ===="
cd /tmp || die "进不去 /tmp"
rm -f "$TARGET"

fetch "$TARGET" "/tmp/$TARGET"

echo "==== 3/6 校验 ===="
size=$(wc -c < "/tmp/$TARGET")
echo "   大小 $size (期望 $EXP_SIZE)"
[ "$size" = "$EXP_SIZE" ] || die "大小不对，停止（文件可能没下全）"
if command -v sha512sum >/dev/null 2>&1; then
	got=$(sha512sum "/tmp/$TARGET" | awk '{print $1}')
	[ "$got" = "$EXP_SHA512" ] || die "SHA512 不匹配，停止"
	echo "   SHA512 正确"
else
	echo "   (设备没有 sha512sum，只做了长度校验)"
fi

if [ "$NEED_UNLOCK" = "yes" ]; then
	echo "==== 4/6 解锁 mtd0 ===="
	fetch mtd-rw.ko /tmp/mtd-rw.ko
	fetch mtd /tmp/mtd
	chmod +x /tmp/mtd
	insmod /tmp/mtd-rw.ko i_want_a_brick=1
	dmesg | tail -3
	ro=$(cat /sys/block/mtdblock0/ro 2>/dev/null)
	if [ "$ro" != "0" ]; then
		die "解锁失败（mtd0 ro=$ro），不要继续。检查 dmesg 里有没有 _mtd-rw: mtd0: setting writeable flag_"
	fi
	echo "   mtd0 ro=0，已解锁"
else
	echo "==== 4/6 不需要解锁 ===="
fi

echo "==== 5/6 写入 mtd0 ===="
if [ "$NEED_UNLOCK" = "yes" ]; then
	/tmp/mtd write "/tmp/$TARGET" /dev/mtd0 || die "mtd write 失败"
else
	dd if="/tmp/$TARGET" of=/dev/mtdblock0 || die "dd 失败"
fi
sync

echo "==== 6/6 回读比对前 64 KiB ===="
a=$(dd if=/dev/mtdblock0 bs=1024 count=64 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')
b=$(dd if="/tmp/$TARGET" bs=1024 count=64 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')
echo "   nand: ${a:-n/a}"
echo "   file: ${b:-n/a}"
if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]; then
	die "回读和文件不一致！不要断电，重新跑一次本脚本"
fi

echo
echo "==== 完成 ===="
echo "现在断电。下一步（不按 reset，见 README 第 7 节）:"
case "$VARIANT" in
a0) echo "  initramfs 文件名: openwrt-bcm53xx-generic-meraki_mx64-a0-initramfs.bin" ;;
*)  echo "  initramfs 文件名: openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin" ;;
esac
[ "$TARGET" = "uboot_mx64_small" ] && echo "  刷的是 small 版 -> 先走过渡固件（README 第 6 节）"
