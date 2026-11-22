"""Bounded, persistent JSON Lines storage for console operations."""

import json
import os
import re
import tempfile
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4


MIB = 1024 * 1024
DEFAULT_MIB = 8
MAX_MIB = 64
SOURCES = {"ui", "server", "udp"}


def timestamp(milliseconds=None):
    value = datetime.now(timezone.utc) if milliseconds is None else datetime.fromtimestamp(milliseconds / 1000, timezone.utc)
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def identifier(value=None):
    return value if isinstance(value, str) and re.fullmatch(r"[a-f0-9]{32}", value) else uuid4().hex


def default_directory(demo):
    local = os.environ.get("LOCALAPPDATA") if os.name == "nt" else os.environ.get("XDG_STATE_HOME")
    base = Path(local) if local else Path.home() / ".local" / "state"
    return base / "Centenarian" / "cfgctl" / ("demo" if demo else "hardware")


def encode(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8", errors="backslashreplace") + b"\n"


def line_tail(data, size):
    if size <= 0:
        return b""
    start = len(data) - size
    if start <= 0:
        return data
    if data[start - 1] != 10:
        boundary = data.find(b"\n", start)
        return data[boundary + 1:] if boundary >= 0 else b""
    return data[start:]


class AuditLog:
    def __init__(self, folder):
        self.folder = Path(folder).resolve()
        self.folder.mkdir(parents=True, exist_ok=True)
        self.path = self.folder / "operations.jsonl"
        self.preferences = self.folder / "settings.json"
        self.lock_path = self.folder / "operations.lock"
        self.lock = threading.Lock()

    @contextmanager
    def locked(self):
        with self.lock, self.lock_path.open("a+b") as lock_file:
            if os.name == "nt":
                import msvcrt
                lock_file.seek(0)
                msvcrt.locking(lock_file.fileno(), msvcrt.LK_LOCK, 1)
            else:
                import fcntl
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            yield

    def maximum(self):
        try:
            value = json.loads(self.preferences.read_bytes()).get("maxMiB")
            if type(value) is int and 1 <= value <= MAX_MIB:
                return value
        except (FileNotFoundError, ValueError, AttributeError):
            pass
        return DEFAULT_MIB

    def size(self):
        try:
            return self.path.stat().st_size
        except FileNotFoundError:
            return 0

    def settings(self):
        with self.locked():
            return {"maxMiB": self.maximum(), "sizeBytes": self.size(), "maxAllowedMiB": MAX_MIB,
                    "path": str(self.path)}

    def snapshot(self):
        with self.locked():
            return self.read()

    def read(self):
        try:
            return self.path.read_bytes()
        except FileNotFoundError:
            return b""

    def replace(self, path, data):
        with tempfile.NamedTemporaryFile(dir=self.folder, delete=False) as handle:
            temporary = Path(handle.name)
            try:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
                handle.close()
                temporary.replace(path)
            finally:
                handle.close()
                temporary.unlink(missing_ok=True)

    def resize(self, maximum):
        if type(maximum) is not int or not 1 <= maximum <= MAX_MIB:
            raise ValueError(f"日志容量应为 1–{MAX_MIB} MiB 的整数。")
        with self.locked():
            old = self.maximum()
            if self.size() > maximum * MIB:
                self.replace(self.path, line_tail(self.read(), maximum * MIB))
            self.replace(self.preferences, encode({"maxMiB": maximum}))
            return old

    def append(self, *events):
        lines = []
        for entry in events:
            event = dict(entry, id=uuid4().hex)
            line = encode(event)
            if len(line) <= 256 * 1024:
                lines.append(line)
                continue
            # Split unusually large result data without losing content or whole events on rotation.
            payload = line.decode("utf-8")
            for offset in range(0, len(payload), 24000):
                lines.append(encode({"id": uuid4().hex, "time": event["time"], "source": event["source"],
                                     "event": event["event"], "operation": event.get("operation"),
                                     "request": event.get("request"), "outcome": event.get("outcome"),
                                     "payloadId": event["id"], "part": offset // 24000 + 1,
                                     "lastPart": offset + 24000 >= len(payload), "jsonFragment": payload[offset:offset + 24000]}))
        if not lines:
            return
        data = b"".join(lines)
        with self.locked():
            limit = self.maximum() * MIB
            if self.size() + len(data) + 1 > limit:
                if len(data) < limit:
                    keep = max(0, min(limit - len(data), limit * 7 // 8 - len(data)))
                    data = line_tail(self.read(), keep) + data
                self.replace(self.path, line_tail(data, limit))
            else:
                with self.path.open("a+b") as handle:
                    if handle.tell():
                        handle.seek(-1, os.SEEK_END)
                        if handle.read(1) != b"\n":
                            handle.write(b"\n")
                    handle.write(data)
                    handle.flush()
                    os.fsync(handle.fileno())

    def entries(self, source, operation, before, limit=60):
        events = []
        skip = bool(before)
        for line in reversed(self.snapshot().splitlines()):
            try:
                entry = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            if not isinstance(entry, dict):
                continue
            if skip:
                skip = entry.get("id") != before
                continue
            if (source and entry.get("source") != source) or (operation and entry.get("operation") != operation):
                continue
            events.append(entry)
            if len(events) > limit:
                return {"entries": events[:limit], "next": events[limit - 1]["id"]}
        return {"entries": events, "next": None, "expired": skip}


def event(source, name, operation=None, details=None, *, request=None, outcome=None, time=None):
    return {"time": time or timestamp(), "source": source, "event": name, "operation": operation,
            "request": request, "outcome": outcome, "details": details}
