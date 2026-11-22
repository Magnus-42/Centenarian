"""Local HTTP bridge from the configuration console to the FPGA UDP port."""

import argparse
import ipaddress
import json
import re
import sys
import threading
import time
import traceback
import webbrowser
from dataclasses import asdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from audit import AuditLog, SOURCES, default_directory, event, identifier, timestamp
from conflicts import check_conflicts, read_config, related_items
from demo import DemoDevice
from protocol import (
    EXEC, GET, ITEMS, OK, PROFILES, SET, STATUS, TABLES, Client,
    big_endian_hex, decode_value, encode_value, is_management_address, unsigned,
)


ROOT = Path(__file__).resolve().parent
ASSETS = {"/": ("index.html", "text/html"), "/style.css": ("style.css", "text/css"),
          "/app.js": ("app.js", "text/javascript"), "/audit.js": ("audit.js", "text/javascript")}
DEVICE_POST = {"/api/probe", "/api/probe-tables", "/api/read", "/api/check", "/api/write", "/api/action", "/api/heartbeat"}
SUMMARY = (0x10, 0x11, 0x12, 0x13, 0x14, 0x26, 0x27, 0x2B)
READ_LIMIT = sum(254 if item.table else 1 for item in ITEMS.values() if item.access != "exec")


def endpoint(host, port):
    address = ipaddress.IPv4Address(host.strip())
    if not is_management_address(address):
        raise ValueError("请输入设备的单播 IPv4 地址")
    return str(address), unsigned(str(port).strip(), 65535, 1)


def status_text(reply):
    if reply is None:
        return "TIMEOUT"
    code = reply[0]
    return STATUS[code] if code < len(STATUS) else f"STATUS_0x{code:02X}"


def checked_item(row, access):
    code, index = row["code"], row.get("index", 0)
    if type(code) is not int or code not in ITEMS:
        raise ValueError("未知配置项")
    item = ITEMS[code]
    if type(index) is not int or not 0 <= index <= (253 if item.table else 0):
        raise ValueError("该配置项的索引无效")
    if item.access not in access:
        raise ValueError("该配置项不支持所请求的操作")
    return item, index


def read_row(client, item, index):
    reply = client.exchange(GET, item, index)
    row = {"code": item.code, "index": index, "status": status_text(reply)}
    if reply is not None and reply[0] == OK:
        raw = reply[1]
        row.update(value=decode_value(item, raw), bigEndian=big_endian_hex(item, raw))
        error = client.value_error(item, raw)
        if error:
            row["validation"] = {"errors": [error], "warnings": []}
    return row


