#!/usr/bin/env python3
"""从 U-Boot 二进制里提取编译内置的默认环境，追加/覆盖指定变量，生成可直接
写到 u-boot-env 分区的 blob（带正确的 CRC32）。

用法:
    python tools/mkenv.py files/uboot_ng.bin files/uboot-env.bin config_dts=config@4

为什么需要这个:
    mtd0 被锁（或被 DTS 标成 read-only）时，进了 OpenWrt 就写不了 U-Boot。
    但 u-boot-env 分区通常可写，而 U-Boot 的大部分行为都来自环境变量 ——
    写环境就能达到"改 U-Boot 行为"的效果，且完全没有变砖风险：
    CRC 不对时 U-Boot 只会退回编译内置的默认环境。
"""

import struct
import sys
import zlib

ENV_SECTOR = 0x40000          # CONFIG_ENV_SIZE，也是擦除块大小
ENV_HEADER = 4                # env_t 里的 uint32 crc
ENV_DATA = ENV_SECTOR - ENV_HEADER


def extract_default_env(blob):
    """在二进制里找到 default_environment[] 并按 NUL 切开。

    U-Boot 把它拼成一段连续的 'key=value\\0' 字符数组，正好可以顺着扫。
    """
    anchor = b"bootargs="
    start = blob.find(anchor)
    if start < 0:
        raise SystemExit("找不到 bootargs=，这个二进制里没有默认环境吗？")

    entries = []
    pos = start
    while pos < len(blob):
        end = blob.find(b"\x00", pos)
        if end < 0:
            break
        raw = blob[pos:end]
        if not raw:
            break
        try:
            txt = raw.decode("ascii")
        except UnicodeDecodeError:
            break
        if "=" not in txt:
            break
        entries.append(txt)
        pos = end + 1
        if len(entries) > 200:
            break
    return entries


def build(entries, overrides):
    keys = {o.split("=", 1)[0] for o in overrides}
    entries = [e for e in entries if e.split("=", 1)[0] not in keys]
    data = b"".join(e.encode() + b"\x00" for e in overrides + entries) + b"\x00"
    if len(data) > ENV_DATA:
        raise SystemExit("环境变量太大: %d > %d" % (len(data), ENV_DATA))
    data = data.ljust(ENV_DATA, b"\x00")
    crc = zlib.crc32(data) & 0xFFFFFFFF
    return struct.pack("<I", crc) + data, crc


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)

    # 输出里带中文；Windows 控制台默认 cp1252 时 print 会抛 UnicodeEncodeError
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass

    src, dst = sys.argv[1], sys.argv[2]
    overrides = sys.argv[3:]

    blob = open(src, "rb").read()
    entries = extract_default_env(blob)
    out, crc = build(entries, overrides)

    with open(dst, "wb") as f:
        f.write(out)

    print("内置变量 %d 个，覆盖 %d 个" % (len(entries), len(overrides)))
    for o in overrides:
        print("  set %s" % o)
    print("写出 %s (%d 字节, crc=0x%08x)" % (dst, len(out), crc))


if __name__ == "__main__":
    main()
