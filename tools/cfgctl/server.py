#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
server.py — Centenarian 配置上位机 · Web 后端

浏览器发不了裸 UDP，所以由这个进程做桥：
    python server.py                       # 默认 127.0.0.1:8770
    python server.py --host 0.0.0.0        # 允许局域网访问
    python server.py --open                # 启动后自动开浏览器
    python server.py --vdev                # 同时起一个虚拟设备（无硬件调试用）

**纯标准库实现**，不需要 pip install 任何东西。

API
----
    GET  /                      → 前端页面
    GET  /api/meta              → ITEM 表 / 状态码 / 几何字段名等静态元数据
    POST /api/connect           {host, port, timeout} → 建连并探测
    POST /api/disconnect        → 断开
    GET  /api/state             → 当前连接状态 + 已读回的配置快照
    POST /api/read              {items:[{item,port,set}]} → 批量读
    POST /api/write             {item,port,set,value}    → 写
    POST /api/action            {item,port}              → 触发动作
    POST /api/dump              → 全量读回（自动按 GEOMETRY 展开档数）
    POST /api/raw               {hex}                    → 原始帧注入（调试用）
    GET  /api/events            → SSE 实时日志流

线程模型
--------
UDP 通道同一时刻只能有一个在途事务（应答靠 SEQ 四元组匹配，交叉会乱），
所以所有设备访问都走一把全局锁，HTTP 线程排队执行。

协议细节见 cfgproto.py 与 Docs/05-config-command.md。
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import socket
import sys
import threading
import time
import traceback
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import cfgproto as P                                          # noqa: E402

STATIC_DIR = os.path.join(HERE, "static")

# ============================================================================
# 设备会话
# ============================================================================