class Bridge(ThreadingHTTPServer):
    def __init__(self, port, demo, pending_width, priority_width, log_dir=None):
        super().__init__(("127.0.0.1", port), Handler)
        self.authority = f"127.0.0.1:{self.server_port}"
        self.origin = f"http://{self.authority}"
        self.demo = DemoDevice() if demo else None
        self.pending_width = pending_width
        self.priority_width = priority_width
        self.lock = threading.Lock()
        self.audit = AuditLog(log_dir if log_dir is not None else default_directory(demo))
        self.audit.append(event("server", "bridge.started", details={"mode": "demo" if demo else "hardware",
                               "origin": self.origin, "pendingWidth": pending_width, "priorityWidth": priority_width,
                               "protocolStamp": "19 31"}))

    def server_close(self):
        if self.demo:
            self.demo.sock.close()
        super().server_close()

    def meta(self):
        profiles = {"A": PROFILES["A"]} if self.demo else PROFILES
        return {"items": [asdict(item) for item in ITEMS.values()], "profiles": profiles,
                "demo": bool(self.demo), "pendingMax": str((1 << self.pending_width) - 1),
                "priorityMax": (1 << self.priority_width) - 1,
                "readLimit": READ_LIMIT,
                "conflictItems": [code for code in ITEMS if related_items(code)[0]]}

    def client(self, target, trace, demo=None):
        return Client(target, trace, demo, pending_width=self.pending_width, priority_width=self.priority_width)

    def command(self, path, body, trace=None):
        target = endpoint(body["host"], body["port"])
        if trace is None:
            trace = []
        demo = self.demo.address if self.demo else None
        peer = body.get("peer")
        block_cross_port = body.get("blockCrossPort", True)
        if type(block_cross_port) is not bool:
            raise ValueError("跨口重复拦截设置无效。")
        with self.lock, self.client(target, trace, demo) as client:
            if self.demo and self.demo.endpoint != target:
                host, port = self.demo.endpoint
                raise ValueError(f"虚拟设备当前的管理端点为 {host}:{port}。")
            if path == "/api/heartbeat":
                return {"rows": [read_row(client, ITEMS[0x13], 0)], "trace": trace}
            if path == "/api/probe":
                link = read_row(client, ITEMS[0x13], 0)
                if link["status"] != "OK":
                    return {"error": f"读取物理链路失败 · {link['status']}", "trace": trace}
                rows = [link] + [read_row(client, ITEMS[code], 0) for code in SUMMARY if code != 0x13]
                counts = {name: client.count(item) for name, item in TABLES.items()}
                warnings = self.audit_rows(client, target, rows, peer, block_cross_port)
                return {"rows": rows, "counts": counts, "validationWarnings": warnings, "trace": trace}
            if path == "/api/probe-tables":
                tables = body["tables"]
                if (not isinstance(tables, list) or not 1 <= len(tables) <= len(TABLES)
                        or any(not isinstance(name, str) or name not in TABLES for name in tables)):
                    raise ValueError("请选择需要重新探测的配置表")
                counts = {name: client.count(TABLES[name]) for name in dict.fromkeys(tables)}
                return {"counts": counts, "trace": trace}
            if path == "/api/read":
                entries = body["items"]
                if not isinstance(entries, list) or not 1 <= len(entries) <= READ_LIMIT:
                    raise ValueError("读取列表大小无效")
                validated = [checked_item(row, ("ro", "rw")) for row in entries]
                rows = [read_row(client, item, index) for item, index in validated]
                warnings = self.audit_rows(client, target, rows, peer, block_cross_port)
                return {"rows": rows, "validationWarnings": warnings, "trace": trace}
            if path == "/api/action":
                item, index = checked_item(body, ("exec",))
                return {"status": status_text(client.exchange(EXEC, item, index)), "trace": trace}
            item, index = checked_item(body, ("rw",))
            value = encode_value(item, body["value"], self.pending_width, self.priority_width)
            normalized = decode_value(item, value)
            review = self.review(client, target, item.code, index, normalized, peer, block_cross_port)
            if path == "/api/check" or review["errors"]:
                return {"status": "CONFLICT" if review["errors"] else "OK", "review": review, "trace": trace}
            result = self.write(client, target, demo, item, index, value, normalized, trace, peer, block_cross_port)
            result["review"] = review
            return result

    def read_peer(self, client, target, codes, requested_peer):
        label = "另一网口"
        if not codes:
            return {}, label, []
        if self.demo:
            return {}, label, ["虚拟设备仅模拟 A 口，跨口冲突未检查。"]
        if requested_peer:
            try:
                peer = endpoint(requested_peer["host"], requested_peer["port"])
            except (AttributeError, KeyError, TypeError, ValueError):
                return {}, label, ["另一网口的管理端点无效，跨口冲突待核对。"]
        elif target in PROFILES.values():
            peer = next(address for address in PROFILES.values() if address != target)
        else:
            return {}, label, ["另一网口的管理端点未知，可在「设备连接」中设置。"]
        if peer == target:
            return {}, label, ["另一网口的端点与当前设备相同，跨口冲突待核对。"]
        name = next((f"{name} 口，" for name, address in PROFILES.items() if address == peer), "")
        label = f"另一网口（{name}{peer[0]}:{peer[1]}）"
        with self.client(peer, client.trace) as other:
            reply = other.exchange(GET, ITEMS[0x11])
            if not reply or reply[0] != OK or decode_value(ITEMS[0x11], reply[1]) != peer[0]:
                return {}, label, [f"未能读取{label}，跨口冲突待核对。"]
            known = {(0x11, 0): peer[0]} if 0x11 in codes else {}
            values, complete = read_config(other, codes, known)
        return values, label, [] if complete else [f"{label}的部分配置未能读取，跨口冲突检查不完整。"]

    def audit_rows(self, client, target, rows, requested_peer, block_cross_port):
        readable = [row for row in rows if row["status"] == "OK"]
        known = {(row["code"], row["index"]): row["value"] for row in readable}
        checks = {code: related_items(code) for code, _ in known}
        local_codes = sorted({dependency for local, _ in checks.values() for dependency in local})
        peer_codes = sorted({dependency for _, peer in checks.values() for dependency in peer})
        if not local_codes:
            return []
        current, complete = read_config(client, local_codes, known)
        peer, label, coverage = self.read_peer(client, target, peer_codes, requested_peer)
        if not complete:
            coverage.append("本口有配置项未能读取，冲突检查不完整。")
        for row in readable:
            code = row["code"]
            if not checks[code][0]:
                continue
            errors, warnings = check_conflicts(code, row["index"], row["value"], current, peer, label,
                                               audit=True, block_cross_port=block_cross_port)
            if errors or warnings:
                validation = row.setdefault("validation", {"errors": [], "warnings": []})
                validation["errors"].extend(errors)
                validation["warnings"].extend(warnings)
        return coverage

    def review(self, client, target, code, index, value, requested_peer, block_cross_port):
        local_codes, peer_codes = related_items(code)
        if not local_codes:
            return {"errors": [], "warnings": []}

        current, local_complete = read_config(client, local_codes)
        if current.get((code, index)) == value:
            return {"errors": [], "warnings": []}
        peer_values, peer_label, coverage = self.read_peer(client, target, peer_codes, requested_peer)
        warnings = [] if local_complete else ["本口有配置项未能读取，冲突检查不完整。"]
        errors, issues = check_conflicts(code, index, value, current, peer_values, peer_label,
                                         block_cross_port=block_cross_port)
        return {"errors": errors, "warnings": [*issues, *warnings, *coverage]}

    def write(self, client, target, demo, item, index, value, normalized, trace, peer, block_cross_port):
        next_target = target
        if item.code == 0x11:
            next_target = endpoint(normalized, target[1])
        elif item.code == 0x12:
            next_target = target[0], int(normalized)

        identity = None
        if next_target != target:
            identity = client.exchange(GET, ITEMS[0x10])
            if identity is None or identity[0] != OK:
                return {"error": "无法读取当前设备的管理 MAC，写入尚未发送。", "trace": trace}

        response = client.exchange(SET, item, index, value, next_target)
        result = {"status": status_text(response), "nextTarget": next_target, "trace": trace}
        if identity is not None:
            result["expectedMac"] = decode_value(ITEMS[0x10], identity[1])
        if response is not None and response[0] != OK:
            return result
        # A management change can legitimately lose the SET acknowledgment.
        # Only follow the new endpoint if readback comes from the same management MAC.
        with self.client(next_target, trace, demo) as reader:
            readback = read_row(reader, item, index)
            if identity is not None:
                actual = reader.exchange(GET, ITEMS[0x10])
                if actual is None or actual[0] != OK:
                    result["verificationError"] = "新端点的管理 MAC 读取失败。"
                    return result
                if actual != identity:
                    result["verificationError"] = "新端点应答的管理 MAC 与原设备不同。"
                    return result
            result["validationWarnings"] = self.audit_rows(reader, next_target, [readback], peer, block_cross_port)
        result["readback"] = readback
        result["verified"] = readback.get("value") == normalized
        return result


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def send_content(self, data, mime, status=200, attachment=None):
        self.send_response(status)
        self.send_header("Content-Type", mime + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if attachment:
            self.send_header("Content-Disposition", f'attachment; filename="{attachment}"')
        self.send_header("Content-Security-Policy", "default-src 'self'; frame-ancestors 'self'; object-src 'none'")
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, body, status=200):
        self.send_content(json.dumps(body, ensure_ascii=False).encode("utf-8"), "application/json", status)

    def valid_origin(self):
        return (self.headers.get("Host") == self.server.authority and
                self.headers.get("Origin", self.server.origin) == self.server.origin and
                self.headers.get("Sec-Fetch-Site", "none") in ("none", "same-origin"))

    def do_GET(self):
        url = urlsplit(self.path)
        if self.headers.get("Host") != self.server.authority:
            self.send_json({"error": "请通过服务启动时打印的本机地址打开网页"}, 403)
        elif url.path.startswith("/api/audit/") and self.valid_origin():
            try:
                if url.path == "/api/audit/settings":
                    self.send_json(self.server.audit.settings())
                elif url.path == "/api/audit/events":
                    query = parse_qs(url.query)
                    source = query.get("source", [""])[0]
                    if source and source not in SOURCES:
                        raise ValueError("日志来源无效。")
                    self.send_json(self.server.audit.entries(source, query.get("operation", [""])[0],
                                                              query.get("before", [""])[0]))
                elif url.path == "/api/audit/download":
                    self.send_content(self.server.audit.snapshot(), "application/x-ndjson", attachment="centenarian-operations.jsonl")
                else:
                    self.send_json({"error": "接口不存在"}, 404)
            except (ValueError, OSError) as error:
                self.send_json({"error": f"无法读取操作日志 · {error}"}, 500)
        elif self.path == "/api/meta":
            self.send_json(self.server.meta())
        elif self.path in ASSETS:
            name, mime = ASSETS[self.path]
            self.send_content((ROOT / name).read_bytes(), mime)
        else:
            self.send_json({"error": "页面不存在"}, 404)

    def read_json(self, limit):
        length = int(self.headers.get("Content-Length", 0))
        if self.headers.get_content_type() != "application/json" or not 1 <= length <= limit:
            raise ValueError("请求应为有效的 JSON")
        body = json.loads(self.rfile.read(length))
        if not isinstance(body, dict):
            raise ValueError("请求内容应为 JSON 对象。")
        return body

    def log_events(self, *entries):
        try:
            self.server.audit.append(*entries)
            return True
        except OSError as error:
            print(f"Operation log write failed: {error}", file=sys.stderr)
            return False

    def ui_events(self, body):
        entries = body.get("events")
        if not isinstance(entries, list) or not 1 <= len(entries) <= 24:
            raise ValueError("操作记录数量无效。")
        pending = []
        for entry in entries:
            name = entry.get("event") if isinstance(entry, dict) else None
            outcome = entry.get("outcome") if name else None
            if not isinstance(name, str) or not 1 <= len(name) <= 80 or outcome not in (None, "ok", "warning", "error", "cancelled"):
                raise ValueError("操作记录格式无效。")
            browser_time = entry.get("time")
            if not isinstance(browser_time, str) or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z", browser_time):
                browser_time = None
            pending.append(event("ui", name, identifier(entry.get("operation")), {
                "receivedAt": timestamp(), "session": entry.get("session"), "clientEvent": entry.get("clientEvent"),
                "page": entry.get("page"), "target": entry.get("target"), "data": entry.get("details"),
            }, request=entry.get("request"), outcome=outcome, time=browser_time))
        if not self.log_events(*pending):
            raise OSError("记录未保存，请检查日志目录权限和磁盘空间。")
        return {"saved": len(pending)}

    def device_request(self):
        operation = identifier(self.headers.get("X-Cfg-Operation"))
        request = identifier(self.headers.get("X-Cfg-Request"))
        path = self.path.removeprefix("/api/")
        context = {"mode": "demo" if self.server.demo else "hardware", "action": path, "codeLocation": "server.py:Bridge.command"}
        start = time.monotonic()
        trace = []
        code = 200
        logged = True
        try:
            body = self.read_json(131072 if path == "read" else 8192)
            item_code = body.get("code")
            if type(item_code) is int and item_code in ITEMS:
                context["rtlItem"] = f"CFG_{ITEMS[item_code].name}"
            logged = self.log_events(event("server", "api.started", operation, {**context, "input": body}, request=request))
            result = self.server.command(self.path, body, trace)
        except (AttributeError, KeyError, TypeError, ValueError) as error:
            code, result = 400, {"error": str(error)}
        except OSError as error:
            code, result = 502, {"error": f"UDP 或 HTTP 通信失败 · {error}"}
        except Exception:
            code, result = 500, {"error": "上位机处理请求失败，请查看操作日志。"}
            context["stack"] = traceback.format_exc()
        saved = []
        for packet in trace:
            details = {key: value for key, value in packet.items() if key != "time"}
            direction = packet["direction"]
            warning = (direction in ("TIMEOUT", "DROP") or packet.get("validationError") or
                       packet.get("statusCode", 0) != 0 and not packet.get("probeBoundary"))
            outcome = "error" if direction == "ERR" else "warning" if warning else "ok"
            saved.append(event("udp", direction, operation, details, request=request,
                               outcome=outcome, time=timestamp(packet["time"])))
        rows = result.get("rows", [])
        errors = sum(row["status"] != "OK" or bool(row.get("validation", {}).get("errors")) for row in rows)
        outcome = "error" if code >= 400 or result.get("error") or result.get("status", "OK") != "OK" else "ok"
        if (outcome == "ok" and (errors or any(row.get("validation", {}).get("warnings") for row in rows)
                                 or result.get("verified") is False or result.get("validationWarnings")
                                 or result.get("review", {}).get("warnings")
                                 or any(count is None for count in result.get("counts", {}).values()))):
            outcome = "warning"
        for start_row in range(0, len(rows), 24):
            saved.append(event("server", "api.rows", operation, {"action": path, "rows": rows[start_row:start_row + 24]},
                               request=request))
        summary = {key: value for key, value in result.items() if key not in ("trace", "rows")}
        saved.append(event("server", "api.finished", operation,
                           {**context, "httpStatus": code, "durationMs": round((time.monotonic() - start) * 1000),
                            "rows": len(rows), "rowsWithErrors": errors, "datagrams": len(trace), **summary},
                           request=request, outcome=outcome))
        if not self.log_events(*saved) or not logged:
            result["auditWarning"] = "本次操作日志未完整保存，请检查日志目录权限和磁盘空间。"
        self.send_json(result, code)

    def do_POST(self):
        if not self.valid_origin():
            self.send_json({"error": "请求来源与本机网页地址不匹配"}, 403)
            return
        if self.path in DEVICE_POST:
            self.device_request()
            return
        try:
            if self.path == "/api/audit/events":
                self.send_json(self.ui_events(self.read_json(65536)))
            elif self.path == "/api/audit/settings":
                body = self.read_json(1024)
                previous = self.server.audit.resize(body.get("maxMiB"))
                operation = identifier(self.headers.get("X-Cfg-Operation"))
                self.log_events(event("server", "audit.capacity", operation,
                                      {"previousMiB": previous, "maxMiB": body["maxMiB"]}, outcome="ok"))
                self.send_json(self.server.audit.settings())
            else:
                self.send_json({"error": "接口不存在"}, 404)
        except (TypeError, ValueError) as error:
            self.send_json({"error": str(error)}, 400)
        except OSError as error:
            self.send_json({"error": f"无法保存操作日志 · {error}"}, 500)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8770, help="local HTTP port (default 8770)")
    parser.add_argument("--demo", action="store_true", help="route UDP to a loopback demo device")
    parser.add_argument("--open", action="store_true", help="open the console in your browser")
    parser.add_argument("--pending-width", type=int, default=24, help="RTL PendingTimeWidth, 1–64")
    parser.add_argument("--priority-width", type=int, default=4, help="RTL ReqWidth, 3–8")
    parser.add_argument("--log-dir", type=Path, help="override the local operation-log directory")
    args = parser.parse_args()
    if not 1 <= args.pending_width <= 64 or not 3 <= args.priority_width <= 8:
        parser.error("--pending-width must be 1–64 and --priority-width must be 3–8")
    with Bridge(args.port, args.demo, args.pending_width, args.priority_width, args.log_dir) as bridge:
        print(f"Centenarian {'demo' if args.demo else 'hardware'} - {bridge.origin}/", flush=True)
        if args.open:
            threading.Thread(target=webbrowser.open, args=(bridge.origin + "/",), daemon=True).start()
        try:
            bridge.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
