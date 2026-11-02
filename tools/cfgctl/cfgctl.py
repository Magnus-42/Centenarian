#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cfgctl.py — Centenarian 配置通道命令行上位机

Windows / Linux 通用，纯标准库，无需安装依赖。

常用示例
--------
    # 探测设备（读版本 + 几何 + 口数）
    python cfgctl.py -H 192.168.1.9 probe

    # 读一项
    python cfgctl.py -H 192.168.1.9 get IPV4_LOCAL_IP
    python cfgctl.py -H 192.168.1.9 get 0x00 --port 1

    # 写一项
    python cfgctl.py -H 192.168.1.9 set IPV4_LOCAL_IP 192.168.1.100
    python cfgctl.py -H 192.168.1.9 set UDP_PORT_RANGE 2-8 --set 2

    # 触发动作（不重试）
    python cfgctl.py -H 192.168.1.9 action reset
    python cfgctl.py -H 192.168.1.9 action stat-clear --port 1

    # 全量导出（人读 / JSON）
    python cfgctl.py -H 192.168.1.9 dump
    python cfgctl.py -H 192.168.1.9 dump --json > cfg.json

    # 列出所有 ITEM
    python cfgctl.py items

退出码
------
    0 成功   1 设备拒绝（ERR_RSP）   2 超时   3 参数/本地校验错误
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict, List, Optional, Tuple

import cfgproto as P

# ---------------------------------------------------------------------------
# 跨平台输出
# ---------------------------------------------------------------------------

def _setup_stdout() -> None:
    """Windows 控制台默认不是 UTF-8，强制一下，避免中文乱码。"""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        except Exception:
            pass


def _use_color() -> bool:
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("FORCE_COLOR"):
        return True
    return sys.stdout.isatty()


class C:
    on = _use_color()
    RED = "\033[31m" if on else ""
    GRN = "\033[32m" if on else ""
    YEL = "\033[33m" if on else ""
    BLU = "\033[36m" if on else ""
    DIM = "\033[2m" if on else ""
    BLD = "\033[1m" if on else ""
    RST = "\033[0m" if on else ""


# ---------------------------------------------------------------------------
# ITEM 名称简写（命令行便利）
# ---------------------------------------------------------------------------

ACTION_ALIAS = {
    "reset": "RESET_DEF", "reset-def": "RESET_DEF", "default": "RESET_DEF",
    "cache-clear": "CACHE_CLEAR", "cache": "CACHE_CLEAR",
    "pend-clear": "PEND_CLEAR", "pend": "PEND_CLEAR",
    "stat-clear": "STAT_CLEAR", "stat": "STAT_CLEAR",
}

# dump 时按类别分组输出
DUMP_GROUPS: List[Tuple[str, List[int]]] = [
    ("地址", [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]),
    ("分流", [0x10, 0x11, 0x12, 0x13]),
    ("行为", [0x30, 0x31, 0x32, 0x33, 0x34]),
    ("状态", [0x51, 0x52, 0x53, 0x54, 0x55]),
    ("统计", [0x60, 0x61]),
    ("边界", [0x70, 0x71, 0x72]),
]


# ---------------------------------------------------------------------------
# 客户端构建
# ---------------------------------------------------------------------------

def make_client(args) -> P.CfgClient:
    host = args.host or os.environ.get("CFG_HOST")
    if not host:
        raise SystemExit("请用 -H/--host 指定设备 IP（或设置环境变量 CFG_HOST）")
    return P.CfgClient(
        host=host,
        port=args.udp_port,          # 注意：是 udp_port，不是子命令的 args.port（网口号）
        local_ip=args.local_ip,
        timeout=args.timeout,
        retries=args.retries,
        verbose=args.verbose,
    )


def _resolve_action(text: str) -> int:
    key = text.strip().lower()
    if key in ACTION_ALIAS:
        return P.parse_item_expr(ACTION_ALIAS[key])
    return P.parse_item_expr(text)


# ---------------------------------------------------------------------------
# 输出辅助
# ---------------------------------------------------------------------------

def print_rsp(rsp: P.Rsp, json_out: bool = False) -> None:
    if json_out:
        return
    it = rsp.item_obj
    name = rsp.item_name
    where = ""
    if it is not None and it.per_port:
        where = f" 口{rsp.port}"
        if it.indexed:
            where += f"/槽{rsp.set_idx}"
    if rsp.ok:
        if rsp.value:
            print(f"{C.GRN}✓{C.RST} {C.BLD}{name}{C.RST}{where} = {P.fmt_value(rsp.item, rsp.value)}")
        else:
            print(f"{C.GRN}✓{C.RST} {C.BLD}{name}{C.RST}{where} 完成")
    else:
        print(f"{C.RED}✗{C.RST} {C.BLD}{name}{C.RST}{where} "
              f"{C.RED}{rsp.status_name}{C.RST} (0x{rsp.status:02X})")