class Session:
    """
    与设备的一次会话。

    设备访问全部经 ``lock`` 串行化 —— UDP 事务不能交叉。
    """

    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.client: Optional[P.CfgClient] = None
        self.host: Optional[str] = None
        self.port: Optional[int] = None
        self.port_num: int = 0                 # 网口数（读自 0x72）
        self.geom: Dict[int, List[int]] = {}   # 每口的 GEOMETRY 原始字节
        self.snapshot: Dict[str, Any] = {}      # 最近一次读回的配置快照
        self.connected_at: Optional[float] = None

    # ---------- 状态 ----------
    @property
    def connected(self) -> bool:
        return self.client is not None

    def state(self) -> Dict[str, Any]:
        return {
            "connected": self.connected,
            "host": self.host,
            "port": self.port,
            "port_num": self.port_num,
            "connected_at": self.connected_at,
            "geom": {str(k): v for k, v in self.geom.items()},
            "snapshot": self.snapshot,
        }

    # ---------- 连接 ----------
    def connect(self, host: str, port: int, timeout: float,
                local_ip: Optional[str] = None) -> Dict[str, Any]:
        with self.lock:
            self.disconnect_locked()
            client = P.CfgClient(host, port, local_ip=local_ip,
                                 timeout=timeout, retries=3)
            client.open()
            self.client = client
            self.host = host
            self.port = port
            self.connected_at = time.time()
            try:
                info = self._probe_locked()
            except Exception:
                self.disconnect_locked()
                raise
            return info

    def disconnect_locked(self) -> None:
        if self.client is not None:
            try:
                self.client.close()
            except Exception:
                pass
        self.client = None
        self.host = None
        self.port = None
        self.port_num = 0
        self.geom = {}
        self.snapshot = {}
        self.connected_at = None

    def disconnect(self) -> None:
        with self.lock:
            self.disconnect_locked()

    # ---------- 探测 ----------
    def _probe_locked(self) -> Dict[str, Any]:
        """读回版本 / 口数 / 每口几何，作为连接成功的凭据。"""
        assert self.client is not None
        c = self.client

        version = c.get("VERSION")
        pn = c.get("PORT_NUM")
        n = (pn.value[0] & 0x0F) if pn.ok and pn.value else 0
        self.port_num = n

        self.geom = {}
        if n:
            for r in c.get_many([("GEOMETRY", p, 0) for p in range(n)]):
                if r.ok:
                    self.geom[r.port] = list(r.value)

        return {
            "version": int.from_bytes(version.value, "little") if version.ok else None,
            "version_text": P.fmt_value(0x51, version.value) if version.ok else None,
            "port_num": n,
            "geom": {str(k): v for k, v in self.geom.items()},
        }

    # ---------- 读 ----------
    def read(self, requests: List[Tuple[Any, int, int]]) -> List[P.Rsp]:
        """批量读。requests = [(item, port, set), ...]"""
        with self.lock:
            if self.client is None:
                raise RuntimeError("尚未连接设备")
            rsps = self.client.get_many(requests)
            self._absorb(rsps)
            return rsps

    def _absorb(self, rsps: List[P.Rsp]) -> None:
        """把读回结果并入快照，供前端判断「哪些项还没读过」。"""
        for r in rsps:
            if not r.ok:
                continue
            key = f"{r.item}:{r.port}:{r.set_idx}"
            self.snapshot[key] = {
                "item": r.item,
                "port": r.port,
                "set": r.set_idx,
                "raw": r.value.hex(),
                "text": P.to_edit_text(r.item, r.value) if r.value else "",
                "display": P.fmt_value(r.item, r.value) if r.value else "",
            }

    # ---------- 写 ----------
    def write(self, item: Any, value: Any, port: int, set_idx: int,
              precheck: bool = True) -> P.Rsp:
        with self.lock:
            if self.client is None:
                raise RuntimeError("尚未连接设备")
            return self.client.set(item, value, port, set_idx, precheck=precheck)

    # ---------- 动作 ----------
    def action(self, item: Any, port: int, precheck: bool = True) -> P.Rsp:
        with self.lock:
            if self.client is None:
                raise RuntimeError("尚未连接设备")
            return self.client.action(item, port, precheck=precheck)

    # ---------- 全量读回 ----------
    def dump(self) -> Dict[str, Any]:
        """
        按 GEOMETRY 展开每个 ITEM 的档数，一次往返读回全部。

        返回 {rows: [{item, port, set, ok, status, raw, text, display}]}
        """
        with self.lock:
            if self.client is None:
                raise RuntimeError("尚未连接设备")
            c = self.client

            if not self.port_num:
                pn = c.get("PORT_NUM")
                self.port_num = (pn.value[0] & 0x0F) if pn.ok and pn.value else 0
            n = self.port_num or 1

            if not self.geom:
                for r in c.get_many([("GEOMETRY", p, 0) for p in range(n)]):
                    if r.ok:
                        self.geom[r.port] = list(r.value)

            reqs: List[Tuple[Any, int, int]] = []
            for code in sorted(P.ITEMS):
                it = P.ITEMS[code]
                if it.is_action:
                    continue
                if not it.per_port:
                    reqs.append((code, 0, 0))
                    continue
                for p in range(n):
                    g = self.geom.get(p)
                    cnt = P.slots_for(code, g) if it.indexed else 1
                    for s in range(cnt):
                        reqs.append((code, p, s))

            rsps = c.get_many(reqs)
            self._absorb(rsps)

            rows: List[Dict[str, Any]] = []
            for r in rsps:
                rows.append({
                    "item": r.item,
                    "item_name": r.item_name,
                    "port": r.port,
                    "set": r.set_idx,
                    "ok": r.ok,
                    "status": r.status_name,
                    "status_code": r.status,
                    "raw": r.value.hex(),
                    "text": P.to_edit_text(r.item, r.value) if r.value else "",
                    "display": P.fmt_value(r.item, r.value) if r.value else "",
                })
            return {"ports": n, "rows": rows}

    # ---------- 原始帧注入 ----------
    def raw(self, hexstr: str) -> Dict[str, Any]:
        """发一段任意字节，等一次回包并解析。调试用。"""
        with self.lock:
            if self.client is None:
                raise RuntimeError("尚未连接设备")
            c = self.client
            try:
                payload = bytes.fromhex(hexstr.replace(" ", ""))
            except ValueError as exc:
                raise ValueError(f"十六进制串非法：{exc}") from None

            assert c._sock is not None
            c._sock.sendto(payload, (c.host, c.port))
            c._sock.settimeout(1.0)
            try:
                data, _addr = c._sock.recvfrom(65535)
            except socket.timeout:
                return {"tx": payload.hex(" "), "rx": None,
                        "rsps": [], "error": "1 秒内无应答"}

            rsps = [{
                "op": f"0x{r.op:02X}",
                "seq": r.seq,
                "status": r.status_name,
                "status_code": r.status,
                "item": r.item,
                "item_name": r.item_name,
                "port": r.port,
                "set": r.set_idx,
                "value": r.value.hex(" ") if r.value else "",
                "display": P.fmt_value(r.item, r.value) if r.value else "",
            } for r in P.parse_rsps(data)]
            return {"tx": payload.hex(" "), "rx": data.hex(" "), "rsps": rsps}


