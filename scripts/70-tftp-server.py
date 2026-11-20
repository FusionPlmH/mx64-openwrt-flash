#!/usr/bin/env python3
"""极简 TFTP 服务器（只支持 RRQ 下载），给 U-Boot 的 tftpboot / flash_uboot 用。

    python 70-tftp-server.py                    # 服务 ../files，UDP 69
    python 70-tftp-server.py --dir files --port 6969

U-Boot 的 tftpboot 默认连 UDP 69：
    Windows: 绑定低端口不需要管理员
    Linux/macOS: 绑定 69 需要 root（sudo）

只想本地测试时可以 --port 6969，但 U-Boot 那边要显式改端口才能连。

实现 RFC1350 octet 模式，512 字节块，不协商选项（U-Boot 未设 tftpblocksize 时
也不会请求选项）。不做上传。
"""

import argparse
import os
import socket
import struct
import sys
import threading

OP_RRQ = 1
OP_WRQ = 2
OP_DATA = 3
OP_ACK = 4
OP_ERROR = 5
OP_OACK = 6

ERR_ACCESS = 2
ERR_NOT_FOUND = 1
ERR_ILLEGAL = 4

BLOCK = 512
MAX_BLOCK = 1468          # U-Boot 默认请求 1468
TIMEOUT = 3.0
RETRIES = 15


def log(msg):
    print(msg, flush=True)


def send_error(sock, peer, code, text):
    sock.sendto(struct.pack("!HH", OP_ERROR, code) + text.encode() + b"\0", peer)


def serve_file(root, filename, peer, opts=None):
    path = os.path.normpath(os.path.join(root, filename.lstrip("/").lstrip("\\")))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("", 0))
    s.settimeout(TIMEOUT)

    try:
        if not path.startswith(root) or not os.path.isfile(path):
            send_error(s, peer, ERR_NOT_FOUND, "file not found")
            log("  %-52s NOT FOUND" % filename)
            return

        with open(path, "rb") as f:
            payload = f.read()

        # 协商选项：U-Boot 的 tftpboot 默认会请求 blksize/tsize，应答 OACK
        # 后就能用大块传输，块数降到 1/3，丢包时也更容易恢复。
        block_size = BLOCK
        oack = []
        opts = opts or {}
        if "blksize" in opts:
            try:
                block_size = int(opts["blksize"])
            except ValueError:
                block_size = BLOCK
            block_size = max(8, min(block_size, MAX_BLOCK))
            oack.append(("blksize", str(block_size)))
        if "tsize" in opts:
            oack.append(("tsize", str(len(payload))))
        if "timeout" in opts:
            oack.append(("timeout", opts["timeout"]))

        total = (len(payload) + block_size - 1) // block_size or 1
        log("  %-52s -> %s (%d bytes, blksize=%d, %d blocks)"
            % (filename, peer[0], len(payload), block_size, total))

        if oack:
            pkt = struct.pack("!H", OP_OACK) + b"".join(
                ("%s\0%s\0" % kv).encode() for kv in oack)
            acked = False
            for _ in range(3):
                s.sendto(pkt, peer)
                try:
                    resp, _ = s.recvfrom(1024)
                except socket.timeout:
                    continue
                if (len(resp) >= 4
                        and struct.unpack("!H", resp[:2])[0] == OP_ACK
                        and struct.unpack("!H", resp[2:4])[0] == 0):
                    acked = True
                    break
            if not acked:
                # 有些 U-Boot 不应答 OACK；退回到不协商的 512 字节传输，
                # 直接开始发 DATA 块 1
                log("  %-52s no ACK for OACK -> falling back to 512-byte blocks"
                    % filename)
                block_size = BLOCK
                total = (len(payload) + block_size - 1) // block_size or 1

        block = 1
        offset = 0
        misses = 0

        while True:
            chunk = payload[offset:offset + block_size]
            s.sendto(struct.pack("!HH", OP_DATA, block & 0xFFFF) + chunk, peer)

            while True:
                try:
                    resp, _ = s.recvfrom(1024)
                except socket.timeout:
                    misses += 1
                    if misses > RETRIES:
                        log("  %-52s timeout at block %d/%d (%d bytes sent), giving up"
                            % (filename, block, total, offset))
                        return
                    break  # 重发同一个块

                if len(resp) < 4:
                    continue
                op = struct.unpack("!H", resp[:2])[0]
                if op == OP_ERROR:
                    log("  %-52s peer aborted at block %d" % (filename, block))
                    return
                if op != OP_ACK:
                    continue
                if struct.unpack("!H", resp[2:4])[0] == (block & 0xFFFF):
                    offset += len(chunk)
                    block += 1
                    misses = 0
                    if len(chunk) < block_size:
                        log("  %-52s done" % filename)
                        return
                    break
    finally:
        s.close()


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="minimal read-only TFTP server")
    ap.add_argument("--dir", default=os.path.join(here, "..", "files"))
    ap.add_argument("--port", type=int, default=69)
    ap.add_argument("--bind", default="0.0.0.0")
    args = ap.parse_args()

    root = os.path.abspath(args.dir)
    if not os.path.isdir(root):
        sys.exit("no such directory: %s" % root)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind((args.bind, args.port))
    except PermissionError:
        sys.exit("binding UDP %d needs administrator/root" % args.port)
    except OSError as e:
        sys.exit("cannot bind UDP %d: %s" % (args.port, e))

    log("TFTP serving %s on %s:%d" % (root, args.bind, args.port))
    log("Ctrl-C to stop")

    while True:
        data, peer = sock.recvfrom(2048)
        if len(data) < 4:
            continue
        op = struct.unpack("!H", data[:2])[0]
        if op == OP_WRQ:
            send_error(sock, peer, ERR_ACCESS, "read only")
            continue
        if op != OP_RRQ:
            send_error(sock, peer, ERR_ILLEGAL, "only RRQ")
            continue
        parts = data[2:].split(b"\0")
        name = parts[0].decode(errors="replace")
        opts = {}
        # parts[1] 是 mode；之后是 name/value 成对出现
        for i in range(2, len(parts) - 1, 2):
            if not parts[i]:
                break
            opts[parts[i].decode(errors="replace").lower()] = \
                parts[i + 1].decode(errors="replace")
        threading.Thread(target=serve_file, args=(root, name, peer, opts),
                         daemon=True).start()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
