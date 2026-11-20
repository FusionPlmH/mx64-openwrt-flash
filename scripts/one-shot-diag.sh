#!/bin/sh
# =============================================================================
#  MX64 诊断模式一键刷 U-Boot（在设备的 telnet shell 里跑）
#
#    sh one-shot-diag.sh                  # 默认：刷 uboot_ng.bin（本项目），TFTP 优先
#    sh one-shot-diag.sh --check          # 只看结论，不写任何东西
#    sh one-shot-diag.sh --clayface       # 改刷 clayface 的 uboot_mx64
#    sh one-shot-diag.sh tftp://192.168.1.2 http://192.168.1.2:8000
#
#  做的事：检测 -> (按需)解锁 -> 下载 -> 校验 -> 写 mtd0 -> 回读比对
#  只写 mtd0（boot 分区），不碰其它分区。
# =============================================================================

CHECK=0
USE_NG=1		# 1 = 默认刷 uboot_ng.bin, 2 = 明确指定 --ng, 0 = --clayface
POS=""
for a in "$@"; do
	case "$a" in
	--check|-n|--dry-run) CHECK=1 ;;
	--ng|--uboot-ng)      USE_NG=2 ;;
	--clayface|--stock)   USE_NG=0 ;;
	*)                    POS="$POS $a" ;;
	esac
done
# shellcheck disable=SC2086
set -- $POS

BASE1="${1:-tftp://192.168.1.2}"
BASE2="${2:-http://192.168.1.2:8000}"

SHA512_MX64=e642976560f5eea1ec52752305a8e54c082e028ee6d68276f6f2d4439e05db75002b68b6edea80ee23d52fd1e2802876d9e881352c5d7a1aa889b208472b1758
SHA512_SMALL=34cc5396899ce445e9d296fbe9a31b1abf0aa4424036a1ed977eaeb23726c2bed69cd91028318c14bdb8b48ee4d5861bcd0ae78509762d3d410303215cb0f47d
SHA512_NG=4a71afc6d8fdad14cc8a019656c35f33e90e7112d4a9b22cfa12f62b8ef0ca487bcaaf75b9db402c1490f893db167ef7103457ccb5f2154ae639f339316490f3
NG_SIZE=598172

die() { echo "!! $*"; exit 1; }
rule() { echo "--------------------------------------------------------------------"; }
ok()   { echo "   [ ok ] $*"; }
step() { echo "        $* ..."; }
note() { echo "          $*"; }

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
		note "来源 $b"
		if fetch_from "$b" "$1" "$2" && [ -s "$2" ]; then
			return 0
		fi
		note "  取不到，换下一个来源"
	done
	die "取不到 $1（$BASE1 和 $BASE2 都失败）"
}

# --------------------------------------------------------------- 1. 检测
echo
rule
echo " [1/6] 检测设备"
rule

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
	rev="读不到"
	VARIANT=unknown
fi

mtd0size=$(awk '/^mtd0:/ {print $2}' /proc/mtd)
ro=$(cat /sys/block/mtdblock0/ro 2>/dev/null)
[ -n "$mtd0size" ] || die "读不到 /proc/mtd 里的 mtd0，先手动确认（不要继续）"
mtd0dec=$((0x$mtd0size))

echo "   SoC        : $rev  ->  $VARIANT"
echo "   mtd0       : $mtd0size ($mtd0dec bytes)"
echo "   mtd0 RO    : ${ro:-?}"

# --------------------------------------------------------------- 2. 决策
if [ "$mtd0dec" -lt 1048576 ]; then
	if [ "$USE_NG" = "2" ]; then
		die "uboot_ng.bin 有 $NG_SIZE 字节，装不进 $mtd0size 的 boot 分区。这台机器只能先用 clayface 的 uboot_mx64_small（README 第 6 节）"
	fi
	TARGET=uboot_mx64_small; EXP_SHA512=$SHA512_SMALL; EXP_SIZE=524288
	echo "   ! 分区只有 $mtd0size，uboot_ng 装不下 -> 自动改用 uboot_mx64_small"
elif [ "$USE_NG" -ge 1 ]; then
	TARGET=uboot_ng.bin; EXP_SHA512=$SHA512_NG; EXP_SIZE=$NG_SIZE
else
	TARGET=uboot_mx64; EXP_SHA512=$SHA512_MX64; EXP_SIZE=587312
fi
NEED_UNLOCK=no
[ "$ro" = "1" ] && NEED_UNLOCK=yes

echo "   Target     : $TARGET ($EXP_SIZE bytes)"
if [ "$NEED_UNLOCK" = "yes" ]; then
	echo "   Unlock     : yes (mtd-rw.ko + mtd write)"
else
	echo "   Unlock     : no (dd)"
fi