SESSION = Session()

# ============================================================================
# 日志总线（SSE）
# ============================================================================

class LogBus:
    """把后端的收发日志广播给所有 SSE 订阅者。"""

    def __init__(self, history: int = 500) -> None:
        self._lock = threading.Lock()
        self._subs: List["queue.Queue[str]"] = []
        self._history: List[str] = []
        self._history_max = history
        self._seq = 0

    def publish(self, msg: str) -> None:
        with self._lock:
            self._seq += 1
            line = f"[{time.strftime('%H:%M:%S')}] {msg}"
            self._history.append(line)
            if len(self._history) > self._history_max:
                del self._history[:len(self._history) - self._history_max]
            subs = list(self._subs)
        for q in subs:
            try:
                q.put_nowait(line)
            except queue.Full:
                pass

    def subscribe(self) -> "queue.Queue[str]":
        q: "queue.Queue[str]" = queue.Queue(maxsize=1000)
        with self._lock:
            self._subs.append(q)
        return q

    def unsubscribe(self, q: "queue.Queue[str]") -> None:
        with self._lock:
            if q in self._subs:
                self._subs.remove(q)

    def history(self) -> List[str]:
        with self._lock:
            return list(self._history)


LOG = LogBus()

# 把客户端的收发细节接到日志总线
_orig_emit = P.CfgClient._emit


def _emit(self: P.CfgClient, msg: str) -> None:
    LOG.publish(msg)
    _orig_emit(self, msg)


P.CfgClient._emit = _emit       # type: ignore[method-assign]


# ============================================================================
# HTTP 处理
# ============================================================================