def rsp_to_dict(rsp: P.Rsp) -> Dict[str, Any]:
    it = rsp.item_obj
    d: Dict[str, Any] = {
        "item": rsp.item_name,
        "item_code": rsp.item,
        "port": rsp.port,
        "set": rsp.set_idx,
        "op": f"0x{rsp.op:02X}",
        "status": rsp.status_name,
        "ok": rsp.ok,
    }
    if rsp.ok and rsp.value:
        d["raw"] = rsp.value.hex()
        d["value"] = P.fmt_value(rsp.item, rsp.value)
        if it is not None and it.width in (1, 2, 4, 6, 8, 16):
            d["int"] = int.from_bytes(rsp.value, "little")
    return d


# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------

def cmd_probe(c: P.CfgClient, args) -> int:
    """探测：版本 → 几何 → 口数。"""
    rsps = c.get_many([("VERSION", 0, 0), ("PORT_NUM", 0, 0), ("GEOMETRY", 0, 0)])
    version, port_num, geom = rsps
    n = port_num.value[0] & 0x0F if port_num.value else 0

    if args.json:
        print(json.dumps({
            "host": c.host, "port": c.port,
            "version": P.fmt_value(0x51, version.value),
            "ports": n,
            "geometry": dict(zip(P.GEOMETRY_FIELDS, geom.value)),
        }, ensure_ascii=False, indent=2))
        return 0

    print(f"{C.BLD}设备{C.RST} {c.host}:{c.port}")
    print(f"  {C.DIM}版本{C.RST}    {P.fmt_value(0x51, version.value)}")
    print(f"  {C.DIM}网口数{C.RST}  {n}")
    print(f"  {C.DIM}几何{C.RST}")
    for k, v in zip(P.GEOMETRY_FIELDS, geom.value):
        print(f"      {k:26s} {v}")
    # 顺带读每口链路
    if n:
        links = c.get_many([("LINK_STATUS", p, 0) for p in range(n)])
        for p, r in enumerate(links):
            st = P.fmt_value(0x52, r.value) if r.ok else r.status_name
            clr = C.GRN if (r.value and r.value[0] & 1) else C.YEL
            print(f"  {C.DIM}口{p} 链路{C.RST} {clr}{st}{C.RST}")
    return 0


def cmd_get(c: P.CfgClient, args) -> int:
    rsp = c.get(args.item, args.port, args.set_num)
    if args.json:
        print(json.dumps(rsp_to_dict(rsp), ensure_ascii=False, indent=2))
    elif args.raw:
        print(rsp.value.hex(" "))
    else:
        print_rsp(rsp)
    return 0


def cmd_set(c: P.CfgClient, args) -> int:
    rsp = c.set(args.item, args.value, args.port, args.set_num,
                precheck=not args.no_precheck)
    if args.json:
        print(json.dumps(rsp_to_dict(rsp), ensure_ascii=False, indent=2))
    else:
        if not args.json:
            print(f"{C.GRN}✓{C.RST} 写入 {rsp.item_name}"
                  f"{f' 口{rsp.port}' if rsp.item_obj and rsp.item_obj.per_port else ''}"
                  f" = {args.value}")
    return 0


def cmd_action(c: P.CfgClient, args) -> int:
    code = _resolve_action(args.name)
    rsp = c.action(code, args.port, precheck=not args.no_precheck)
    if args.json:
        print(json.dumps(rsp_to_dict(rsp), ensure_ascii=False, indent=2))
    else:
        print_rsp(rsp)
    return 0


def cmd_geom(c: P.CfgClient, args) -> int:
    rsps = c.get_many([("GEOMETRY", args.port, 0), ("GEOMETRY_MAX", args.port, 0)])
    cur, mx = rsps
    if args.json:
        print(json.dumps({
            "port": args.port,
            "geometry": dict(zip(P.GEOMETRY_FIELDS, cur.value)),
            "geometry_max": dict(zip(P.GEOMETRY_FIELDS, mx.value)),
        }, ensure_ascii=False, indent=2))
        return 0

    print(f"{C.BLD}口 {args.port} 配置边界{C.RST}")
    print(f"  {'字段':28s} {'当前':>6s} {'上限':>6s}")
    print(f"  {'-'*28} {'-'*6} {'-'*6}")
    for k, a, b in zip(P.GEOMETRY_FIELDS, cur.value, mx.value):
        same = "" if a == b else f"  {C.YEL}(已裁剪){C.RST}"
        print(f"  {k:28s} {a:>6d} {b:>6d}{same}")
    return 0