# --------------------------------------------------------------- --check
if [ "$CHECK" = "1" ]; then
	echo
	rule
	echo " --check：只看结论，什么都没写"
	rule
	case "$VARIANT" in
	a0) echo "   initramfs : openwrt-bcm53xx-generic-meraki_mx64-a0-initramfs.bin" ;;
	b0) echo "   initramfs : openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin" ;;
	*)  echo "   initramfs : 读不到 SoC，靠标签确认 A0 / B0+" ;;
	esac
	if [ "$TARGET" = "uboot_mx64_small" ]; then
		echo "   Next      : 512 KiB 分区 -> 还要走 README 第 6 节（过渡固件换 1 MiB 布局）"
	elif [ "$TARGET" = "uboot_ng.bin" ]; then
		echo "   Next      : 重启后 U-Boot 自动 TFTP 拉 initramfs（第 7 节）"
		echo "               uboot_ng.bin 是本项目编的，功能多但没在真机上验证过"
	else
		echo "   Next      : 断电后引导 openwrt-bcm53xx-...-initramfs.bin（第 7 节）"
	fi
	echo
	note "去掉 --check 再跑一次就会真正写入"
	exit 0
fi

# --------------------------------------------------------------- 3. 下载
echo
rule
echo " [2/6] 下载 $TARGET"
rule
cd /tmp || die "进不去 /tmp"
rm -f "$TARGET"
fetch "$TARGET" "/tmp/$TARGET"
ok "已下载 $(wc -c < "/tmp/$TARGET") 字节"

# --------------------------------------------------------------- 4. 校验
echo
rule
echo " [3/6] 校验"
rule
size=$(wc -c < "/tmp/$TARGET")
echo "   长度 $size / 期望 $EXP_SIZE"
[ "$size" = "$EXP_SIZE" ] || die "长度不符，停止（文件没下全？）"
if command -v sha512sum >/dev/null 2>&1; then
	got=$(sha512sum "/tmp/$TARGET" | awk '{print $1}')
	if [ "$got" != "$EXP_SHA512" ]; then
		echo "   实际 $got"
		die "SHA512 不匹配，停止"
	fi
	ok "SHA512 正确"
else
	note "设备没有 sha512sum，只做了长度校验"
fi

# --------------------------------------------------------------- 5. 解锁
echo
rule
echo " [4/6] mtd0 写保护"
rule
if [ "$NEED_UNLOCK" = "yes" ]; then
	fetch mtd-rw.ko /tmp/mtd-rw.ko
	fetch mtd /tmp/mtd
	chmod +x /tmp/mtd
	step "insmod mtd-rw.ko i_want_a_brick=1"
	insmod /tmp/mtd-rw.ko i_want_a_brick=1
	dmesg | tail -3 | while read -r l; do note "$l"; done
	ro=$(cat /sys/block/mtdblock0/ro 2>/dev/null)
	[ "$ro" = "0" ] || die "解锁失败（mtd0 ro=$ro），不要继续。检查 dmesg 有没有 _mtd-rw: mtd0: setting writeable flag_"
	ok "已解锁（mtd0 ro=0）"
else
	ok "不需要解锁（mtd0 ro=${ro:-0}）"
fi

# --------------------------------------------------------------- 6. 写入
echo
rule
echo " [5/6] 写入 mtd0"
rule
if [ "$NEED_UNLOCK" = "yes" ]; then
	step "mtd write /tmp/$TARGET /dev/mtd0"
	/tmp/mtd write "/tmp/$TARGET" /dev/mtd0 || die "mtd write 失败"
else
	step "dd if=/tmp/$TARGET of=/dev/mtdblock0"
	dd if="/tmp/$TARGET" of=/dev/mtdblock0 2>/dev/null || die "dd 失败"
fi
sync
ok "写入完成"

# --------------------------------------------------------------- 7. 回读
echo
rule
echo " [6/6] 回读比对（前 64 KiB）"
rule
a=$(dd if=/dev/mtdblock0 bs=1024 count=64 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')
b=$(dd if="/tmp/$TARGET" bs=1024 count=64 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')
echo "   nand : ${a:-n/a}"
echo "   file : ${b:-n/a}"
if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]; then
	die "回读和文件不一致！不要断电，重新跑一次本脚本"
fi
ok "回读一致"

# --------------------------------------------------------------- 完成
echo
rule
echo " 完成"
rule
echo "   Target    : $TARGET"
case "$VARIANT" in
a0) echo "   initramfs : openwrt-bcm53xx-generic-meraki_mx64-a0-initramfs.bin" ;;
*)  echo "   initramfs : openwrt-bcm53xx-generic-meraki_mx64-initramfs.bin" ;;
esac
if [ "$TARGET" = "uboot_mx64_small" ]; then
	echo "   Next      : 断电 -> 过渡固件（README 第 6 节）"
elif [ "$TARGET" = "uboot_ng.bin" ]; then
	echo "   Next      : 重启后 U-Boot 自动 TFTP 拉 initramfs；之后可用 flash_uboot 升级（第 11 节）"
else
	echo "   Next      : 断电 -> 引导 initramfs（README 第 7 节）"
fi
rule
echo "==== 完成 ===="