class Handler(BaseHTTPRequestHandler):
    server_version = "CentenarianCfg/2.0"
    protocol_version = "HTTP/1.1"

    # ---------- 工具 ----------
    def _json(self, obj: Any, code: int = 200) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _err(self, msg: str, code: int = 400, **extra: Any) -> None:
        obj = {"ok": False, "error": msg}
        obj.update(extra)
        self._json(obj, code)

    def _body(self) -> Dict[str, Any]:
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise ValueError(f"请求体不是合法 JSON：{exc}") from None

    def log_message(self, fmt: str, *args: Any) -> None:
        """屏蔽 http.server 的默认 stderr 噪声，改为进日志总线。"""
        if args and str(args[1] if len(args) > 1 else "").startswith(("4", "5")):
            LOG.publish("HTTP " + (fmt % args))

    def handle_one_request(self) -> None:
        """
        包一层，吞掉浏览器主动断开造成的异常。

        SSE 长连接在页面刷新/关闭时会被浏览器直接 RST，
        BaseHTTPRequestHandler 默认会往 stderr 打一整页 traceback ——
        对一个长期挂着的工具来说这是噪声。
        """
        try:
            super().handle_one_request()
        except (ConnectionResetError, ConnectionAbortedError,
                BrokenPipeError, TimeoutError):
            self.close_connection = True

    # ---------- 路由 ----------
    def do_GET(self) -> None:
        path = urlparse(self.path).path
        try:
            if path == "/api/meta":
                return self._json(self._meta())
            if path == "/api/state":
                return self._json({"ok": True, **SESSION.state()})
            if path == "/api/events":
                return self._sse()
            if path == "/api/logs":
                return self._json({"ok": True, "lines": LOG.history()})
            return self._static(path)
        except Exception as exc:                          # noqa: BLE001
            traceback.print_exc()
            self._err(f"{type(exc).__name__}: {exc}", 500)

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        try:
            body = self._body()
        except ValueError as exc:
            return self._err(str(exc), 400)

        try:
            if path == "/api/connect":
                return self._connect(body)
            if path == "/api/disconnect":
                SESSION.disconnect()
                return self._json({"ok": True})
            if path == "/api/read":
                return self._read(body)
            if path == "/api/write":
                return self._write(body)
            if path == "/api/action":
                return self._action(body)
            if path == "/api/dump":
                return self._json({"ok": True, **SESSION.dump()})
            if path == "/api/raw":
                return self._json({"ok": True, **SESSION.raw(body.get("hex", ""))})
            return self._err(f"未知接口 {path}", 404)
        except P.CfgError as exc:
            return self._err(f"设备拒绝：{exc.rsp.status_name}", 200,
                             status_code=exc.rsp.status,
                             status_name=exc.rsp.status_name)
        except P.CfgTimeout as exc:
            return self._err(f"超时：{exc}", 504)
        except (ValueError, RuntimeError) as exc:
            return self._err(str(exc), 400)
        except Exception as exc:                          # noqa: BLE001
            traceback.print_exc()
            return self._err(f"{type(exc).__name__}: {exc}", 500)

    # ---------- 各接口实现 ----------
    def _meta(self) -> Dict[str, Any]:
        return {
            "ok": True,
            "items": P.item_meta(),
            "groups": [{"key": g, "label": P.GROUP_LABEL[g]} for g in P.GROUP_ORDER],
            "status_names": {str(k): v for k, v in P.STATUS_NAME.items()},
            "geometry_fields": P.GEOMETRY_FIELDS,
            "geometry_semantics": P.geometry_semantics(),
            "stat_bits": {str(k): v for k, v in P.stat_bits_meta().items()},
            "readonly_hints": {str(k): v for k, v in P.readonly_hints().items()},
            "tx_lanes": P.tx_lane_meta(),
            "arp_stat_bits": [{"bit": b.bit, "short": b.short, "desc": b.desc,
                               "src": b.src, "level": b.level}
                              for b in P.ARP_STAT_BITS],
            "icmp_stat_bits": [{"bit": b.bit, "short": b.short, "desc": b.desc,
                                "src": b.src, "level": b.level}
                               for b in P.ICMP_STAT_BITS],
            "default_udp_port": P.DEFAULT_UDP_PORT,
            "max_value_bytes": P.MAX_VALUE_BYTES,
        }

    def _connect(self, body: Dict[str, Any]) -> None:
        host = str(body.get("host", "")).strip()
        if not host:
            return self._err("缺少设备 IP", 400)
        try:
            port = int(body.get("port", P.DEFAULT_UDP_PORT))
            timeout = float(body.get("timeout", 0.2))
        except (TypeError, ValueError):
            return self._err("端口需为整数、超时需为小数", 400)
        local_ip = body.get("local_ip") or None

        try:
            info = SESSION.connect(host, port, timeout, local_ip)
        except P.CfgTimeout:
            return self._err(
                f"连接 {host}:{port} 超时。\n"
                "请确认：① 目的 IP 是设备绑定口 set0 的本机 IP；"
                "② UDP 端口与 CMD_UDP_PORT 当前值一致；"
                "③ 本机与设备在同一网段。", 504)
        except OSError as exc:
            return self._err(f"套接字错误：{exc}", 400)

        LOG.publish(f"=== 已连接 {host}:{port} ===")
        return self._json({"ok": True, "host": host, "port": port, **info})

    def _read(self, body: Dict[str, Any]) -> None:
        reqs = body.get("items") or []
        if not isinstance(reqs, list):
            return self._err("items 必须是数组", 400)
        parsed: List[Tuple[Any, int, int]] = []
        for it in reqs:
            try:
                parsed.append((it.get("item"),
                               int(it.get("port", 0)),
                               int(it.get("set", 0))))
            except (TypeError, ValueError) as exc:
                return self._err(f"非法请求项：{exc}", 400)

        rsps = SESSION.read(parsed)
        rows = []
        for r in rsps:
            rows.append({
                "item": r.item,
                "item_name": r.item_name,
                "port": r.port,
                "set": r.set_idx,
                "ok": r.ok,
                "status": r.status_name,
                "status_code": r.status,
                "raw": r.value.hex(),
                "text": P.to_edit_text(r.item, r.value) if r.value else "",
                "display": P.fmt_value(r.item, r.value) if r.value else "",
            })
        return self._json({"ok": True, "rows": rows})

    def _write(self, body: Dict[str, Any]) -> None:
        item = body.get("item")
        value = body.get("value", "")
        port = int(body.get("port", 0))
        set_idx = int(body.get("set", 0))
        precheck = bool(body.get("precheck", True))

        rsp = SESSION.write(item, value, port, set_idx, precheck)
        return self._json({
            "ok": True,
            "item": rsp.item,
            "item_name": rsp.item_name,
            "port": rsp.port,
            "set": rsp.set_idx,
            "status": rsp.status_name,
            "display": P.fmt_value(rsp.item, rsp.value) if rsp.value else "",
        })

    def _action(self, body: Dict[str, Any]) -> None:
        item = body.get("item")
        port = int(body.get("port", 0))
        precheck = bool(body.get("precheck", True))
        rsp = SESSION.action(item, port, precheck)
        return self._json({
            "ok": True,
            "item": rsp.item,
            "item_name": rsp.item_name,
            "port": rsp.port,
            "status": rsp.status_name,
        })

    # ---------- SSE ----------
    def _sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        q = LOG.subscribe()
        try:
            # 先补历史
            for line in LOG.history():
                self.wfile.write(f"data: {line}\n\n".encode("utf-8"))
            self.wfile.flush()
            while True:
                try:
                    line = q.get(timeout=15.0)
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")      # 心跳，防代理断连
                    self.wfile.flush()
                    continue
                self.wfile.write(f"data: {line}\n\n".encode("utf-8"))
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            LOG.unsubscribe(q)

    # ---------- 静态资源 ----------
    def _static(self, path: str) -> None:
        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        full = os.path.normpath(os.path.join(STATIC_DIR, rel))
        if not full.startswith(os.path.normpath(STATIC_DIR)):
            return self._err("非法路径", 403)
        if not os.path.isfile(full):
            return self._err(f"找不到 {path}", 404)

        ctype = {
            ".html": "text/html; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".js": "application/javascript; charset=utf-8",
            ".svg": "image/svg+xml",
            ".ico": "image/x-icon",
        }.get(os.path.splitext(full)[1], "application/octet-stream")

        with open(full, "rb") as fh:
            body = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


