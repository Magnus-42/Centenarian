#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
selftest.py — 上位机自测（不需要硬件）

在 127.0.0.1 上起一个 vdev，然后跑完整的协议用例：
    编解码对齐 / 正常读写 / 全部错误码 / 多 TLV / 乱序应答 / 动作生效

用法:
    python selftest.py            # 跑全部
    python selftest.py -v         # 附带 vdev 的收发日志
    python selftest.py --shuffle  # 同时验证乱序应答下的四元组匹配

退出码: 0 全过 / 1 有失败
"""

from __future__ import annotations

import argparse
import os
import random
import socket
import subprocess
import sys
import time
from typing import List, Optional, Tuple

import cfgproto as P
from vdev import VirtualDevice

HERE = os.path.dirname(os.path.abspath(__file__))

# ============================================================================
# 断言框架
# ============================================================================

PASS = 0
FAIL = 0
FAILED: List[str] = []


def ok(desc: str, detail: str = "") -> None:
    global PASS
    PASS += 1
    print(f"  [PASS] {desc}")


def bad(desc: str, detail: str = "") -> None:
    global FAIL
    FAIL += 1
    FAILED.append(desc)
    print(f"  [FAIL] {desc}" + (f"  ← {detail}" if detail else ""))


def check(desc: str, cond: bool, detail: str = "") -> bool:
    (ok if cond else bad)(desc, detail)
    return cond


def check_eq(desc: str, got, want) -> bool:
    return check(desc, got == want, f"got={got!r} want={want!r}")


def expect_err(desc: str, fn, want_status: int) -> bool:
    try:
        fn()
    except P.CfgError as exc:
        return check_eq(f"{desc} → {P.STATUS_NAME.get(want_status)}",
                        exc.rsp.status, want_status)
    except Exception as exc:
        return check(desc, False, f"抛出非 CfgError: {type(exc).__name__}: {exc}")
    return check(desc, False, "没有报错")


# ============================================================================
# 用例
# ============================================================================

def t_encoding() -> None:
    """请求组帧必须与文档示例逐字节一致。"""
    print("\n[1] 编解码对齐")
    t = P.Tlv(P.OP_GET, 0x01, 0x51, 0, 0, b"").encode()
    check_eq("GET 0x51 port0 set0 的 5 字节", t.hex(" ").upper(), "02 01 51 00 00")

    t = P.Tlv(P.OP_SET, 0x02, 0x03, 0, 0, bytes.fromhex("FFFF0000")).encode()
    check_eq("SET 0x03 LEN=4 的 9 字节", t.hex(" ").upper(),
             "01 02 03 00 04 FF FF 00 00")

    # SET/PORT 挤在 TAG 高字节：set=5 port=3 → 0x53
    t = P.Tlv(P.OP_GET, 0x03, 0x00, 3, 5, b"").encode()
    check_eq("SET/PORT 合成一字节（set=5 port=3 → 0x53）", f"{t[3]:02X}", "53")

    # 应答头 6 字节：OP SEQ STATUS ITEM {SET,PORT} LEN
    raw = bytes.fromhex("8201005100 04 00010100".replace(" ", ""))
    rsps = P.parse_rsps(raw)
    check("应答解析出 1 条", len(rsps) == 1, f"got {len(rsps)}")
    if rsps:
        r = rsps[0]
        check_eq("应答 op", r.op, P.RSP_GET)
        check_eq("应答 seq", r.seq, 1)
        check_eq("应答 item", r.item, 0x51)
        check_eq("应答 value 长度", len(r.value), 4)
        check_eq("VERSION 值", int.from_bytes(r.value, "little"), 0x00010100)

    # SET_RSP / ERR_RSP 不带 VALUE，LEN 只是回显 → 不能按 LEN 切片
    raw = bytes.fromhex("8F 02 07 51 00 00".replace(" ", "")) + \
          bytes.fromhex("82 03 00 00 00 04 0901A8C0".replace(" ", ""))
    rsps = P.parse_rsps(raw)
    check("ERR_RSP(LEN 回显 0) + GET_RSP 连排能解析出 2 条", len(rsps) == 2,
          f"got {len(rsps)}")
    if len(rsps) == 2:
        check_eq("  第 1 条是 ERR_RSP 且无 VALUE", (rsps[0].op, len(rsps[0].value)),
                 (P.RSP_ERR, 0))
        check_eq("  第 2 条是 GET_RSP 且带 4 B", (rsps[1].op, len(rsps[1].value)),
                 (P.RSP_GET, 4))

    # 值的文本解析
    # IP / MAC / IPv6 走网络序字节（见 TB/Config/tb_cfg_byteorder.v 的 RTL 判定）
    check_eq("IP 文本 → 网络序字节", P.parse_value(0x00, "192.168.1.100").hex(),
             "c0a80164")
    check_eq("MAC 文本 → 网络序字节", P.parse_value(0x01, "00:19:31:00:00:01").hex(),
             "001931000001")
    check_eq("端口区间 2-8 → 小端", P.parse_value(0x13, "2-8").hex(), "02000800")
    check_eq("以太类型 0x88B5 → 小端", P.parse_value(0x10, "0x88B5").hex(), "b588")
    check_eq("IP 字节 → 文本", P.fmt_value(0x00, bytes.fromhex("c0a80164")),
             "192.168.1.100")
    check_eq("MAC 字节 → 文本", P.fmt_value(0x01, bytes.fromhex("001931000001")),
             "00:19:31:00:00:01")

    # to_edit_text 与 parse_value 必须互为逆运算
    for _code, _raw in [
        (0x00, bytes.fromhex("c0a80109")),
        (0x01, bytes.fromhex("001931000001")),
        (0x04, bytes.fromhex("20010db8" + "00" * 12)),
        (0x13, bytes.fromhex("04000800")),
        (0x30, (400_000_000).to_bytes(8, "little")),
        (0x33, bytes.fromhex("dec0")),
    ]:
        _t = P.to_edit_text(_code, _raw)
        check_eq(f"to_edit_text/parse_value 互逆 (0x{_code:02X})",
                 P.parse_value(_code, _t), _raw)


def t_read_write(c: P.CfgClient) -> None:
    print("\n[2] 正常读写")
    r = c.get("VERSION")
    check_eq("GET VERSION 状态", r.status, P.ST_OK)
    check_eq("VERSION = 0x00010100", int.from_bytes(r.value, "little"), 0x00010100)

    r = c.get("IPV4_LOCAL_IP", 0)
    check_eq("口0 默认 IP = 192.168.1.9", P.fmt_value(0x00, r.value), "192.168.1.9")
    r = c.get("IPV4_LOCAL_IP", 1)
    check_eq("口1 默认 IP = 192.168.1.8", P.fmt_value(0x00, r.value), "192.168.1.8")

    c.set("IPV4_LOCAL_IP", "10.0.0.7", 0)
    r = c.get("IPV4_LOCAL_IP", 0)
    check_eq("SET 后回读 IP", P.fmt_value(0x00, r.value), "10.0.0.7")
    r = c.get("IPV4_LOCAL_IP", 1)
    check_eq("只影响口0，口1 不变", P.fmt_value(0x00, r.value), "192.168.1.8")

    c.set("IPV4_LOCAL_MAC", "AA:BB:CC:DD:EE:FF", 0)
    r = c.get("IPV4_LOCAL_MAC", 0)
    check_eq("SET/GET MAC", P.fmt_value(0x01, r.value), "AA:BB:CC:DD:EE:FF")

    c.set("UDP_PORT_RANGE", "100-200", 0, 1)
    r = c.get("UDP_PORT_RANGE", 0, 1)
    check_eq("SET/GET 端口区间（带槽）", P.fmt_value(0x13, r.value), "[100, 200]")

    c.set("IPV4_PROTO_DICT", 0x2F, 1, 2)
    r = c.get("IPV4_PROTO_DICT", 1, 2)
    check_eq("SET/GET 协议号", int.from_bytes(r.value, "little"), 0x2F)

    c.set("IPV6_SRC_LOCAL", "2001:db8::1", 0, 0)
    r = c.get("IPV6_SRC_LOCAL", 0, 0)
    check_eq("SET/GET IPv6", P.fmt_value(0x04, r.value), "2001:db8::1")

    r = c.get("GEOMETRY", 0)
    check_eq("GEOMETRY 长度 9 B", len(r.value), 9)
    check("GEOMETRY 的 ARBITER_VAL_WIDTH 非 0", r.value[0] > 0)


def t_errors(c: P.CfgClient) -> None:
    print("\n[3] 错误码全覆盖（关掉本地预检，走设备真实判定）")
    expect_err("SET 只读项 VERSION", lambda: c.set("VERSION", 1, precheck=False),
               P.ST_READ_ONLY)
    expect_err("SET 只读项 ARP_STAT", lambda: c.set("ARP_STAT", 0, precheck=False),
               P.ST_READ_ONLY)
    expect_err("GET 只写项 RESET_DEF", lambda: c.get("RESET_DEF"), P.ST_WRITE_ONLY)
    expect_err("GET 只写项 CACHE_CLEAR", lambda: c.get("CACHE_CLEAR"), P.ST_WRITE_ONLY)
    expect_err("ITEM 0x20 未定义", lambda: c.set(0x20, b"\x01", precheck=False),
               P.ST_BAD_ITEM)
    expect_err("ITEM 0x56（已删除）", lambda: c.set(0x56, b"\x00", precheck=False),
               P.ST_BAD_ITEM)
    expect_err("PORT 14 越界",
               lambda: c.set("IPV4_LOCAL_IP", "1.2.3.4", port=14, precheck=False),
               P.ST_BAD_PORT)
    expect_err("SET 槽越界 set=5",
               lambda: c.set("IPV4_LOCAL_IP", "1.2.3.4", set_idx=5, precheck=False),
               P.ST_BAD_SET)
    expect_err("SET LEN 短了",
               lambda: c.set("IPV4_LOCAL_IP", b"\x01", precheck=False), P.ST_BAD_LEN)
    expect_err("SET LEN 长了",
               lambda: c.set("IPV4_LOCAL_IP", b"\x01\x02\x03\x04\x05", precheck=False),
               P.ST_BAD_LEN)
    expect_err("非法 OP（0x03 当请求）",
               lambda: _send_raw(c, bytes([0x03, 0x01, 0x51, 0x00, 0x00])),
               P.ST_BAD_OP)


def _send_raw(c: P.CfgClient, payload: bytes) -> None:
    """直接发一段原始字节，绕过 Tlv 的 OP 合法性检查。"""
    if c._sock is None:
        c.open()
    c._sock.sendto(payload, (c.host, c.port))
    c._sock.settimeout(0.5)
    try:
        data, _ = c._sock.recvfrom(4096)
    except socket.timeout:
        raise P.CfgTimeout("原始帧无应答") from None
    rsps = P.parse_rsps(data)
    if not rsps:
        raise P.CfgTimeout("原始帧应答解析失败")
    if rsps[0].status != P.ST_OK:
        raise P.CfgError(rsps[0])


def t_multi(c: P.CfgClient) -> None:
    print("\n[4] 多 TLV 一帧 + 四元组匹配")
    reqs = [("VERSION", 0, 0), ("LINK_STATUS", 0, 0),
            ("LINK_STATUS", 1, 0), ("IS_DF", 1, 0)]
    rsps = c.get_many(reqs)
    check_eq("一次往返取回 4 条", len(rsps), 4)
    check_eq("顺序与请求一致[0]", rsps[0].item, 0x51)
    check_eq("顺序与请求一致[1]", (rsps[1].item, rsps[1].port), (0x52, 0))
    check_eq("顺序与请求一致[2]", (rsps[2].item, rsps[2].port), (0x52, 1))
    check_eq("顺序与请求一致[3]", rsps[3].item, 0x55)
    # SEQ 必须各不相同，否则无法区分
    seqs = [r.seq for r in rsps]
    check("4 条应答的 SEQ 互不相同", len(set(seqs)) == 4, f"seqs={seqs}")


def t_actions(c: P.CfgClient) -> None:
    print("\n[5] 动作与 sticky 统计")
    c.set("IPV4_LOCAL_IP", "172.16.0.1", 0)
    r = c.get("IPV4_LOCAL_IP", 0)
    check_eq("改 IP 后回读", P.fmt_value(0x00, r.value), "172.16.0.1")

    c.action("RESET_DEF", 0)
    r = c.get("IPV4_LOCAL_IP", 0)
    check_eq("RESET_DEF 后恢复默认", P.fmt_value(0x00, r.value), "192.168.1.9")

    c.action("STAT_CLEAR", 0)
    r = c.get("ARP_STAT", 0)
    check_eq("STAT_CLEAR 后 ARP_STAT 归零", int.from_bytes(r.value, "little"), 0)

    for name in ("CACHE_CLEAR", "PEND_CLEAR"):
        try:
            c.action(name, 0)
            ok(f"动作 {name} 执行成功")
        except Exception as exc:
            bad(f"动作 {name}", str(exc))


def t_dump(c: P.CfgClient) -> bool:
    print("\n[6] 全量读取")
    reqs: List[Tuple[int, int, int]] = []
    pn = c.get("PORT_NUM")
    n = pn.value[0] & 0x0F
    check_eq("PORT_NUM = 2", n, 2)

    for code in sorted(P.ITEMS):
        it = P.ITEMS[code]
        if it.is_action:
            continue
        if not it.per_port:
            reqs.append((code, 0, 0))
            continue
        for p in range(n):
            reqs.append((code, p, 0))
    rsps = c.get_many(reqs)
    check_eq(f"全量读取 {len(reqs)} 项全部返回", len(rsps), len(reqs))
    all_ok = all(r.ok for r in rsps)
    check("全量读取无 ERR_RSP", all_ok,
          ",".join(r.item_name for r in rsps if not r.ok))
    return all_ok


def t_semantics() -> None:
    """语义元数据自检：每个字段/位都必须有中文名与解释。"""
    print("\n[1b] 语义元数据")

    # GEOMETRY 字节序：必须等于 RTL 拼接顺序的反序（小端）
    # 2026-10-29 曾写错中间 5 个字段 ⇒ 档数推导读错字段 ⇒ 多读超限档 ⇒ 7 项 BAD_SET
    check("GEOMETRY_FIELDS 字节序 == RTL 拼接反序",
          tuple(P.GEOMETRY_FIELDS) == tuple(reversed(P.GEOMETRY_RTL_ORDER)),
          f"{P.GEOMETRY_FIELDS}")

    # 用「口1 MAC_RX=1 / 口0 MAC_RX=2」的真实配置验证档数推导
    g1 = [4, 57, 1, 2, 2, 1, 3, 3, 2]      # 口1: MAC_RX_NUM=1, UDP_RX_NUM=2
    check_eq("口1 ETH_TYPE_DICT 档数 = MAC_RX_NUM",
             P.slots_for(0x10, g1), 1)
    check_eq("口1 UDP_PORT_RANGE 档数 = UDP_RX_PORT_NUM",
             P.slots_for(0x13, g1), 2)
    check_eq("口1 IPV6_SRC_LOCAL 档数 = LOCAL_SRC_IPV6_MAC_NUM",
             P.slots_for(0x04, g1), 2)
    check_eq("口1 IPV4_PROTO_DICT 档数 = IPV4_RX_NUM",
             P.slots_for(0x11, g1), 3)

    # 全局项不应按口展开（RTL 读出不看 rd_port）
    for code in (0x71, 0x72):
        check(f"0x{code:02X} 是全局项（不按口展开）",
              not P.ITEMS[code].per_port)

    # GEOMETRY 语义表：每个字段都要有中文名与含义说明
    sem = P.geometry_semantics()
    check_eq("几何语义条数 == 字段数", len(sem), len(P.GEOMETRY_FIELDS))
    missing = [g["name"] for g in sem if not g.get("label") or not g.get("desc")]
    check("每个几何字段都有中文名与含义说明", not missing, missing)

    # 每个带档维度的 ITEM 都必须能映射到某个几何字段
    indexed = [c for c, it in P.ITEMS.items() if it.indexed]
    unmapped = [P.ITEMS[c].name for c in indexed if c not in P.SLOT_FIELD]
    check("所有带 SET 维度的 ITEM 都能映射到几何字段", not unmapped, unmapped)

    # 几何语义表声明的 ITEM：带档维度的必须与 SLOT_FIELD 一致；
    # 位宽类字段（ARBITER_VAL_WIDTH / PENDING_TIME_WIDTH）约束的不是档数，
    # 用 GEOM_CONSTRAINS 单独声明
    bad = []
    for name, g in P.GEOMETRY_SEMANTICS.items():
        for code in g.items:
            if g.kind == "count":
                if P.SLOT_FIELD.get(code) != name:
                    bad.append(f"{P.ITEMS[code].name}→{P.SLOT_FIELD.get(code)}≠{name}")
            else:
                if code not in P.GEOM_CONSTRAINS.get(name, ()):
                    bad.append(f"{P.ITEMS[code].name} 未在 GEOM_CONSTRAINS 声明")
    check("几何语义表与档数/位宽映射一致", not bad, bad)

    # 位宽类字段必须真的约束了对应 ITEM
    for name in ("ARBITER_VAL_WIDTH", "PENDING_TIME_WIDTH"):
        g = P.GEOMETRY_SEMANTICS[name]
        check(f"{name} 约束了对应 ITEM", bool(g.items) and
              all(c in P.ITEMS for c in g.items), g.items)

    # 统计位：每个位都要有短名 + 详述 + RTL 出处
    for item, cnt in ((0x60, 7), (0x61, 4)):
        rows = P.stat_bits_meta()[item]
        check_eq(f"0x{item:02X} 统计位数量", len(rows), cnt)
        bad = [r["bit"] for r in rows
               if not r.get("short") or not r.get("desc") or not r.get("src")]
        check(f"0x{item:02X} 每个位都有短名/详述/出处", not bad, bad)

    # 只读项提示
    hints = P.readonly_hints()
    for code in (0x51, 0x52, 0x53, 0x54, 0x55, 0x70, 0x71, 0x72):
        check(f"0x{code:02X} 有解释文本", code in hints and len(hints[code]) > 10)

    # TX 通道表
    lanes = P.tx_lane_meta()
    check_eq("TX 通道数", len(lanes), 4)
    check("TX_ACTIVE fmt 显示通道名",
          "IPv6" in P.fmt_value(0x54, bytes([2])))

    # 统计位格式化要能说出命中项
    txt = P.fmt_value(0x60, bytes.fromhex("48000000"))
    check("ARP_STAT 格式化列出命中位", "非本网段" in txt and "超时" in txt, txt)


# ============================================================================
# Web 后端 API 冒烟
# ============================================================================

def t_web_api(vdev_port: int) -> None:
    """起一个后端进程，跑一遍 HTTP API 全链路。"""
    print("\n[7] Web 后端 API")
    import json
    import urllib.request

    http_port = _free_port()
    # 后端自带的 vdev 必须用【另一个】端口 —— 与外层 vdev 同端口会绑失败
    inner_vdev_port = _free_port()
    env = dict(os.environ)
    env["PYTHONPATH"] = HERE
    proc = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "server.py"),
         "--port", str(http_port), "--vdev", "--vdev-port", str(inner_vdev_port)],
        cwd=HERE, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        # 等后端起来
        base = f"http://127.0.0.1:{http_port}"
        op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        ready = False
        for _ in range(50):
            time.sleep(0.2)
            try:
                op.open(base + "/api/state", timeout=2).read()
                ready = True
                break
            except Exception:
                continue
        if not check("后端可访问", ready):
            return

        def call(path: str, body: Optional[dict] = None,
                 post: bool = False) -> dict:
            # post=True 时即使无请求体也强制 POST（urllib 在 data=None 时会退化成 GET）
            data = json.dumps(body).encode() if body is not None else (
                b"" if post else None)
            req = urllib.request.Request(
                base + path, data=data,
                headers={"Content-Type": "application/json"},
                method="POST" if (body is not None or post) else "GET")
            try:
                with op.open(req, timeout=15) as r:
                    return json.loads(r.read().decode())
            except urllib.error.HTTPError as e:
                return json.loads(e.read().decode())

        m = call("/api/meta")
        check_eq("meta 返回全部 ITEM", len(m["items"]), len(P.ITEMS))
        check_eq("meta 分组数", len(m["groups"]), len(P.GROUP_ORDER))

        r = call("/api/connect", {"host": "127.0.0.1", "port": inner_vdev_port,
                                  "timeout": 0.4})
        check("连接成功", r.get("ok"), r)
        check_eq("探测到网口数", r.get("port_num"), 2)

        r = call("/api/read", {"items": [{"item": 0x00, "port": 0, "set": 0},
                                         {"item": 0x00, "port": 1, "set": 0},
                                         {"item": 0x01, "port": 0, "set": 0}]})
        rows = {f"{x['item']}:{x['port']}": x for x in r["rows"]}
        check_eq("口0 IP 读回", rows["0:0"]["text"], "192.168.1.9")
        check_eq("口1 IP 读回", rows["0:1"]["text"], "192.168.1.8")
        check_eq("MAC 读回", rows["1:0"]["text"], "00:19:31:00:00:01")

        r = call("/api/write", {"item": 0x00, "port": 0, "set": 0,
                                "value": "10.0.0.7"})
        check("写入成功", r.get("ok"), r)
        r = call("/api/read", {"items": [{"item": 0x00, "port": 0, "set": 0}]})
        check_eq("写入后回读", r["rows"][0]["text"], "10.0.0.7")

        r = call("/api/write", {"item": 0x00, "port": 0, "set": 0,
                                "value": "999.1.1.1"})
        check("非法 IP 被拒", not r.get("ok"), r)

        r = call("/api/write", {"item": 0x51, "port": 0, "set": 0,
                                "value": "1", "precheck": False})
        check_eq("只读项写入 → READ_ONLY", r.get("status_name"), "READ_ONLY")

        r = call("/api/action", {"item": 0x43, "port": 0})
        check("动作执行成功", r.get("ok"), r)

        r = call("/api/dump", post=True)
        check(f"全量导出 {len(r['rows'])} 行", len(r["rows"]) > 40)
        bad = [x for x in r["rows"] if not x["ok"]]
        check("导出无失败项", not bad, bad[:3])

        r = call("/api/raw", {"hex": "03 05 51 00 00"})
        check_eq("原始帧非法 OP → BAD_OP",
                 r["rsps"][0]["status"] if r.get("rsps") else None, "BAD_OP")

        for path, tag in [("/", "Centenarian"), ("/style.css", "--bg"),
                          ("/app.js", "boot")]:
            with op.open(base + path, timeout=5) as rr:
                text = rr.read().decode()
            check(f"静态资源 {path} 可访问", tag in text, len(text))

        r = call("/api/state")
        check("state: connected", r.get("connected"))
        r = call("/api/disconnect", {})
        check("断开成功", r.get("ok"))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


# ============================================================================
# 入口
# ============================================================================

def _free_port() -> int:
    """
    找一个能用的 UDP 端口。

    Windows 会保留一段端口（动态端口区 + Hyper-V/WSL 排除段），
    随机撞上就会报 WSAEACCES。逐个试，绑定成功即返回。
    """
    import socket as _s
    for _ in range(200):
        p = random.randint(40000, 60000)
        try:
            sk = _s.socket(_s.AF_INET, _s.SOCK_DGRAM)
            sk.bind(("127.0.0.1", p))
            sk.close()
            return p
        except OSError:
            continue
    raise RuntimeError("找不到可用端口")


def run(port: int, shuffle: bool, verbose: bool) -> int:
    print("=" * 72)
    print("Centenarian 配置上位机自测")
    print("=" * 72)

    # 阶段 1：纯编解码，不需要设备
    t_encoding()
    t_semantics()

    # 阶段 2~6：起虚拟设备
    dev = VirtualDevice("127.0.0.1", port, num_ports=2,
                        shuffle=shuffle, verbose=verbose).start()
    time.sleep(0.3)
    try:
        with P.CfgClient("127.0.0.1", port, timeout=0.4, retries=2) as c:
            t_read_write(c)
            t_errors(c)
            t_multi(c)
            t_actions(c)
            t_dump(c)
    except Exception as exc:
        bad("未捕获异常中断", f"{type(exc).__name__}: {exc}")
        import traceback
        traceback.print_exc()
    finally:
        dev.stop()

    # 阶段 7：Web 后端 API（自带虚拟设备）
    try:
        t_web_api(port)
    except Exception as exc:
        bad("Web API 阶段异常中断", f"{type(exc).__name__}: {exc}")
        import traceback
        traceback.print_exc()

    print("\n" + "=" * 72)
    if FAIL == 0:
        print(f"*** 全部通过：{PASS} PASS / 0 FAIL ***")
    else:
        print(f"*** 有失败：{PASS} PASS / {FAIL} FAIL ***")
        for d in FAILED:
            print(f"    - {d}")
    print("=" * 72)
    return 0 if FAIL == 0 else 1


def main(argv=None) -> int:
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        except Exception:
            pass

    ap = argparse.ArgumentParser(description="配置上位机自测")
    ap.add_argument("--port", type=lambda s: int(s, 0), default=0,
                    help="虚拟设备监听端口（默认随机 49152~65535）")
    ap.add_argument("--shuffle", action="store_true",
                    help="打乱应答顺序，验证四元组匹配")
    ap.add_argument("-v", "--verbose", action="store_true", help="打印 vdev 收发")
    args = ap.parse_args(argv)

    port = args.port or _free_port()
    return run(port, args.shuffle, args.verbose)


if __name__ == "__main__":
    sys.exit(main())
