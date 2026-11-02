#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vdev.py — 配置通道虚拟设备（按新协议）

在没有硬件时验证上位机（cfgctl.py / cfg_gui.py）的组帧、解析与匹配逻辑。

严格对齐 RTL 行为：
  * 校验顺序：OP → ITEM → SET → PORT → LEN → 读写权限，命中第一个错误即返回
  * SET 的 LEN 必须精确等于该 ITEM 值宽；GET 只查 LEN ≤ 16
  * 动作类 0x40~0x43 不校验 LEN
  * 只读项收到 SET → READ_ONLY(0x07)；只写项收到 GET → WRITE_ONLY(0x06)
  * 应答字段序：OP SEQ STATUS ITEM PORT SET LEN [VALUE]

用法：
    python vdev.py                        # 前台跑，监听 127.0.0.1:49374
    python vdev.py --port 49374 --shuffle # 顺带模拟应答乱序
    python vdev.py --bind 0.0.0.0         # 让同网段其它机器也能连
"""

from __future__ import annotations

import argparse
import ipaddress
import random
import socket
import sys
import threading
import time
from typing import Dict, List, Optional, Tuple

from cfgproto import (
    GEOMETRY_FIELDS, ITEMS, MAX_VALUE_BYTES, OP_GET, OP_SET, RSP_ERR,
    RSP_GET, RSP_SET, ST_BAD_ITEM, ST_BAD_LEN, ST_BAD_OP, ST_BAD_PORT,
    ST_BAD_SET, ST_OK, ST_READ_ONLY, ST_WRITE_ONLY, Item, item_by_code,
)

# ============================================================================
# 默认值（对齐 RTL cfg_map.vh）
#
# 存储一律小端：值 = 「按网络序读出的整数」，落到字节时反转。
#   192.168.1.100 → 0xC0A80164 → 字节 64 01 A8 C0
#   255.255.255.0 → 0xFFFFFF00 → 字节 00 FF FF FF
#
# ⚠ 例外：IP / MAC / IPv6 这几类在配置通道里是【网络序原样】进寄存器的
#   （cfg_cmd_rx: val_reg[val_index +: 8] <= active_data，第 0 字节进 bit[7:0]；
#    由 TB/Config/tb_cfg_byteorder.v 用真实 RTL 判定）。
#   所以它们的字节序与上面的通用规则相反 —— 见下方 IP/MAC 的注释。
# ============================================================================

def _ip(a: int) -> bytes:
    """IPv4：网络序字节（大端）。192.168.1.100 → C0 A8 01 64"""
    return a.to_bytes(4, "big")


def _mac(a: int) -> bytes:
    """MAC：线上字节序。00:19:31:00:00:01 → 00 19 31 00 00 01"""
    return a.to_bytes(6, "big")


def _ipv6(s: str) -> bytes:
    return ipaddress.IPv6Address(s).packed


def _range(lo: int, hi: int) -> bytes:
    """UDP 端口区间 {高16b, 低16b}：通用小端规则。"""
    return ((hi << 16) | lo).to_bytes(4, "little")


DEFAULTS: Dict[int, List[List[bytes]]] = {
    0x00: [[_ip(0xC0A80109)], [_ip(0xC0A80108)]],                       # IPv4 本机地址
    # MAC 取自 RTL cfg_map.vh：48'h010000_311900 = 00:19:31:00:00:01
    0x01: [[_mac(0x001931000001)], [_mac(0x001931000002)]],               # IPv4 MAC
    0x02: [[_ip(0xC0A80101)], [_ip(0xC0A80101)]],                       # 网关
    0x03: [[_ip(0xFFFFFF00)], [_ip(0xFFFFFF00)]],                       # 掩码 255.255.255.0
    0x04: [[_ipv6("fe80::1"), _ipv6("fe80::2")],
           [_ipv6("fe80::1"), _ipv6("fe80::2")]],                       # IPv6 本机
    0x05: [[_mac(0x001931000001), _mac(0x001931000001)],
           [_mac(0x001931000002), _mac(0x001931000002)]],               # IPv6 本机 MAC
    0x06: [[_ipv6("::"), _ipv6("::")], [_ipv6("::"), _ipv6("::")]],     # 邻居 IPv6
    0x07: [[_mac(0), _mac(0)], [_mac(0), _mac(0)]],                     # 邻居 MAC
    0x10: [[(0x88B5).to_bytes(2, "little"), (0x88CC).to_bytes(2, "little")],
           [(0x88B5).to_bytes(2, "little")]],                           # 以太类型
    0x11: [[bytes([0x01]), bytes([0x59]), bytes([0x06])],
           [bytes([0x06]), bytes([0x01]), bytes([0x59])]],              # IPv4 协议号
    0x12: [[bytes([0x11]), bytes([0x3A]), bytes([0x59])],
           [bytes([0x11]), bytes([0x59]), bytes([0x3A])]],              # IPv6 下一首部
    0x13: [[_range(0, 0), _range(1, 1), _range(2, 8)],
           [_range(2, 2), _range(4, 8)]],                               # UDP 端口区间
    0x30: [[(400_000_000).to_bytes(8, "little")], [(200_000_000).to_bytes(8, "little")]],
    0x31: [[bytes([15])], [bytes([15])]],                               # ARP 优先级
    0x32: [[bytes([12])], [bytes([12])]],                               # ICMP 优先级
    0x33: [[(0xC0DE).to_bytes(2, "little")], [(0xC0DE).to_bytes(2, "little")]],
    0x34: [[bytes([9])], [bytes([9])]],                                 # 命令应答优先级
}

# 每口每 item 的槽数（SET 维度上限）
SET_NUM: Dict[int, List[int]] = {
    0x00: [1, 1], 0x01: [1, 1], 0x02: [1, 1], 0x03: [1, 1],
    0x04: [2, 2], 0x05: [2, 2], 0x06: [2, 2], 0x07: [2, 2],
    0x10: [2, 1], 0x11: [3, 3], 0x12: [3, 3], 0x13: [3, 2],
}

GEOMETRY_BASE = [4, 57, 1, 3, 3, 2, 2, 2, 3]   # ARBITER_VAL_WIDTH / PENDING_TIME_WIDTH 等固定值
VERSION = 0x0001_0100


class VirtualDevice:
    """模拟一台双口 100G 设备。"""

    def __init__(self, bind: str = "127.0.0.1", port: int = 0xC0DE,
                 num_ports: int = 2, shuffle: bool = False, verbose: bool = False,
                 arp_stat: int = 0, icmp_stat: int = 0) -> None:
        self.bind = bind
        self.port = port
        self.num_ports = num_ports
        self.shuffle = shuffle
        self.verbose = verbose
        # 初始统计位（注入异常场景，便于验证上位机的位解释显示）
        self._init_arp_stat = arp_stat
        self._init_icmp_stat = icmp_stat

        self.store: Dict[Tuple[int, int, int], bytes] = {}
        # 统计位按口记录（真实硬件是每口一份）
        self.arp_stat: Dict[int, int] = {}
        self.icmp_stat: Dict[int, int] = {}
        self._sock: Optional[socket.socket] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self.rx_count = 0
        self.rx_bytes = 0
        self.reset_defaults()

    # ---------- 状态 ----------
    def reset_defaults(self) -> None:
        self.store.clear()
        for item, per_port in DEFAULTS.items():
            for p, slots in enumerate(per_port[:self.num_ports]):
                for s, val in enumerate(slots):
                    self.store[(item, p, s)] = bytes(val)
        self.arp_stat = {p: self._init_arp_stat for p in range(self.num_ports)}
        self.icmp_stat = {p: self._init_icmp_stat for p in range(self.num_ports)}
        if self.verbose:
            print(f"[vdev] 已装载默认值：{len(self.store)} 条")

    # ---------- 生命周期 ----------
    def start(self) -> "VirtualDevice":
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        # 刻意不设 SO_REUSEADDR：Windows 上它允许第二个进程绑定同一 UDP 端口，
        # 结果新旧实例同时存在、收包归属随机（调试时表现为「改了代码却没生效」）。
        # 宁可绑失败并明确报错，也不要静默抢包。
        try:
            s.bind((self.bind, self.port))
        except OSError as exc:
            s.close()
            raise OSError(
                f"虚拟设备无法绑定 {self.bind}:{self.port}（{exc}）。\n"
                "端口可能已被另一个虚拟设备占用，请换一个 --vdev-port。"
            ) from None
        s.settimeout(0.2)
        self._sock = s
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        print(f"[vdev] 监听 {self.bind}:{self.port}（{self.num_ports} 口）"
              + ("，应答乱序模拟已开启" if self.shuffle else ""))
        return self

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    def _run(self) -> None:
        assert self._sock is not None
        while not self._stop.is_set():
            try:
                data, addr = self._sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            self.rx_count += 1
            self.rx_bytes += len(data)
            if self.verbose:
                print(f"[vdev] ← {len(data)} B 来自 {addr}")
            try:
                out = self.handle(data)
            except Exception as exc:              # 虚拟设备不因畸形帧崩溃
                print(f"[vdev] 解析异常：{exc}", file=sys.stderr)
                continue
            if out:
                try:
                    self._sock.sendto(out, addr)
                except OSError:
                    pass

    # ---------- 协议处理 ----------
    def handle(self, data: bytes) -> bytes:
        """解析一帧（可含多根 TLV），返回合并后的应答字节流。"""
        rsps: List[bytes] = []
        i, n = 0, len(data)
        while i + 5 <= n:
            op = data[i]
            seq = data[i + 1]
            item = data[i + 2]
            port = data[i + 3] & 0x0F
            set_idx = (data[i + 3] >> 4) & 0x0F
            ln = data[i + 4]
            i += 5
            if i + ln > n:
                break
            value = data[i:i + ln]
            i += ln
            rsp = self._one(op, seq, item, port, set_idx, value)
            if rsp is not None:
                rsps.append(rsp)

        if self.shuffle and len(rsps) > 1:
            random.shuffle(rsps)
        return b"".join(rsps)

    def _one(self, op: int, seq: int, item: int, port: int,
             set_idx: int, value: bytes) -> Optional[bytes]:
        # ---- 1. OP ----
        if op not in (OP_SET, OP_GET):
            return self._err(seq, ST_BAD_OP, item, port, set_idx, len(value))

        # ---- 2. ITEM ----
        it = item_by_code(item)
        if it is None:
            return self._err(seq, ST_BAD_ITEM, item, port, set_idx, len(value))

        # ---- 3. SET 维度 ----
        if it.indexed:
            idx_port = port if port < self.num_ports else 0
            limit = SET_NUM.get(item, [1] * self.num_ports)[idx_port]
            if set_idx >= limit:
                return self._err(seq, ST_BAD_SET, item, port, set_idx, len(value))
        elif set_idx != 0:
            return self._err(seq, ST_BAD_SET, item, port, set_idx, len(value))

        # ---- 4. PORT ----
        if port >= self.num_ports:
            return self._err(seq, ST_BAD_PORT, item, port, set_idx, len(value))

        # ---- 5. LEN ----
        if it.is_action:
            pass                                  # 动作类不校验 LEN
        elif op == OP_SET:
            if len(value) != it.width:            # SET 必须精确等于值宽
                return self._err(seq, ST_BAD_LEN, item, port, set_idx, len(value))
        else:
            if len(value) > MAX_VALUE_BYTES:      # GET 只查上界
                return self._err(seq, ST_BAD_LEN, item, port, set_idx, len(value))

        # ---- 6. 读写权限 ----
        if op == OP_SET and it.mode == "r":
            return self._err(seq, ST_READ_ONLY, item, port, set_idx, len(value))
        if op == OP_GET and it.is_action:
            return self._err(seq, ST_WRITE_ONLY, item, port, set_idx, len(value))

        # ---- 执行 ----
        if op == OP_SET:
            return self._do_set(seq, it, port, set_idx, value)
        return self._do_get(seq, it, port, set_idx)

    # ---------- 执行 ----------
    def _do_set(self, seq: int, it: Item, port: int, set_idx: int, value: bytes) -> bytes:
        if it.code == 0x40:                       # RESET_DEF（全局）
            self.reset_defaults()
        elif it.code in (0x41, 0x42):             # CACHE_CLEAR / PEND_CLEAR
            pass
        elif it.code == 0x43:                     # STAT_CLEAR
            self.arp_stat[port] = 0
            self.icmp_stat[port] = 0
        else:
            self.store[(it.code, port, set_idx)] = bytes(value)
        if self.verbose:
            print(f"[vdev] SET {it.name} port={port} set={set_idx} "
                  f"val={value.hex() or '(空)'}")
        return self._rsp(RSP_SET, seq, ST_OK, it.code, port, set_idx, value)

    def _geometry(self, port: int, maximum: bool = False) -> List[int]:
        """
        按口生成 9 个 GEOMETRY 字段。

        字段顺序直接取 cfgproto.GEOMETRY_FIELDS（= VALUE 字节序），
        不在这里另写一份 —— 写错顺序会让上位机读到别的字段的档数。
        """
        def slot(item: int) -> int:
            v = SET_NUM.get(item, [1] * self.num_ports)
            if maximum:
                return max(v)
            return v[port] if port < len(v) else 1

        # ITEM → 它受哪个 GEOMETRY 字段约束
        item_of_field = {
            "LOCAL_IPV4_MAC_NUM": 0x00,
            "LOCAL_SRC_IPV6_MAC_NUM": 0x04,
            "LOCAL_DST_IPV6_MAC_NUM": 0x06,
            "MAC_RX_NUM": 0x10,
            "IPV4_RX_NUM": 0x11,
            "IPV6_RX_NUM": 0x12,
            "UDP_RX_PORT_NUM": 0x13,
        }
        out: List[int] = []
        for field in GEOMETRY_FIELDS:
            if field == "ARBITER_VAL_WIDTH":
                out.append(GEOMETRY_BASE[0])
            elif field == "PENDING_TIME_WIDTH":
                out.append(GEOMETRY_BASE[1])
            else:
                out.append(slot(item_of_field[field]))
        return out

    def _do_get(self, seq: int, it: Item, port: int, set_idx: int) -> bytes:
        if it.code == 0x51:
            val = VERSION.to_bytes(4, "little")
        elif it.code == 0x52:
            val = bytes([1])                      # 链路可用
        elif it.code == 0x53:
            val = bytes([1])                      # 空闲
        elif it.code == 0x54:
            val = bytes([0])                      # 源索引 0
        elif it.code == 0x55:
            val = bytes([1])                      # 不允许分片
        elif it.code == 0x60:
            val = self.arp_stat.get(port, 0).to_bytes(4, "little")
        elif it.code == 0x61:
            val = bytes([self.icmp_stat.get(port, 0) & 0xFF])
        elif it.code in (0x70, 0x71):
            val = bytes(self._geometry(port, maximum=(it.code == 0x71)))
        elif it.code == 0x72:
            val = bytes([self.num_ports])
        else:
            val = self.store.get((it.code, port, set_idx), bytes(it.width))
        if self.verbose:
            print(f"[vdev] GET {it.name} port={port} set={set_idx} -> {val.hex() or '(空)'}")
        return self._rsp(RSP_GET, seq, ST_OK, it.code, port, set_idx, val)

    # ---------- 组帧 ----------
    @staticmethod
    def _rsp(op: int, seq: int, status: int, item: int,
             port: int, set_idx: int, value: bytes) -> bytes:
        """应答头 6 字节：OP SEQ STATUS ITEM {SET,PORT} LEN，GET_RSP 再跟 VALUE。"""
        return bytes((
            op & 0xFF, seq & 0xFF, status & 0xFF, item & 0xFF,
            ((set_idx & 0x0F) << 4) | (port & 0x0F), len(value) & 0xFF,
        )) + value

    @staticmethod
    def _err(seq: int, status: int, item: int, port: int,
             set_idx: int, req_len: int) -> bytes:
        """ERR_RSP：6 字节，LEN 只是回显请求值，不带 VALUE。"""
        return bytes((
            RSP_ERR, seq & 0xFF, status & 0xFF, item & 0xFF,
            ((set_idx & 0x0F) << 4) | (port & 0x0F), req_len & 0xFF,
        ))


# ============================================================================
# 命令行入口
# ============================================================================

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Centenarian 配置通道虚拟设备")
    ap.add_argument("--bind", default="127.0.0.1", help="监听地址（默认 127.0.0.1）")
    ap.add_argument("--port", type=lambda s: int(s, 0), default=0xC0DE,
                    help="监听 UDP 端口（默认 0xC0DE = 49374）")
    ap.add_argument("--ports", type=int, default=2, help="模拟几个网口（默认 2）")
    ap.add_argument("--shuffle", action="store_true",
                    help="打乱同帧内多条应答顺序，验证上位机四元组匹配")
    ap.add_argument("--verbose", "-v", action="store_true", help="打印每根 TLV")
    ap.add_argument("--arp-stat", type=lambda s: int(s, 0), default=0,
                    help="初始 ARP_STAT 位图（注入异常场景，验证上位机的位解释显示）")
    ap.add_argument("--icmp-stat", type=lambda s: int(s, 0), default=0,
                    help="初始 ICMP_STAT 位图")
    args = ap.parse_args(argv)

    dev = VirtualDevice(args.bind, args.port, args.ports, args.shuffle, args.verbose,
                         arp_stat=args.arp_stat, icmp_stat=args.icmp_stat)
    dev.start()
    print("[vdev] Ctrl+C 退出")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print(f"\n[vdev] 收到 {dev.rx_count} 帧 / {dev.rx_bytes} B，退出")
    finally:
        dev.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