def cmd_items(c: P.CfgClient, args) -> int:
    rows = []
    for code in sorted(P.ITEMS):
        it = P.ITEMS[code]
        rows.append({
            "item": f"0x{code:02X}", "name": it.name, "width": it.width,
            "mode": it.mode, "indexed": it.indexed, "per_port": it.per_port,
            "desc": it.desc,
        })
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0
    print(f"{'ITEM':6s} {'名称':20s} {'宽':>3s} {'权限':4s} {'索引':4s} {'作用域':6s} 说明")
    print("-" * 96)
    for r in rows:
        print(f"{r['item']:6s} {r['name']:20s} {r['width']:>3d} "
              f"{r['mode'].upper():4s} {'是' if r['indexed'] else '-':4s} "
              f"{'每口' if r['per_port'] else '全局':6s} {r['desc']}")
    return 0


def cmd_dump(c: P.CfgClient, args) -> int:
    """全量读取：先拿 GEOMETRY 决定每口槽数，再一次性批量读回。"""
    n = 2
    try:
        pn = c.get("PORT_NUM")
        if pn.ok and pn.value:
            n = pn.value[0] & 0x0F
    except P.CfgError:
        pass

    geoms: Dict[int, List[int]] = {}
    for p in range(n):
        g = c.get("GEOMETRY", p)
        geoms[p] = list(g.value) if g.ok else [1] * 9

    # 每口每 item 的槽数：按 GEOMETRY 里的 *_NUM 字段反推
    # 统一走 P.slots_for（与 Web UI、tkinter GUI 同一套逻辑）
    def slots_of(item: int, port: int) -> int:
        return P.slots_for(item, geoms.get(port))

    reqs: List[Tuple[int, int, int]] = []
    for _title, codes in DUMP_GROUPS:
        for code in codes:
            it = P.ITEMS.get(code)
            if it is None or it.is_action:
                continue
            if not it.per_port:
                reqs.append((code, 0, 0))
                continue
            for p in range(n):
                cnt = slots_of(code, p) if it.indexed else 1
                for s in range(cnt):
                    reqs.append((code, p, s))

    rsps = c.get_many(reqs)

    if args.json:
        out: Dict[str, Any] = {
            "host": c.host, "port": c.port, "ports": n,
            "version": None,
            "items": [rsp_to_dict(r) for r in rsps],
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    print(f"{C.BLD}设备{C.RST} {c.host}:{c.port}   共 {n} 口")
    for title, codes in DUMP_GROUPS:
        print(f"\n{C.BLU}── {title} ──{C.RST}")
        for code in codes:
            it = P.ITEMS.get(code)
            if it is None:
                continue
            if not it.per_port:
                r = next((x for x in rsps if x.item == code), None)
                if r is not None:
                    print(f"  {it.name:20s} {P.fmt_value(code, r.value) if r.ok else r.status_name}")
                continue
            for p in range(n):
                cnt = slots_of(code, p) if it.indexed else 1
                vals = []
                for s in range(cnt):
                    r = next((x for x in rsps
                              if x.item == code and x.port == p and x.set_idx == s), None)
                    if r is None:
                        continue
                    if not r.ok:
                        # 该口没有这个槽（BAD_SET）→ 正常，静默跳过
                        if r.status != P.ST_BAD_SET:
                            vals.append(r.status_name)
                        continue
                    v = P.fmt_value(code, r.value)
                    vals.append(v if cnt == 1 else f"[{s}] {v}")
                if vals:
                    print(f"  {it.name:20s} 口{p}  " + "   ".join(vals))
    return 0


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    # 子命令通用的开关：default=SUPPRESS 保证「子命令未显式给出时不覆盖全局已设值」，
    # 否则子命令的默认值会把主 parser 解析结果冲掉（argparse 的经典坑）。
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS,
                        help="以 JSON 输出")
    common.add_argument("-v", "--verbose", action="store_true", default=argparse.SUPPRESS,
                        help="打印收发细节")
    common.add_argument("--no-precheck", action="store_true", default=argparse.SUPPRESS,
                        help="跳过本地预检，直接发给设备")

    ap = argparse.ArgumentParser(
        prog="cfgctl",
        description="Centenarian 配置通道命令行上位机（Windows/Linux 通用）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n"
               "  python cfgctl.py -H 192.168.1.9 probe\n"
               "  python cfgctl.py -H 192.168.1.9 get IPV4_LOCAL_IP\n"
               "  python cfgctl.py -H 192.168.1.9 set IPV4_LOCAL_IP 192.168.1.100\n"
               "  python cfgctl.py -H 192.168.1.9 action stat-clear --port 1\n"
               "  python cfgctl.py -H 192.168.1.9 dump --json > cfg.json\n")
    ap.add_argument("-H", "--host", default=None,
                    help="设备 IP（也可用环境变量 CFG_HOST）")
    # 注意：这里叫 --udp-port，避免与子命令的 --port（网口号）重名
    ap.add_argument("-P", "--udp-port", type=lambda s: int(s, 0),
                    default=P.DEFAULT_UDP_PORT,
                    help="设备 UDP 端口，默认 0x%04X (%d)" % (P.DEFAULT_UDP_PORT, P.DEFAULT_UDP_PORT))
    ap.add_argument("--local-ip", default=None, help="本地绑定 IP（多网卡时指定）")
    ap.add_argument("--timeout", type=float, default=0.2, help="单次超时秒数（默认 0.2）")
    ap.add_argument("--retries", type=int, default=3, help="重试次数（默认 3）")
    ap.add_argument("--json", action="store_true", help="以 JSON 输出")
    ap.add_argument("--no-precheck", action="store_true",
                    help="跳过本地预检，直接发给设备（用于验证设备端状态码）")
    ap.add_argument("-v", "--verbose", action="store_true", help="打印收发细节")

    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("probe", parents=[common],
                   help="探测设备：版本 / 几何 / 链路").set_defaults(fn=cmd_probe)

    g = sub.add_parser("get", parents=[common], help="读一项")
    g.add_argument("item", help="ITEM 名称或编号，如 IPV4_LOCAL_IP / 0x00 / 51")
    g.add_argument("--port", type=int, default=0, help="网口号（默认 0）")
    g.add_argument("--set", dest="set_num", type=int, default=0, help="档号（默认 0）")
    g.add_argument("--raw", action="store_true", help="只打印原始字节（hex）")
    g.set_defaults(fn=cmd_get)

    s = sub.add_parser("set", parents=[common], help="写一项")
    s.add_argument("item", help="ITEM 名称或编号")
    s.add_argument("value", help="值：IP / MAC / 数字 / 区间(2-8)")
    s.add_argument("--port", type=int, default=0, help="网口号（默认 0）")
    s.add_argument("--set", dest="set_num", type=int, default=0, help="档号（默认 0）")
    s.set_defaults(fn=cmd_set)

    a = sub.add_parser("action", parents=[common], help="触发动作（不重试）")
    a.add_argument("name", help="reset / cache-clear / pend-clear / stat-clear"
                               "（也可直接用 ITEM 名或编号）")
    a.add_argument("--port", type=int, default=0, help="网口号（默认 0）")
    a.set_defaults(fn=cmd_action)

    gm = sub.add_parser("geom", parents=[common], help="打印配置边界")
    gm.add_argument("--port", type=int, default=0, help="网口号（默认 0）")
    gm.set_defaults(fn=cmd_geom)

    sub.add_parser("items", parents=[common],
                   help="列出所有 ITEM").set_defaults(fn=cmd_items)
    sub.add_parser("dump", parents=[common],
                   help="全量读取").set_defaults(fn=cmd_dump)
    return ap


def main(argv: Optional[List[str]] = None) -> int:
    _setup_stdout()
    args = build_parser().parse_args(argv)

    # items 不需要连设备
    if args.cmd == "items":
        return cmd_items(None, args)  # type: ignore[arg-type]

    client = make_client(args)
    try:
        with client:
            return args.fn(client, args)
    except P.CfgError as e:
        print(f"{C.RED}设备拒绝{C.RST} {e}", file=sys.stderr)
        return 1
    except P.CfgTimeout as e:
        print(f"{C.YEL}超时{C.RST} {e}", file=sys.stderr)
        return 2
    except ValueError as e:
        print(f"{C.RED}参数错误{C.RST} {e}", file=sys.stderr)
        return 3
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