# ============================================================================
# 入口
# ============================================================================

def main(argv: Optional[List[str]] = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            # line_buffering：后台运行时 stdout 是块缓冲的，启动信息会卡在缓冲区里
            stream.reconfigure(encoding="utf-8", errors="replace",  # type: ignore[attr-defined]
                               line_buffering=True)
        except Exception:
            pass

    ap = argparse.ArgumentParser(description="Centenarian 配置上位机 · Web 后端")
    ap.add_argument("--host", default="127.0.0.1", help="监听地址（默认仅本机）")
    ap.add_argument("--port", type=int, default=8770, help="监听端口（默认 8770）")
    ap.add_argument("--open", action="store_true", help="启动后打开浏览器")
    ap.add_argument("--vdev", action="store_true",
                    help="同时启动虚拟设备（127.0.0.1:0xC0DE），用于无硬件调试")
    ap.add_argument("--vdev-port", type=lambda s: int(s, 0),
                    default=P.DEFAULT_UDP_PORT, help="虚拟设备端口")
    ap.add_argument("--arp-stat", type=lambda s: int(s, 0), default=0,
                    help="虚拟设备的初始 ARP_STAT 位图（注入异常场景）")
    ap.add_argument("--icmp-stat", type=lambda s: int(s, 0), default=0,
                    help="虚拟设备的初始 ICMP_STAT 位图")
    args = ap.parse_args(argv)

    vdev = None
    if args.vdev:
        from vdev import VirtualDevice
        try:
            vdev = VirtualDevice("127.0.0.1", args.vdev_port, num_ports=2,
                                 shuffle=False, verbose=False,
                                 arp_stat=args.arp_stat,
                                 icmp_stat=args.icmp_stat).start()
        except OSError as exc:
            print(f"[vdev] 启动失败：{exc}", file=sys.stderr)
            return 1
        print(f"[vdev] 虚拟设备已启动，可在界面上连接 127.0.0.1:{args.vdev_port}")

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.daemon_threads = True
    url = f"http://{args.host if args.host != '0.0.0.0' else '127.0.0.1'}:{args.port}/"
    print(f"[cfgweb] 上位机已启动：{url}")
    print("[cfgweb] Ctrl+C 退出")
    if args.open:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[cfgweb] 已退出")
    finally:
        httpd.server_close()
        if vdev is not None:
            vdev.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
