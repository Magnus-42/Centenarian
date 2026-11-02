#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cfgproto.py — Centenarian 配置命令通道协议核心库

纯 Python 标准库实现，Windows / Linux 通用，无需安装任何依赖。

协议依据：Docs/05-config-command.md + RTL/Config/*.v（代码为唯一依据）

────────────────────────────────────────────────────────────────────────────
帧格式（注意请求与应答的字节布局【不对称】，这是最容易写错的地方）
────────────────────────────────────────────────────────────────────────────

请求 TLV（来自 cfg_cmd_rx.v 状态机 S_OP→S_SEQ→S_ITEM→S_PORT→S_LEN→S_VAL）:

    byte0 = OP
    byte1 = SEQ
    byte2 = ITEM
    byte3 = (SET << 4) | PORT        ← SET 和 PORT 挤在同一个字节里
    byte4 = LEN
    byte5.. = VALUE（小端，LEN 字节）

应答头固定 6 字节（cfg_get.v:162 / cfg_error.v:76 的位域拼装，err_axis_mkeep=6'b111111）:

    byte0 = OP
    byte1 = SEQ
    byte2 = STATUS
    byte3 = ITEM
    byte4 = (SET << 4) | PORT
    byte5 = LEN                       ← SET_RSP / ERR_RSP 只是回显，不跟 VALUE
    byte6.. = VALUE（仅 GET_RSP 有）

    cfg_get  : {pad, rd_val, rd_len, rd_set, rd_port, rd_item, status, seq, op}
    cfg_error: {pad, err_len, err_set, err_port, err_item, err_status, err_seq, op}

────────────────────────────────────────────────────────────────────────────
其它关键约定
────────────────────────────────────────────────────────────────────────────
  * 一帧 = 若干根 TLV 首尾相连，没有独立帧头；每根自带 OP 和 SEQ
  * 应答顺序不保证与请求一致（三路经 3 口轮询合并），必须按
    (SEQ, ITEM, SET, PORT) 四元组匹配
  * 应答回到请求帧的源 IP / 源端口 → 必须同一 socket 收发
  * 准入：请求的目的 IP 必须等于绑定网口 set0 的本机 IP，否则静默丢弃
  * VALUE 内部一律小端；TLV 各字段（OP/SEQ/TAG/LEN）按字节顺序直排
"""

from __future__ import annotations

import ipaddress
import socket
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple

__all__ = [
    # 常量
    "OP_SET", "OP_GET", "RSP_SET", "RSP_GET", "RSP_ERR",
    "MAX_VALUE_BYTES", "DEFAULT_UDP_PORT",
    "STATUS_NAME", "Item", "ITEMS", "item_by_code", "item_by_name",
    # 分组与编辑器类型（前端渲染用）
    "GROUP_ADDR", "GROUP_ROUTE", "GROUP_BEHAVIOR", "GROUP_STATUS",
    "GROUP_STAT", "GROUP_BOUND", "GROUP_ORDER", "GROUP_LABEL",
    "ED_IPV4", "ED_MAC", "ED_IPV6", "ED_HEX8", "ED_HEX16", "ED_NUM",
    "ED_RANGE", "ED_PRIO", "ED_PORT", "ED_CYCLES", "ED_VERSION",
    "ED_LINK", "ED_TXIDLE", "ED_TXACTIVE", "ED_DF", "ED_STAT",
    "ED_GEO", "ED_COUNT", "ED_NONE",
    # 数据结构
    "Tlv", "Rsp",
    # 编解码
    "encode_tlv", "encode_frame", "parse_rsps",
    "fmt_value", "parse_value", "match_key",
    # 语义化辅助
    "slots_for", "to_edit_text", "bit_labels_for", "item_meta",
    "GeomField", "GEOMETRY_SEMANTICS", "geometry_semantics", "stat_bits_meta",
    "TX_ACTIVE_LANES", "tx_active_lane", "tx_lane_meta",
    "READONLY_HINTS", "readonly_hints",
    # 客户端
    "CfgError", "CfgTimeout", "CfgClient",
]

# ============================================================================
# 1. 协议常量
# ============================================================================

OP_SET = 0x01          # 写配置 / 触发动作
OP_GET = 0x02          # 读配置 / 读状态

RSP_SET = 0x81         # SET 成功
RSP_GET = 0x82         # GET 成功
RSP_ERR = 0x8F         # 请求被拒绝

MAX_VALUE_BYTES = 16   # 单根 TLV 的 VALUE 上限
DEFAULT_UDP_PORT = 0xC0DE

ST_OK = 0x00
ST_BAD_OP = 0x01
ST_BAD_ITEM = 0x02
ST_BAD_SET = 0x03
ST_BAD_PORT = 0x04
ST_BAD_LEN = 0x05
ST_WRITE_ONLY = 0x06   # 对只写项发 GET
ST_READ_ONLY = 0x07    # 对只读项发 SET

STATUS_NAME: Dict[int, str] = {
    ST_OK: "OK",
    ST_BAD_OP: "BAD_OP",
    ST_BAD_ITEM: "BAD_ITEM",
    ST_BAD_SET: "BAD_SET",
    ST_BAD_PORT: "BAD_PORT",
    ST_BAD_LEN: "BAD_LEN",
    ST_WRITE_ONLY: "WRITE_ONLY",
    ST_READ_ONLY: "READ_ONLY",
}

# ============================================================================
# 2. ITEM 表
# ============================================================================

# ---- 分组（前端页签）----
GROUP_ADDR = "addr"          # 地址
GROUP_ROUTE = "route"        # 分流规则
GROUP_BEHAVIOR = "behavior"  # 行为参数
GROUP_STATUS = "status"      # 运行状态
GROUP_STAT = "stat"          # 锁存统计
GROUP_BOUND = "bound"        # 配置边界

GROUP_ORDER = [GROUP_ADDR, GROUP_ROUTE, GROUP_BEHAVIOR,
               GROUP_STATUS, GROUP_STAT, GROUP_BOUND]

GROUP_LABEL = {
    GROUP_ADDR: "地址",
    GROUP_ROUTE: "分流",
    GROUP_BEHAVIOR: "行为",
    GROUP_STATUS: "状态",
    GROUP_STAT: "统计",
    GROUP_BOUND: "边界",
}

# ---- 编辑器类型（前端决定用哪种输入控件）----
ED_IPV4 = "ipv4"        # IPv4 地址
ED_MAC = "mac"          # MAC 地址
ED_IPV6 = "ipv6"        # IPv6 地址
ED_HEX8 = "hex8"        # 1 字节十六进制
ED_HEX16 = "hex16"      # 2 字节十六进制
ED_NUM = "num"          # 无符号整数
ED_RANGE = "range"      # 端口区间 low-high
ED_PRIO = "prio"        # 优先级 0..15（0=禁用）
ED_PORT = "port"        # UDP 端口号
ED_CYCLES = "cycles"    # 用户时钟周期数
ED_VERSION = "version"
ED_LINK = "link"        # 链路状态
ED_TXIDLE = "txidle"
ED_TXACTIVE = "txactive"
ED_DF = "df"
ED_STAT = "stat"        # 位域统计
ED_GEO = "geo"          # 几何向量
ED_COUNT = "count"
ED_NONE = "none"        # 只读展示


@dataclass(frozen=True)
class Item:
    """一条配置项的静态描述。"""
    code: int
    name: str
    width: int          # VALUE 字节数
    mode: str           # 'rw' 可读写 / 'w' 只写(动作) / 'r' 只读
    indexed: bool       # 是否有 SET 档维度
    per_port: bool      # 是否每口一份（False = 全局）
    desc: str = ""
    group: str = ""     # 所属分组（GROUP_*）
    editor: str = ED_NONE  # 前端编辑器类型

    @property
    def is_action(self) -> bool:
        return self.mode == "w"


ITEMS: Dict[int, Item] = {}


def _reg(code: int, name: str, width: int, mode: str,
         indexed: bool = False, per_port: bool = True, desc: str = "",
         group: str = "", editor: str = ED_NONE) -> None:
    ITEMS[code] = Item(code, name, width, mode, indexed, per_port, desc,
                       group, editor)


# ---- 地址类（RW，带 SET 维度，每口一份）----
_reg(0x00, "IPV4_LOCAL_IP",  4, "rw", indexed=True, group=GROUP_ADDR,
     editor=ED_IPV4, desc="本机 IPv4 地址")
_reg(0x01, "IPV4_LOCAL_MAC", 6, "rw", indexed=True, group=GROUP_ADDR,
     editor=ED_MAC, desc="本机 MAC")
_reg(0x02, "IPV4_GATEWAY",   4, "rw", indexed=True, group=GROUP_ADDR,
     editor=ED_IPV4, desc="网关")
_reg(0x03, "IPV4_MASK",      4, "rw", indexed=True, group=GROUP_ADDR,
     editor=ED_IPV4, desc="子网掩码")
_reg(0x04, "IPV6_SRC_LOCAL", 16, "rw", indexed=True, group=GROUP_ADDR,
     editor=ED_IPV6, desc="本机 IPv6 地址")
_reg(0x05, "IPV6_SRC_MAC",   6, "rw", indexed=True, group=GROUP_ADDR,
     editor=ED_MAC, desc="本机 IPv6 对应 MAC")
_reg(0x06, "IPV6_DST_LOCAL", 16, "rw", indexed=True, group=GROUP_ADDR,
     editor=ED_IPV6, desc="邻居 IPv6 地址")
_reg(0x07, "IPV6_DST_MAC",   6, "rw", indexed=True, group=GROUP_ADDR,
     editor=ED_MAC, desc="邻居 IPv6 对应 MAC")

# ---- 分流规则（RW，带 SET 维度）----
_reg(0x10, "ETH_TYPE_DICT",   2, "rw", indexed=True, group=GROUP_ROUTE,
     editor=ED_HEX16, desc="用户自定义以太类型")
_reg(0x11, "IPV4_PROTO_DICT", 1, "rw", indexed=True, group=GROUP_ROUTE,
     editor=ED_HEX8, desc="IPv4 协议号")
_reg(0x12, "IPV6_NH_DICT",    1, "rw", indexed=True, group=GROUP_ROUTE,
     editor=ED_HEX8, desc="IPv6 下一首部号")
_reg(0x13, "UDP_PORT_RANGE",  4, "rw", indexed=True, group=GROUP_ROUTE,
     editor=ED_RANGE, desc="UDP 目的端口区间 {高16b,低16b}")

# ---- 行为参数（RW，每口一份，无 SET 维度）----
_reg(0x30, "PENDING_TIME", 8, "rw", group=GROUP_BEHAVIOR, editor=ED_CYCLES,
     desc="ARP 等待超时，低 57 位有效，单位=用户时钟周期")
_reg(0x31, "ARP_PRIO",     1, "rw", group=GROUP_BEHAVIOR, editor=ED_PRIO,
     desc="ARP 帧发送优先级，低 4 位；0=禁用")
_reg(0x32, "ICMP_PRIO",    1, "rw", group=GROUP_BEHAVIOR, editor=ED_PRIO,
     desc="ICMPv4 echo 应答优先级，低 4 位；0=禁用")
_reg(0x33, "CMD_UDP_PORT", 2, "rw", group=GROUP_BEHAVIOR, editor=ED_PORT,
     desc="命令通道自身 UDP 端口（数值）")
_reg(0x34, "CMD_UDP_PRIO", 1, "rw", group=GROUP_BEHAVIOR, editor=ED_PRIO,
     desc="命令应答发送优先级，低 4 位；0=禁用")

# ---- 动作（W，LEN=0）----
_reg(0x40, "RESET_DEF",   0, "w", per_port=False, group="action",
     desc="恢复全部默认值（全局）")
_reg(0x41, "CACHE_CLEAR", 0, "w", group="action", desc="清 ARP 缓存表")
_reg(0x42, "PEND_CLEAR",  0, "w", group="action", desc="清 ARP 等待队列")
_reg(0x43, "STAT_CLEAR",  0, "w", group="action", desc="清锁存统计")

# ---- 状态（R）----
_reg(0x51, "VERSION",     4, "r", per_port=False, group=GROUP_STATUS,
     editor=ED_VERSION, desc="0x00010100 = {主,次,构建,协议}")
_reg(0x52, "LINK_STATUS", 1, "r", group=GROUP_STATUS, editor=ED_LINK,
     desc="bit0=1 链路可用")
_reg(0x53, "TX_IDLE",     1, "r", group=GROUP_STATUS, editor=ED_TXIDLE,
     desc="bit0=1 该口发送侧空闲")
_reg(0x54, "TX_ACTIVE",   1, "r", group=GROUP_STATUS, editor=ED_TXACTIVE,
     desc="低 TX_IDX_WIDTH 位 = 当前服务的发送源索引")
_reg(0x55, "IS_DF",       1, "r", group=GROUP_STATUS, editor=ED_DF,
     desc="bit0=1 该口 IPv4 不允许分片")

# ---- 统计（R，sticky）----
_reg(0x60, "ARP_STAT",  4, "r", group=GROUP_STAT, editor=ED_STAT,
     desc="低 7 位锁存状态")
_reg(0x61, "ICMP_STAT", 1, "r", group=GROUP_STAT, editor=ED_STAT,
     desc="低 4 位锁存状态")

# ---- 配置边界（R）----
# per_port 的判据 = RTL 读出时是否用 rd_port 索引：
#   0x70 GEOMETRY     用 rd_port 索引 *_ARR ⇒ 每口一份 ⇒ per_port=True
#   0x71 GEOMETRY_MAX 直接返回全局 *_MAX 常量，【不看 rd_port】⇒ 全局 ⇒ per_port=False
#   0x72 PORT_NUM     直接返回 ETH_PORT_NUM，【不看 rd_port】⇒ 全局 ⇒ per_port=False
_reg(0x70, "GEOMETRY",     9, "r", group=GROUP_BOUND, editor=ED_GEO,
     desc="本口档数/套数/位宽")
_reg(0x71, "GEOMETRY_MAX", 9, "r", per_port=False, group=GROUP_BOUND,
     editor=ED_GEO, desc="全局上限（所有口共用，不随 PORT 变化）")
_reg(0x72, "PORT_NUM",     1, "r", per_port=False, group=GROUP_BOUND,
     editor=ED_COUNT, desc="低 4 位 = 网口数")

# 已删除但保留说明，命中时回 BAD_ITEM
_REMOVED = {0x56: "MIN_FRAME（已删除）", 0x62: "RX 错误计数（已删除）",
            0x63: "RX 错误计数（已删除）"}


def item_by_code(code: int) -> Optional[Item]:
    return ITEMS.get(code & 0xFF)


def item_by_name(name: str) -> Optional[Item]:
    key = name.strip().upper()
    for it in ITEMS.values():
        if it.name == key:
            return it
    return None


# ---- 语义化名称表 ----
#: GEOMETRY 的 9 个字段，**按 VALUE 字节序排列**（字节 0 → 字节 8）。
#:
#: RTL `cfg_reg_bank.v` 的拼接是「高位 → 低位」：
#:   {UDP_RX_PORT_NUM, IPV6_RX_NUM, IPV4_RX_NUM, MAC_RX_NUM,
#!    LOCAL_DST_IPV6_MAC_NUM, LOCAL_SRC_IPV6_MAC_NUM, LOCAL_IPV4_MAC_NUM,
#!    PENDING_TIME_WIDTH, ARBITER_VAL_WIDTH}
#: 而 VALUE 按【小端】进寄存器（cfg_cmd_rx.v: `val_reg[val_index +: 8] <= active_data`，
#: 第 0 字节进 bit[7:0]），所以【字节 0 = 拼接的最低位】= ARBITER_VAL_WIDTH。
#:
#: ⚠ 顺序写错会导致档数推导取到别的字段的值 ⇒ 多读超限的档 ⇒ 设备回 BAD_SET。
#:   2026-10-29 曾因此把口 1 的 MAC_RX_NUM(=1) 读成 IPV6_RX_NUM(=3)，
#!   多读 2 档；全量读从 72 项变 73 项、7 项被设备拒绝。
GEOMETRY_FIELDS = [
    # 字节 0    1         2                  3                  4                  5         6         7         8
    "ARBITER_VAL_WIDTH", "PENDING_TIME_WIDTH", "LOCAL_IPV4_MAC_NUM",
    "LOCAL_SRC_IPV6_MAC_NUM", "LOCAL_DST_IPV6_MAC_NUM", "MAC_RX_NUM",
    "IPV4_RX_NUM", "IPV6_RX_NUM", "UDP_RX_PORT_NUM",
]

#: 每个 ITEM 的档数由 GEOMETRY 的哪个字段决定（None = 不带 SET 维度）
#: 与 RTL cfg_reg_bank.v 的 `rd_idx_v4 / rd_idx_v6s / rd_idx_v6d /
#: rd_idx_eth / rd_idx_v4p / rd_idx_v6nh / rd_idx_udp` 选路一一对应。
SLOT_FIELD: Dict[int, str] = {
    0x00: "LOCAL_IPV4_MAC_NUM",    # IPV4_LOCAL_IP
    0x01: "LOCAL_IPV4_MAC_NUM",    # IPV4_LOCAL_MAC
    0x02: "LOCAL_IPV4_MAC_NUM",    # IPV4_GATEWAY
    0x03: "LOCAL_IPV4_MAC_NUM",    # IPV4_MASK
    0x04: "LOCAL_SRC_IPV6_MAC_NUM",  # IPV6_SRC_LOCAL
    0x05: "LOCAL_SRC_IPV6_MAC_NUM",  # IPV6_SRC_MAC
    0x06: "LOCAL_DST_IPV6_MAC_NUM",  # IPV6_DST_LOCAL
    0x07: "LOCAL_DST_IPV6_MAC_NUM",  # IPV6_DST_MAC
    0x10: "MAC_RX_NUM",            # ETH_TYPE_DICT
    0x11: "IPV4_RX_NUM",           # IPV4_PROTO_DICT
    0x12: "IPV6_RX_NUM",           # IPV6_NH_DICT
    0x13: "UDP_RX_PORT_NUM",       # UDP_PORT_RANGE
}

@dataclass(frozen=True)
class StatBit:
    """一个统计位的完整语义。"""
    bit: int
    short: str                    # 短名（界面上一行能读完）
    desc: str                     # 详细说明
    src: str                      # RTL 出处（文件:行号）
    level: str = "event"          # event=真事件脉冲 / level=电平状态（可能恒 1）


#: ARP_STAT 各位。
#: ⚠ bit5 / bit4 挂的是 ARP 引擎内部的**就绪标志**（`clear_finish`），
#:   语义是「清空扫描已完成、表项就绪、可正常读写」，**不是**「发生过清空动作」。
#:   该信号复位后约 2^CACHE_ADDR_WIDTH 拍（1024 拍 ≈ 2.6 μs @400MHz）自动置 1
#:   并保持 —— 所以这两位【几乎恒为 1】，不能据此判断缓存被清过。
#:   RTL 侧问题在于把「就绪」接到了「事件统计」位置，见
#:   Docs/Results/arp_stat_diag_20261029.md
ARP_STAT_BITS = [
    StatBit(6, "收到源 IP 非本网段的 ARP 询问",
             "ARP 请求里的源 IP 不属于本机任一套子网，因此无法回应该请求",
             "arp_engine_top.v:633 stat_query_src_not_local"),
    StatBit(5, "ARP 缓存已就绪（扫描完成）",
             "内部「缓存地址扫描」已完成，表项就绪、可正常读写。这是【就绪标志】不是事件 —— "
             "复位后约 2.6 μs 就自动置 1 并保持，【不代表真的执行过 CACHE_CLEAR 动作】。",
             "arp_cache_write.v:75 clear_finish（就绪电平，非事件脉冲）", "level"),
    StatBit(4, "ARP 等待表已就绪（扫描完成）",
             "内部「等待表地址扫描」已完成，表项就绪。这是【就绪标志】不是事件 —— "
             "复位后自动置位，【不代表真的执行过 PEND_CLEAR 动作】。",
             "arp_pending_ctrl.v:92 clear_finish（就绪电平，非事件脉冲）", "level"),
    StatBit(3, "有请求未得到应答（超时）",
             "查询已发出但没等到对端应答，超过 PENDING_TIME 后判超时。"
             "这一位置位通常意味着对端不回应 ARP。",
             "arp_engine_top.v:592 stat_lookup_no_resp_error"),
    StatBit(2, "ARP 等待队列溢出",
             "待应答请求队列满，新请求被丢弃", "arp_engine_top.v:620 stat_pending_fifo_overflow_error"),
    StatBit(1, "ARP 应答队列溢出",
             "待发送应答队列满，应答帧被丢弃", "arp_engine_top.v:612 stat_ack_fifo_overflow_error"),
    StatBit(0, "收到非标准 ARP 帧",
             "帧长度或 AXIS keep 不合规，不符合标准 ARP 格式",
             "arp_engine_top.v:604 stat_rx_error"),
]

#: ICMP_STAT 各位（全部是真实事件）
ICMP_STAT_BITS = [
    StatBit(3, "因「不是 echo 请求」被丢",
             "收到的 IPv4 报文不是 ICMP echo request，不予应答",
             "icmpv4_echo_reply.v:316 bit2 = ~is_echo_req"),
    StatBit(2, "因 MAC 校验失败被丢",
             "ICMP 目的 MAC 与本机不匹配", "icmpv4_echo_reply.v:316 bit1 = ~is_frame_valid"),
    StatBit(1, "因 TTL = 0 被丢",
             "IPv4 首部 TTL 已耗尽", "icmpv4_echo_reply.v:316 bit0 = ~is_ttl_live"),
    StatBit(0, "曾发生过丢弃",
             "bit3~bit1 的或 —— 只要上面任一原因发生过就置位",
             "net_stack_top.v:803 icmp_reason_sticky | icmp_drop_reason"),
]


@dataclass(frozen=True)
class GeomField:
    """GEOMETRY 的一个字段：它约束的是什么、单位是什么。"""
    name: str
    label: str                       # 中文名
    unit: str                        # 单位 / 语义类别
    desc: str                        # 这个数字代表什么
    items: Tuple[int, ...] = ()      # 受该字段约束的 ITEM 编号
    kind: str = "count"              # count=份数 / width=位宽


#: GEOMETRY 9 个字段的完整语义。
#: 全部来自 RTL：cfg_reg_bank.v 的 rd_idx_* 选路 + cfg_map.vh 的 *_ARR 参数。
#: 这些都是【编译期常量】parameter，不是运行期可改的配置 ——
#: 所以读回来的「当前值」恒等于「全局上限」，除非换了 bitstream。
#: 位宽类几何字段（不是档数，约束的是「字段能存多大」）
GEOM_CONSTRAINS: Dict[str, Tuple[int, ...]] = {
    "ARBITER_VAL_WIDTH": (0x31, 0x32, 0x34),
    "PENDING_TIME_WIDTH": (0x30,),
}


#: GEOMETRY 的 RTL 拼接顺序（**高 → 低**），直接抄自
#: `cfg_reg_bank.v` 的 `CFG_R_GEOMETRY` 分支。它是校验
#: GEOMETRY_FIELDS 字节序是否正确的唯一依据。
GEOMETRY_RTL_ORDER = (
    "UDP_RX_PORT_NUM", "IPV6_RX_NUM", "IPV4_RX_NUM", "MAC_RX_NUM",
    "LOCAL_DST_IPV6_MAC_NUM", "LOCAL_SRC_IPV6_MAC_NUM", "LOCAL_IPV4_MAC_NUM",
    "PENDING_TIME_WIDTH", "ARBITER_VAL_WIDTH",
)

# 导入即校验：GEOMETRY_FIELDS 必须是 RTL 拼接顺序的反序（小端）
assert tuple(GEOMETRY_FIELDS) == tuple(reversed(GEOMETRY_RTL_ORDER)), (
    "GEOMETRY_FIELDS 的字节序与 RTL 拼接顺序不符！\n"
    f"  当前: {GEOMETRY_FIELDS}\n"
    f"  应为: {list(reversed(GEOMETRY_RTL_ORDER))}\n"
    "  顺序错了会导致档数推导读到别的字段 ⇒ 多读超限档 ⇒ 设备回 BAD_SET。"
)


GEOMETRY_SEMANTICS: Dict[str, GeomField] = {
    "ARBITER_VAL_WIDTH": GeomField(
        "ARBITER_VAL_WIDTH", "仲裁优先级位宽", "bit",
        "发送仲裁优先级字段的宽度。取低 4 位 ⇒ 优先级取值 0~15，0 表示禁用。"
        "ARP/ICMP/命令应答三类内部帧共用这个宽度。",
        GEOM_CONSTRAINS["ARBITER_VAL_WIDTH"], "width"),
    "PENDING_TIME_WIDTH": GeomField(
        "PENDING_TIME_WIDTH", "ARP 超时计数字段位宽", "bit",
        "PENDING_TIME 的字段宽度。低 57 位有效 ⇒ 取值上限 2^57-1 个用户时钟周期。"
        "用户时钟 400 MHz 下 1 秒 = 400,000,000 周期。",
        GEOM_CONSTRAINS["PENDING_TIME_WIDTH"], "width"),
    "LOCAL_IPV4_MAC_NUM": GeomField(
        "LOCAL_IPV4_MAC_NUM", "IPv4 地址套数", "套",
        "每口可配置的 IPv4 地址套数。一套 = 本机 IP + MAC + 网关 + 掩码 "
        "四个 ITEM 共用同一个套索引。",
        (0x00, 0x01, 0x02, 0x03)),
    "IPV4_RX_NUM": GeomField(
        "IPV4_RX_NUM", "IPv4 协议号分流档数", "档",
        "每口按 IPv4 协议号分流的档数。写进去的是「该档认什么协议号」，"
        "命中即进对应用户通道。",
        (0x11,)),
    "IPV6_RX_NUM": GeomField(
        "IPV6_RX_NUM", "IPv6 下一首部分流档数", "档",
        "每口按 IPv6 下一首部号（Next Header）分流的档数。",
        (0x12,)),
    "LOCAL_SRC_IPV6_MAC_NUM": GeomField(
        "LOCAL_SRC_IPV6_MAC_NUM", "本机 IPv6 地址套数", "套",
        "每口可配置的本机 IPv6 地址套数。一套 = IPv6 地址 + 对应 MAC。",
        (0x04, 0x05)),
    "LOCAL_DST_IPV6_MAC_NUM": GeomField(
        "LOCAL_DST_IPV6_MAC_NUM", "邻居 IPv6 地址套数", "套",
        "每口可配置的邻居 IPv6 地址套数。一套 = 邻居 IPv6 地址 + 对应 MAC。",
        (0x06, 0x07)),
    "MAC_RX_NUM": GeomField(
        "MAC_RX_NUM", "以太类型分流档数", "档",
        "每口按以太类型（EtherType）分流的档数，用于识别用户自定义的二层协议。",
        (0x10,)),
    "UDP_RX_PORT_NUM": GeomField(
        "UDP_RX_PORT_NUM", "UDP 目的端口区间档数", "档",
        "每口按 UDP 目的端口区间分流的档数。一档 = 一个 {低16b, 高16b} 端口区间。"
        "命令通道是内部档，占索引 0，不计入此数。",
        (0x13,)),
}


def geometry_semantics() -> List[Dict[str, Any]]:
    """导出 GEOMETRY 字段的完整语义，供前端渲染。"""
    out: List[Dict[str, Any]] = []
    for name in GEOMETRY_FIELDS:
        g = GEOMETRY_SEMANTICS.get(name)
        if g is None:
            out.append({"name": name, "label": name, "unit": "", "desc": "",
                        "items": [], "item_names": [], "kind": "count"})
            continue
        out.append({
            "name": g.name,
            "label": g.label,
            "unit": g.unit,
            "desc": g.desc,
            "kind": g.kind,
            "items": list(g.items),
            "item_names": [ITEMS[c].name for c in g.items if c in ITEMS],
        })
    return out


def readonly_hints() -> Dict[int, str]:
    """只读状态项的解释（前端展示用）。"""
    return dict(READONLY_HINTS)


def tx_lane_meta() -> List[Dict[str, Any]]:
    """TX_ACTIVE 通道号的含义表。"""
    return [{"idx": i, "name": n, "desc": d} for i, n, d in TX_ACTIVE_LANES]


#: TX_ACTIVE 报的是 MAC 层 eth_tx_mux 的仲裁通道号（lane）。
#: 来源：net_stack_top.v 的 `lane0=arp / lane1=ipv4 / lane2=ipv6 / lane3..=用户自定义段`
#: 以及 eth_port_top.v 的 TX_TYPE_NUM=4（⇒ TX_IDX_WIDTH=2，值域 0~3）。
TX_ACTIVE_LANES = [
    (0, "ARP 引擎", "内部 ARP 帧（请求应答 / 免费 ARP），优先级取 ARP_PRIO"),
    (1, "IPv4 通道", "所有 IPv4 报文（用户 IPv4 档 + UDP 应用），优先级取 usr[3:0]"),
    (2, "IPv6 通道", "所有 IPv6 报文（用户 IPv6 档），优先级取 usr[3:0]"),
    (3, "用户自定义 MAC 段", "用户直接投递的二层帧，不经 IP 分流"),
]

#: 只读状态项的语义解释（前端展示用）
READONLY_HINTS: Dict[int, str] = {
    0x51: "固件版本号 {主.次.构建.协议}。构建号变化通常意味着固件更新过。",
    0x52: "该网口的物理链路状态。bit0=1 表示 CMAC 已同步 —— "
          "为 0 时所有发包都会失败，先查物理链路与 GT/PCS 配置。",
    0x53: "该网口发送侧是否空闲。bit0=1 表示当前没有帧在发送，"
          "为 0 说明有帧正在排队或发送中。",
    0x54: "该网口当前正在发送的 MAC 层通道号（lane）。"
          "可据此判断是谁占住了发送带宽。",
    0x55: "该网口 IPv4 出包的 DF（Don't Fragment）标志。"
          "置位后大于路径 MTU 的包会被丢弃，不做分片。",
    0x70: "本口各项配置能力的实际份数。这些是**编译期常量**（bitstream 决定），"
          "运行期不可改；写超了会返回 BAD_SET。",
    0x71: "全芯片各口共用的能力上限。当前值与上限相同即为正常 —— "
          "不一致说明该口被裁剪过（按实际资源分配）。",
    0x72: "本芯片配置的网口总数。写配置时 PORT 必须小于这个值。",
}


def tx_active_lane(idx: int) -> Optional[Tuple[int, str, str]]:
    """TX_ACTIVE 的通道号 → (编号, 名称, 说明)；超出范围返回 None。"""
    for i, name, desc in TX_ACTIVE_LANES:
        if i == idx:
            return (i, name, desc)
    return None


def stat_bits_meta() -> Dict[int, List[Dict[str, Any]]]:
    """导出统计位的完整语义（位号 / 短名 / 详述 / RTL 出处）。"""
    out: Dict[int, List[Dict[str, Any]]] = {}
    for item, table in ((0x60, ARP_STAT_BITS), (0x61, ICMP_STAT_BITS)):
        rows = []
        for b in table:
            rows.append({"bit": b.bit, "short": b.short, "desc": b.desc,
                         "src": b.src, "level": b.level})
        out[item] = rows
    return out


def slots_for(item: int, geom: Optional[Sequence[int]]) -> int:
    """
    某个 ITEM 在某口上有几档（SET 维度）。

    geom 是该口读回的 GEOMETRY 原始字节（9 B）。传 None 时按 1 档处理。
    """
    it = item_by_code(item)
    if it is None or not it.indexed:
        return 1
    field = SLOT_FIELD.get(it.code)
    if not field or not geom:
        return 1
    try:
        idx = GEOMETRY_FIELDS.index(field)
    except ValueError:
        return 1
    if idx >= len(geom):
        return 1
    return max(1, int(geom[idx]))


def bit_labels_for(item: int) -> List[Tuple[int, str]]:
    """返回该 ITEM 各位的含义 [(bit, 说明), ...]；没有位定义则空。"""
    if item == 0x60:
        return [(b.bit, b.short) for b in ARP_STAT_BITS]
    if item == 0x61:
        return [(b.bit, b.short) for b in ICMP_STAT_BITS]
    return []


def to_edit_text(item: int, raw: bytes) -> str:
    """
    把读回的原始字节转成「可直接编辑并写回」的文本。

    与 parse_value 互为逆运算：parse_value(to_edit_text(x)) == x

    只读项（mode='r'）不走可编辑路径，直接用 fmt_value —— 它的输出带格式化
    与含义说明（如 ARP_STAT 显示成 `0x00000000 ← 有请求未得到应答`），
    比裸数值有用得多。
    """
    if not raw:
        return ""
    it = item_by_code(item)
    if it is not None and it.mode == 'r':
        return fmt_value(item, raw)

    if item in (0x00, 0x02, 0x03, 0x04, 0x06):     # IPv4 / IPv6
        return fmt_value(item, raw)
    if item in (0x01, 0x05, 0x07):                  # MAC
        return fmt_value(item, raw)
    if item == 0x13:                                # 端口区间 → "low-high"
        v = int.from_bytes(raw, "little")
        return f"{v & 0xFFFF}-{(v >> 16) & 0xFFFF}"
    if item == 0x10:                                # 以太类型 → 0xXXXX
        return f"0x{int.from_bytes(raw, 'little'):04X}"
    if item in (0x11, 0x12):                        # 协议号 → 0xXX
        return f"0x{int.from_bytes(raw, 'little'):02X}"
    if item == 0x30:                                # 周期数 → 十进制
        return str(int.from_bytes(raw, "little") & ((1 << 57) - 1))
    if item == 0x51:                                # 版本 → 0xXXXXXXXX
        return f"0x{int.from_bytes(raw, 'little'):08X}"
    if item in (0x70, 0x71):                        # GEOMETRY → 按字节拆开
        return " ".join(f"{b:02X}" for b in raw[:9])
    if it is not None and it.width in (1, 2, 4, 6, 8, 16):
        return str(int.from_bytes(raw, "little"))
    return raw.hex()

def item_meta() -> List[Dict[str, Any]]:
    """
    导出 ITEM 表的完整元数据，供前端渲染（后端 /api/meta 直接吐这个）。

    这是前端唯一的「ITEM 语义来源」——前端不再硬编码任何 ITEM 编号。
    """
    out: List[Dict[str, Any]] = []
    for code in sorted(ITEMS):
        it = ITEMS[code]
        out.append({
            "code": code,
            "code_hex": f"0x{code:02X}",
            "name": it.name,
            "width": it.width,
            "mode": it.mode,
            "indexed": it.indexed,
            "per_port": it.per_port,
            # 该 ITEM 的档数由 GEOMETRY 的哪个字段决定（前端据此展开槽位）
            "slot_field": SLOT_FIELD.get(code),
            "desc": it.desc,
            "group": it.group,
            "editor": it.editor,
            "action": it.is_action,
        })
    return out


# ============================================================================
# 3. TLV 编解码
# ============================================================================

@dataclass
class Tlv:
    """一根请求 TLV。"""
    op: int
    seq: int
    item: int
    port: int = 0
    set_idx: int = 0
    value: bytes = b""

    def __post_init__(self) -> None:
        if len(self.value) > MAX_VALUE_BYTES:
            raise ValueError(f"VALUE 超过 {MAX_VALUE_BYTES} 字节")
        if self.op not in (OP_SET, OP_GET):
            raise ValueError(f"非法 OP: 0x{self.op:02X}")

    def encode(self) -> bytes:
        return bytes((
            self.op & 0xFF,
            self.seq & 0xFF,
            self.item & 0xFF,
            ((self.set_idx & 0x0F) << 4) | (self.port & 0x0F),   # SET 高 4 位 / PORT 低 4 位
            len(self.value) & 0xFF,
        )) + self.value

    def __str__(self) -> str:
        it = item_by_code(self.item)
        nm = it.name if it else f"ITEM_0x{self.item:02X}"
        return (f"{'SET' if self.op == OP_SET else 'GET'} seq={self.seq} "
                f"{nm} port={self.port} set={self.set_idx} len={len(self.value)}")


@dataclass
class Rsp:
    """一条应答。"""
    op: int
    seq: int
    status: int
    item: int
    port: int
    set_idx: int
    value: bytes = b""

    @property
    def ok(self) -> bool:
        return self.op != RSP_ERR and self.status == ST_OK

    @property
    def status_name(self) -> str:
        return STATUS_NAME.get(self.status, f"0x{self.status:02X}")

    @property
    def item_obj(self) -> Optional[Item]:
        return item_by_code(self.item)

    @property
    def item_name(self) -> str:
        it = self.item_obj
        return it.name if it else f"ITEM_0x{self.item:02X}"

    def key(self) -> Tuple[int, int, int, int]:
        """四元组匹配键 (SEQ, ITEM, SET, PORT)。"""
        return (self.seq, self.item, self.set_idx, self.port)

    def __str__(self) -> str:
        base = (f"{self.item_name} port={self.port} set={self.set_idx} "
                f"seq={self.seq} status={self.status_name}")
        if self.ok and self.value:
            return f"{base} = {fmt_value(self.item, self.value)}"
        return base


def encode_tlv(op: int, seq: int, item: int, value: bytes = b"",
               port: int = 0, set_idx: int = 0) -> bytes:
    """便捷函数：编一根 TLV。"""
    return Tlv(op, seq, item, port, set_idx, value).encode()


def encode_frame(tlvs: Sequence[Tlv]) -> bytes:
    """把多根 TLV 拼成一帧（首尾相连，无帧头）。"""
    return b"".join(t.encode() for t in tlvs)


def parse_rsps(buf: bytes) -> List[Rsp]:
    """
    解析应答字节流。一帧可能含多条应答（三路合并）。

    应答头固定 6 字节（cfg_error.v 的 mkeep = 6'b111111 印证）：

        byte0 = OP
        byte1 = SEQ
        byte2 = STATUS
        byte3 = ITEM
        byte4 = (SET << 4) | PORT        ← 与请求的 TAG 高字节编码相同
        byte5 = LEN
        byte6.. = VALUE（仅 GET_RSP 才有）

    注意：SET_RSP / ERR_RSP 的 LEN 只是「回显请求的 LEN」，
    不表示后面跟着 VALUE —— 不能拿它去切片，否则会把后续应答吃掉。
    """
    out: List[Rsp] = []
    i, n = 0, len(buf)
    while i + 6 <= n:
        op = buf[i]
        seq = buf[i + 1]
        status = buf[i + 2]
        item = buf[i + 3]
        port = buf[i + 4] & 0x0F
        set_idx = (buf[i + 4] >> 4) & 0x0F
        ln = buf[i + 5]
        i += 6

        if op == RSP_GET:
            if ln > MAX_VALUE_BYTES or i + ln > n:
                break                       # 长度异常，剩余字节不完整
            out.append(Rsp(op, seq, status, item, port, set_idx, buf[i:i + ln]))
            i += ln
        else:
            # SET_RSP / ERR_RSP：无 VALUE
            out.append(Rsp(op, seq, status, item, port, set_idx, b""))
    return out


def match_key(seq: int, item: int, set_idx: int, port: int) -> Tuple[int, int, int, int]:
    return (seq & 0xFF, item & 0xFF, set_idx & 0x0F, port & 0x0F)


# ============================================================================
# 4. VALUE 的语义化（原始字节 ↔ 人类可读）
# ============================================================================

def _u(raw: bytes) -> int:
    """小端字节 → 无符号整数。"""
    return int.from_bytes(raw, "little")


def fmt_value(item: int, raw: bytes) -> str:
    """把 VALUE 原始字节格式化成可读字符串。"""
    if not raw:
        return "(空)"

    if item in (0x00, 0x02, 0x03):                      # IPv4 / 网关 / 掩码
        try:
            return str(ipaddress.IPv4Address(raw))
        except Exception:
            return raw.hex(" ")

    if item in (0x01, 0x05, 0x07):                      # MAC
        return ":".join(f"{b:02X}" for b in raw)

    if item in (0x04, 0x06):                            # IPv6
        try:
            return str(ipaddress.IPv6Address(raw))
        except Exception:
            return raw.hex(" ")

    if item == 0x10:                                    # 以太类型
        return f"0x{_u(raw):04X}"

    if item in (0x11, 0x12):                            # 协议号 / 下一首部
        return f"0x{_u(raw):02X}"

    if item == 0x13:                                    # UDP 端口区间
        v = _u(raw)
        lo, hi = v & 0xFFFF, (v >> 16) & 0xFFFF
        return f"[{lo}, {hi}]"

    if item == 0x30:                                    # PENDING_TIME：周期数 + 秒（按 400MHz）
        v = _u(raw) & ((1 << 57) - 1)
        return f"{v} 周期（{v / 400_000_000:.3f} s @400MHz）"

    if item in (0x31, 0x32, 0x34):                      # 优先级
        v = _u(raw) & 0x0F
        return f"{v}（{'禁用' if v == 0 else '启用'}）"

    if item == 0x33:                                    # 命令端口
        return f"0x{_u(raw):04X}（{_u(raw)}）"

    if item == 0x51:                                    # VERSION
        v = _u(raw)
        return (f"0x{v:08X}（主 {(v >> 24) & 0xFF}.{(v >> 16) & 0xFF}"
                f".{(v >> 8) & 0xFF} 协议 {v & 0xFF}）")

    if item == 0x52:                                    # LINK_STATUS
        v = _u(raw)
        return f"0x{v:02X}（{'链路可用' if v & 1 else '链路断开'}）"

    if item == 0x53:                                    # TX_IDLE
        v = _u(raw)
        return f"0x{v:02X}（{'空闲' if v & 1 else '忙'}）"

    if item == 0x54:                                    # TX_ACTIVE
        idx = _u(raw) & 0x07
        lane = tx_active_lane(idx)
        if lane:
            return f"lane{idx} · {lane[1]}"
        return f"lane{idx}"

    if item == 0x55:                                    # IS_DF
        v = _u(raw)
        return f"0x{v:02X}（DF={'置位' if v & 1 else '清零'}）"

    if item == 0x60:                                    # ARP_STAT
        v = _u(raw)
        hits = [b.short for b in ARP_STAT_BITS if v & (1 << b.bit)]
        return f"0x{v:08X}" + ("" if not hits else "  ← " + "; ".join(hits))

    if item == 0x61:                                    # ICMP_STAT
        v = _u(raw)
        hits = [b.short for b in ICMP_STAT_BITS if v & (1 << b.bit)]
        return f"0x{v:02X}" + ("" if not hits else "  ← " + "; ".join(hits))

    if item in (0x70, 0x71):                            # GEOMETRY / GEOMETRY_MAX
        parts = [f"{GEOMETRY_FIELDS[k]}={raw[k]}" for k in range(min(9, len(raw)))]
        return ", ".join(parts)

    if item == 0x72:                                    # PORT_NUM
        return f"{_u(raw) & 0x0F} 个网口"

    return f"0x{_u(raw):0{len(raw) * 2}X}（{raw.hex(' ')}）"


def parse_value(item: int, text: str) -> bytes:
    """
    把用户输入的文本转成 VALUE 原始字节（小端）。

    支持：
        IP       192.168.1.100
        MAC      00:19:31:00:00:01   或  001931000001
        IPv6     fe80::1
        数值     0x88B5 / 12345
        区间     2-8                  （UDP_PORT_RANGE）
        动作     （空串，LEN=0）
    """
    it = item_by_code(item)
    if it is None:
        raise ValueError(f"未知 ITEM 0x{item:02X}")

    width = it.width
    text = text.strip()

    if it.is_action:
        return b""

    if not text:
        raise ValueError(f"{it.name} 需要提供值")

    if item in (0x00, 0x02, 0x03):
        addr = ipaddress.IPv4Address(text)
        return addr.packed

    if item in (0x01, 0x05, 0x07):
        mac = text.replace(":", "").replace("-", "").replace(".", "")
        if len(mac) != 12:
            raise ValueError("MAC 需要 12 个十六进制字符")
        return bytes.fromhex(mac)

    if item in (0x04, 0x06):
        addr = ipaddress.IPv6Address(text)
        return addr.packed

    if item == 0x13:
        m = text.replace("[", "").replace("]", "")
        for sep in (",", ":", "~"):
            m = m.replace(sep, "-")
        if "-" in m:
            lo_s, hi_s = m.split("-", 1)
            lo, hi = int(lo_s.strip(), 0), int(hi_s.strip(), 0)
        else:
            lo = hi = int(m, 0)
        if not (0 <= lo <= 0xFFFF and 0 <= hi <= 0xFFFF):
            raise ValueError("端口需在 0~65535")
        if lo > hi:
            raise ValueError(f"端口区间 low({lo}) 不能大于 high({hi})")
        return ((hi << 16) | lo).to_bytes(4, "little")

    val = int(text, 0)

    if item == 0x30:
        if val < 0 or val >= (1 << 57):
            raise ValueError("PENDING_TIME 超过 57 位")
        return val.to_bytes(8, "little")

    if item in (0x31, 0x32, 0x34):                  # 优先级：低 4 位
        if val < 0 or val > 0x0F:
            raise ValueError(f"{it.name} 取值范围 0~15（0=禁用）")
        return val.to_bytes(1, "little")

    if val < 0 or val >= (1 << (width * 8)):
        raise ValueError(f"{it.name} 超出 {width} 字节范围")

    return val.to_bytes(width, "little")


# ============================================================================
# 5. 客户端
# ============================================================================

class CfgError(Exception):
    """协议层错误（设备返回 ERR_RSP）。"""

    def __init__(self, rsp: Rsp):
        self.rsp = rsp
        super().__init__(f"{rsp.item_name} port={rsp.port} set={rsp.set_idx} "
                         f"被拒绝：{rsp.status_name} (0x{rsp.status:02X})")


class CfgTimeout(Exception):
    """超时未收到应答。"""


class CfgClient:
    """
    配置通道客户端。

    要点：
      * 同一 socket 收发（应答回到请求的源端口）
      * 按 (SEQ, ITEM, SET, PORT) 四元组匹配，不依赖收包顺序
      * 动作类（0x40~0x43）默认不重试，避免重复副作用
    """

    def __init__(self, host: str, port: int = DEFAULT_UDP_PORT,
                 local_ip: Optional[str] = None, timeout: float = 0.2,
                 retries: int = 3, verbose: bool = False) -> None:
        self.host = host
        self.port = port
        self.local_ip = local_ip
        self.timeout = timeout
        self.retries = retries
        self.verbose = verbose
        self._sock: Optional[socket.socket] = None
        self._seq = 0
        self._log = None      # 可选：可调用对象，接收字符串

    # ---------- 生命周期 ----------
    def open(self) -> "CfgClient":
        if self._sock is not None:
            return self
        family = socket.AF_INET6 if ":" in self.host else socket.AF_INET
        s = socket.socket(family, socket.SOCK_DGRAM)
        s.settimeout(self.timeout)
        if self.local_ip:
            bind_addr = (self.local_ip, 0) if family == socket.AF_INET else (self.local_ip, 0, 0, 0)
            s.bind(bind_addr)
        else:
            s.bind(("::", 0) if family == socket.AF_INET6 else ("", 0))
        self._sock = s
        return self

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            finally:
                self._sock = None

    def __enter__(self) -> "CfgClient":
        return self.open()

    def __exit__(self, *exc) -> None:
        self.close()

    # ---------- 内部 ----------
    def _next_seq(self) -> int:
        self._seq = (self._seq + 1) & 0xFF
        return self._seq

    def _emit(self, msg: str) -> None:
        if self.verbose:
            print(f"  [cfg] {msg}")
        if self._log:
            self._log(msg)

    def _recv_until(self, want: set, deadline: float) -> List[Rsp]:
        """
        收包直到 want 里的四元组全部到齐或超时。
        返回本次收到的所有应答（可能含不需要的）。
        """
        assert self._sock is not None
        got: List[Rsp] = []
        pending = set(want)
        while pending:
            remain = deadline - time.monotonic()
            if remain <= 0:
                break
            self._sock.settimeout(remain)
            try:
                data, _addr = self._sock.recvfrom(4096)
            except socket.timeout:
                break
            except OSError:
                break
            for rsp in parse_rsps(data):
                got.append(rsp)
                pending.discard(rsp.key())
                self._emit(f"← {rsp}")
        return got

    # ---------- 请求 ----------
    def transact(self, tlvs: Sequence[Tlv], retry: Optional[bool] = None
                 ) -> Dict[Tuple[int, int, int, int], Rsp]:
        """
        发送一帧（可含多根 TLV），返回 {四元组: Rsp}。

        retry=None 时自动判断：含动作类（LEN=0 的 0x40~0x43）则不重试。
        """
        if self._sock is None:
            self.open()

        if retry is None:
            retry = not any(t.item in (0x40, 0x41, 0x42, 0x43) for t in tlvs)

        want = {match_key(t.seq, t.item, t.set_idx, t.port) for t in tlvs}
        payload = encode_frame(tlvs)
        attempts = (self.retries if retry else 1)

        for attempt in range(attempts):
            self._emit(f"→ 第 {attempt + 1} 次发送 {len(tlvs)} 根 TLV，共 {len(payload)} B")
            assert self._sock is not None
            self._sock.sendto(payload, (self.host, self.port))
            deadline = time.monotonic() + self.timeout
            rsps = self._recv_until(want, deadline)

            table = {r.key(): r for r in rsps}
            missing = want - set(table)
            if not missing:
                return table
            self._emit(f"   缺 {len(missing)} 条应答，重试")

        raise CfgTimeout(
            f"{self.timeout * attempts:.1f}s 内未收到完整应答 "
            f"（缺 {len(want)} 条；确认目的 IP 是本机 set0 的 IP、端口与 CFG_CMD_PORT_SEL 口一致）"
        )

    # ---------- 语义化封装 ----------
    def get(self, item, port: int = 0, set_idx: int = 0) -> Rsp:
        code = _resolve_item(item)
        seq = self._next_seq()
        tlv = Tlv(OP_GET, seq, code, port, set_idx, b"")
        rsp = self.transact([tlv])[match_key(seq, code, set_idx, port)]
        _raise_if_err(rsp)
        return rsp

    def get_many(self, requests: Sequence[Tuple], ) -> List[Rsp]:
        """
        批量 GET。requests = [(item, port, set_idx), ...]
        每根 TLV 分配独立 SEQ，一次往返全部取回。
        """
        tlvs: List[Tlv] = []
        keys: List[Tuple[int, int, int, int]] = []
        for req in requests:
            item, port, set_idx = (tuple(req) + (0, 0))[:3]
            code = _resolve_item(item)
            seq = self._next_seq()
            tlvs.append(Tlv(OP_GET, seq, code, port, set_idx, b""))
            keys.append(match_key(seq, code, set_idx, port))
        table = self.transact(tlvs)
        return [table[k] for k in keys]

    def set(self, item, value, port: int = 0, set_idx: int = 0,
            precheck: bool = True) -> Rsp:
        """
        写配置 / 触发动作。

        precheck=True 时在本地先拦掉「只读项 SET」，省一轮往返；
        设 False 则直接发给设备，用于验证设备端的真实状态码。
        """
        code = _resolve_item(item)
        it = item_by_code(code)
        if precheck:
            if it is None:
                raise ValueError(f"未知 ITEM 0x{code:02X}（本地上位机已拦截）")
            if it.mode == "r":
                raise ValueError(f"{it.name} 是只读项，不能 SET（本地上位机已拦截）")
        if isinstance(value, (bytes, bytearray)):
            raw = bytes(value)
        else:
            if it is None:
                raise ValueError(f"未知 ITEM 0x{code:02X}，只能以原始字节发送")
            raw = parse_value(code, str(value))
        seq = self._next_seq()
        tlv = Tlv(OP_SET, seq, code, port, set_idx, raw)
        rsp = self.transact([tlv])[match_key(seq, code, set_idx, port)]
        _raise_if_err(rsp)
        return rsp

    def action(self, item, port: int = 0, precheck: bool = True) -> Rsp:
        """触发动作（0x40~0x43）。不重试——重发可能造成重复副作用。"""
        code = _resolve_item(item)
        it = item_by_code(code)
        if precheck and (it is None or not it.is_action):
            raise ValueError(f"ITEM 0x{code:02X} 不是动作类（本地上位机已拦截）")
        seq = self._next_seq()
        tlv = Tlv(OP_SET, seq, code, port, 0, b"")
        rsp = self.transact([tlv], retry=False)[match_key(seq, code, 0, port)]
        _raise_if_err(rsp)
        return rsp


# ============================================================================
# 6. 辅助
# ============================================================================

def _resolve_item(item) -> int:
    if isinstance(item, int):
        return item & 0xFF
    if isinstance(item, str):
        it = item_by_name(item)
        if it is not None:
            return it.code
        return int(item, 0) & 0xFF
    raise TypeError(f"无法识别的 ITEM: {item!r}")


def _raise_if_err(rsp: Rsp) -> None:
    if not rsp.ok:
        raise CfgError(rsp)


def parse_item_expr(text: str) -> int:
    """命令行用：接受 '0x00' / '51' / 'IPV4_LOCAL_IP'。"""
    return _resolve_item(text)
