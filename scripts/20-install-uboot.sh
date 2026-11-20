# 在 MX64 diagnostic mode 里执行：
#   cd /tmp && wget http://192.168.1.2:8000/20-install-uboot.sh
#   sh 20-install-uboot.sh http://192.168.1.2:8000
# 先跑过 10-device-check.sh（结论在 /tmp/mx64-check.env）

BASE="${1:-http://192.168.1.2}"
ENVFILE=/tmp/mx64-check.env

SHA512_MX64=e642976560f5eea1ec52752305a8e54c082e028ee6d68276f6f2d4439e05db75002b68b6edea80ee23d52fd1e2802876d9e881352c5d7a1aa889b208472b1758
SHA512_SMALL=34cc5396899ce445e9d296fbe9a31b1abf0aa4424036a1ed977eaeb23726c2bed69cd91028318c14bdb8b48ee4d5861bcd0ae78509762d3d410303215cb0f47d

if [ ! -f "$ENVFILE" ]; then
	echo "!! 先运行 10-device-check.sh"
	exit 1
fi
. "$ENVFILE"

case "$TARGET" in
uboot_mx64)       EXP_SHA512="$SHA512_MX64";  EXP_SIZE=587312 ;;
uboot_mx64_small) EXP_SHA512="$SHA512_SMALL"; EXP_SIZE=524288 ;;
*) echo "!! 未知 TARGET=$TARGET"; exit 1 ;;
esac

echo "== 目标: $TARGET (NEED_UNLOCK=$NEED_UNLOCK) =="
cd /tmp || exit 1
rm -f "$TARGET"

echo "== 下载 =="
wget "$BASE/$TARGET" -O "/tmp/$TARGET" || { echo "!! 下载失败"; exit 1; }

size=$(wc -c < "/tmp/$TARGET")
echo "   大小 $size (期望 $EXP_SIZE)"
if [ "$size" != "$EXP_SIZE" ]; then
	echo "!! 大小不符，停止"
	exit 1
fi

echo "== 校验 SHA512 =="
if command -v sha512sum >/dev/null 2>&1; then
	got=$(sha512sum "/tmp/$TARGET" | awk '{print $1}')
	echo "   $got"
	if [ "$got" != "$EXP_SHA512" ]; then
		echo "!! SHA512 不匹配，停止"
		exit 1
	fi
	echo "   SHA512 正确"
else
	echo "   !! 设备上没有 sha512sum，只做了长度校验"
	echo "   !! 可以在 PC 上先比对: certutil -hashfile uboot_mx64 SHA512"
fi

if [ "$NEED_UNLOCK" = "yes" ]; then
	echo "== 解锁 mtd0 =="
	wget "$BASE/mtd-rw.ko" -O /tmp/mtd-rw.ko || { echo "!! 下载 mtd-rw.ko 失败"; exit 1; }
	wget "$BASE/mtd" -O /tmp/mtd || { echo "!! 下载 mtd 失败"; exit 1; }
	chmod +x /tmp/mtd
	insmod /tmp/mtd-rw.ko i_want_a_brick=1 || echo "   (insmod 返回非 0，检查下面的 dmesg)"
	dmesg | tail -5
	echo "   上面应出现: _mtd-rw: mtd0: setting writeable flag_"
	echo "   没有出现就不要继续，Ctrl-C 退出"
	sleep 5
fi

echo "== 写入 =="
if [ "$NEED_UNLOCK" = "yes" ]; then
	/tmp/mtd write "/tmp/$TARGET" /dev/mtd0 || { echo "!! mtd write 失败"; exit 1; }
else
	dd if="/tmp/$TARGET" of=/dev/mtdblock0 || { echo "!! dd 失败"; exit 1; }
fi
sync

echo "== 回读前 64 KiB 比对 =="
dd if=/dev/mtdblock0 bs=1024 count=64 2>/dev/null | md5sum 2>/dev/null
dd if="/tmp/$TARGET" bs=1024 count=64 2>/dev/null | md5sum 2>/dev/null
echo "   两行相同即可（设备没有 md5sum 就跳过）"

echo
echo "== 完成：断电，然后按 README 第 6/7 节继续 =="
if [ "$TARGET" = "uboot_mx64_small" ]; then
	echo "   刷的是 small 版 -> 必须先用 U 盘过渡固件，再在 OpenWrt 里写 uboot_mx64（第 6 节）"
fi
