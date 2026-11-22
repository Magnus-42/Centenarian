"""Host-side codec for RTL/Config/cfg_cmd.v and cfg_regs.v."""

import ipaddress
import re
import socket
import time
from dataclasses import dataclass, replace


STAMP = bytes.fromhex("19 31")
VALUE_BYTES = 16
GET, SET, EXEC, RESPONSE = 1, 2, 3, 4
OK, BAD_OP, BAD_ITEM, BAD_INDEX, ACCESS_DENIED, BAD_VALUE_LENGTH = range(6)
STATUS = ("OK", "BAD_OP", "BAD_ITEM", "BAD_INDEX", "ACCESS_DENIED", "BAD_VALUE_LENGTH")
ARP_ANNOUNCE_MASK = 0x2A
ARP_ANNOUNCE_SEND = 0x2B
ICMP_ECHO_PRIORITY = 0x2C
ICMP_ERROR_FLAGS = 0x2D
UDP_IPV4_RX_PORT_RANGE = 0x2E
UDP_IPV6_RX_PORT_RANGE = 0x2F
PROFILES = {"A": ("192.168.1.9", 6), "B": ("192.168.1.137", 134)}


@dataclass(frozen=True)
class Item:
    code: int
    name: str
    label: str
    group: str
    width: int
    kind: str
    access: str = "rw"
    table: str = ""
    note: str = ""
    bits: tuple[str, ...] = ()
    value_bits: int = 0


ITEMS = {item.code: item for item in (
    Item(0x10, "MGMT_MAC_ADDR", "管理 MAC", "management", 6, "mac"),
    Item(0x11, "MGMT_IPV4_ADDR", "管理 IPv4", "management", 4, "ipv4"),
    Item(0x12, "MGMT_UDP_PORT", "管理 UDP 端口", "management", 2, "port"),
    Item(0x13, "LINK_STATE", "物理链路", "status", 1, "link", "ro"),
    Item(0x14, "IP_TX_DROP_FLAGS", "IP 发送丢包", "status", 1, "flags", "ro",
         bits=("IPv4 发送丢包", "IPv6 发送丢包")),
    Item(0x15, "CLEAR_PORT_FLAGS", "清除端口状态", "actions", 0, "action", "exec",
         note="清除本口的 IP、ARP 和 ICMP 错误标志。"),
    Item(0x16, "RESTORE_PORT_DEFAULTS", "恢复端口默认值", "actions", 0, "action", "exec",
         note="恢复本口寄存器的默认值，管理地址与 UDP 端口也可能改变。"),
    Item(0x20, "IPV4_LOCAL_IP", "本机 IPv4", "ipv4", 4, "ipv4", table="ipv4"),
    Item(0x21, "IPV4_LOCAL_MAC", "本机 MAC", "ipv4", 6, "mac", table="ipv4"),
    Item(0x22, "IPV4_GATEWAY", "IPv4 网关", "ipv4", 4, "ipv4", table="ipv4"),
    Item(0x23, "IPV4_MASK", "IPv4 子网掩码", "ipv4", 4, "ipv4", table="ipv4"),
    Item(0x24, "ARP_PENDING_TIMEOUT_MS", "ARP 待决超时", "policy", 8, "timeout",
         note="单位为毫秒。"),
    Item(0x25, "ARP_TX_PRIORITY", "ARP 发送优先级", "policy", 1, "priority"),
    Item(0x26, "ARP_ERROR_FLAGS", "ARP 错误标志", "status", 1, "flags", "ro",
         bits=("接收错误", "应答 FIFO 溢出", "待决 FIFO 溢出", "查询源 IP 非本机")),
    Item(0x27, "ARP_CLEAR_STATE", "ARP 清除状态", "status", 1, "flags", "ro",
         bits=("缓存清除完成", "待决队列清除完成")),
    Item(0x28, "ARP_CLEAR_CACHE", "清除 ARP 缓存", "actions", 0, "action", "exec",
         note="清除本口已学习的 ARP 表项。"),
    Item(0x29, "ARP_CLEAR_PENDING", "清除 ARP 待决队列", "actions", 0, "action", "exec",
         note="清除本口等待 ARP 解析的报文。"),
    Item(ARP_ANNOUNCE_MASK, "ARP_ANNOUNCE_MASK", "免费 ARP 发送掩码", "policy", 0, "bitmask",
         table="arp_announce", note="索引固定为 0。bit 0 对应管理地址，bit 1 起依次对应业务 IPv4 地址。"),
    Item(ARP_ANNOUNCE_SEND, "ARP_ANNOUNCE_SEND", "发送免费 ARP", "actions", 0, "action", "exec",
         note="使用「ARP 与 ICMP」中本口已保存的掩码。新请求覆盖待发送的旧请求，已经开始的一轮继续发送。"),
    Item(ICMP_ECHO_PRIORITY, "ICMP_ECHO_PRIORITY", "ICMP 回显优先级", "policy", 1, "priority"),
    Item(ICMP_ERROR_FLAGS, "ICMP_ERROR_FLAGS", "ICMP 错误标志", "status", 1, "flags", "ro",
         bits=("TTL 错误",)),
    Item(UDP_IPV4_RX_PORT_RANGE, "UDP_IPV4_RX_PORT_RANGE", "UDP(IPV4) 目的端口区间", "udp", 4, "range", table="udp",
         note="格式为起始端口-结束端口，包含两端。"),
    Item(UDP_IPV6_RX_PORT_RANGE, "UDP_IPV6_RX_PORT_RANGE", "UDP(IPV6) 目的端口区间", "udp", 4, "range", table="udp_ipv6",
         note="格式为起始端口-结束端口，包含两端。"),
    Item(0x40, "IPV6_SRC_IP", "IPv6 源地址", "ipv6", 16, "ipv6", table="ipv6_source"),
    Item(0x41, "IPV6_SRC_MAC", "IPv6 源 MAC", "ipv6", 6, "mac", table="ipv6_source"),
    Item(0x42, "IPV6_DST_IP", "IPv6 目的地址", "ipv6", 16, "ipv6", table="ipv6_destination"),
    Item(0x43, "IPV6_DST_MAC", "IPv6 目的 MAC", "ipv6", 6, "mac", table="ipv6_destination"),
)}
TABLES = {item.table: item for item in ITEMS.values() if item.table}


def announce_mask_item(ipv4_count):
    bits = ipv4_count + 1
    if bits > VALUE_BYTES * 8:
        raise ValueError(f"免费 ARP 掩码最多支持 {VALUE_BYTES * 8} 个 IPv4 地址（含管理地址）。")
    return replace(ITEMS[ARP_ANNOUNCE_MASK], width=(bits + 7) // 8, value_bits=bits)


def unsigned(text, maximum, minimum=0):
    if len(text) > max(22, len(str(maximum))) or not re.fullmatch(r"[0-9]+|0[xX][0-9a-fA-F]+", text):
        raise ValueError("请输入十进制整数或 0x 开头的十六进制整数")
    value = int(text, 16 if text.lower().startswith("0x") else 10)
    if not minimum <= value <= maximum:
        raise ValueError(f"数值应在 {minimum}–{maximum} 之间")
    return value


def is_management_address(address):
    return not (address.is_unspecified or address.is_multicast or int(address) == 0xFFFFFFFF)


def encode_value(item, text, pending_width=24, priority_width=4):
    text = text.strip()
    if not text:
        raise ValueError(f"请输入{item.label}。")
    if item.kind == "ipv4":
        try:
            address = ipaddress.IPv4Address(text)
        except ipaddress.AddressValueError:
            raise ValueError(f"{item.label}须为点分隔的四段数字，每段在 0 到 255 之间。") from None
        if item.name == "MGMT_IPV4_ADDR" and not is_management_address(address):
            raise ValueError("管理 IPv4 必须是单播地址。")
        if item.name == "IPV4_MASK":
            zero_bits = 0xFFFFFFFF - int(address)
            if zero_bits & (zero_bits + 1):
                raise ValueError("子网掩码的二进制位须由连续的 1 和随后的 0 组成，例如 255.255.255.0。")
        return address.packed
    if item.kind == "ipv6":
        if "%" in text:
            raise ValueError("IPv6 地址无需填写接口作用域")
        try:
            return ipaddress.IPv6Address(text).packed
        except ipaddress.AddressValueError:
            raise ValueError("IPv6 地址格式无效。各段用冒号分隔，连续的零可用一次 :: 缩写，如 fe80::1。") from None
    if item.kind == "mac":
        if not re.fullmatch(r"[\da-fA-F]{2}(?::[\da-fA-F]{2}){5}", text, re.ASCII):
            raise ValueError("MAC 格式应为 00:11:22:33:44:55")
        return bytes.fromhex(text.replace(":", ""))
    if item.kind == "port":
        return unsigned(text, 65535, 1).to_bytes(2, "big")
    if item.kind == "range":
        low_text, sep, high_text = text.partition("-")
        if not sep:
            raise ValueError("请用短横线分隔起始与结束端口")
        low = unsigned(low_text.strip(), 65535)
        high = unsigned(high_text.strip(), 65535)
        if low > high:
            raise ValueError("起始端口不能大于结束端口。")
        return low.to_bytes(2, "big") + high.to_bytes(2, "big")
    if item.kind in ("timeout", "priority", "bitmask"):
        if item.kind == "bitmask" and not item.value_bits:
            raise ValueError("尚未确定本口免费 ARP 掩码长度。")
        width = {"timeout": pending_width, "priority": priority_width, "bitmask": item.value_bits}[item.kind]
        return unsigned(text, (1 << width) - 1).to_bytes(item.width, "little")
    raise ValueError("该配置项不可写")


def decode_value(item, raw):
    if item.kind in ("ipv4", "ipv6"):
        return str(ipaddress.ip_address(raw))
    if item.kind == "mac":
        return raw.hex(":")
    if item.kind == "port":
        return str(int.from_bytes(raw, "big"))
    if item.kind == "range":
        return f"{int.from_bytes(raw[:2], 'big')}-{int.from_bytes(raw[2:], 'big')}"
    if item.kind == "flags":
        return f"0x{raw[0]:02X}"
    if item.kind == "bitmask":
        return f"0x{int.from_bytes(raw, 'little'):0{len(raw) * 2}X}"
    return str(int.from_bytes(raw, "little"))


def big_endian_hex(item, raw):
    # Configuration scalars sent low byte first are displayed high byte first.
    ordered = raw[::-1] if item.kind in ("timeout", "bitmask") else raw
    return ordered.hex(" ").upper()


def readback_error(item, raw, pending_width, priority_width):
    if item.kind == "link":
        return "链路状态超出协议定义的范围。" if raw[0] > 1 else ""
    if item.kind == "flags":
        return "设备返回了协议未定义的状态位。" if raw[0] >> len(item.bits) else ""
    try:
        encode_value(item, decode_value(item, raw), pending_width, priority_width)
    except ValueError as error:
        return str(error)
    return ""


def request_frame(op, seq, code, index, value=b""):
    return STAMP + bytes((seq << 3 | op, code, index, len(value))) + value.ljust(VALUE_BYTES, b"\0")


def response_error(frame, seq, item, index, op):
    if len(frame) != 23:
        return f"应答应为 23 字节，实际为 {len(frame)} 字节。"
    if frame[:2] != STAMP:
        return f"应答标识应为 {STAMP.hex(' ')}，实际为 {frame[:2].hex(' ')}。"
    if frame[2] & 7 != RESPONSE:
        return f"应答操作码应为 {RESPONSE}，实际为 {frame[2] & 7}。"
    if frame[2] >> 3 != seq:
        return f"应答序号应为 {seq}，实际为 {frame[2] >> 3}。"
    status, code, reply_index, length = frame[3:7]
    expected = item.width if status == OK and op == GET else 0
    if code != item.code:
        return f"应答配置项应为 0x{item.code:02X}，实际为 0x{code:02X}。"
    if reply_index != index:
        return f"应答索引应为 {index}，实际为 {reply_index}。"
    if length != expected:
        return f"应答值长度应为 {expected} 字节，实际为 {length} 字节。"
    return ""


def decode_response(frame, seq, item, index, op):
    if response_error(frame, seq, item, index, op):
        return None
    return frame[3], frame[7:7 + frame[6]]


def packet_fields(frame, item, is_reply):
    """Describe a validated configuration payload using zero-based byte offsets."""
    fields = []

    def add(label, value, offset, size=1):
        fields.append({"label": label, "value": value, "offset": offset, "size": size})

    control = frame[2]
    op = control & 7
    op_name = {GET: "GET", SET: "SET", EXEC: "EXEC", RESPONSE: "RESPONSE"}.get(op, "未知")
    item_offset = 4 if is_reply else 3
    value_offset = item_offset + 3
    length = frame[value_offset - 1]
    add("协议标识", "19 31", 0, 2)
    add("序号（位 7–3）", str(control >> 3), 2)
    add("操作码（位 2–0）", f"{op_name} · {op}", 2)
    if is_reply:
        status = frame[3]
        status_name = STATUS[status] if status < len(STATUS) else "未知状态"
        add("应答状态", f"{status_name} · 0x{status:02X}", 3)
    add("配置项", f"0x{item.code:02X} · {item.name}", item_offset)
    add("索引", str(frame[item_offset + 1]), item_offset + 1)
    add("有效值长度", f"{length} 字节", value_offset - 1)
    if length:
        raw = frame[value_offset:value_offset + length]
        unit = " ms" if item.kind == "timeout" else ""
        add("配置值", f"{decode_value(item, raw)}{unit} · {big_endian_hex(item, raw)}",
            value_offset, length)
    if length < VALUE_BYTES:
        add("填充", f"{VALUE_BYTES - length} 字节", value_offset + length, VALUE_BYTES - length)
    return fields


class Client:
    def __init__(self, target, trace, demo=None, *, pending_width=24, priority_width=4):
        self.target = target
        self.trace = trace
        self.demo = demo
        self.pending_width = pending_width
        self.priority_width = priority_width
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.seq = 0
        self.table_counts = {}

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        self.sock.close()

    def value_error(self, item, raw):
        return readback_error(item, raw, self.pending_width, self.priority_width)

    def item_for_index(self, item, index):
        if item.code != ARP_ANNOUNCE_MASK:
            return item
        if index != 0:
            raise ValueError("免费 ARP 掩码的索引必须为 0。")
        if item.width:
            return item
        ipv4_count = self.count(TABLES["ipv4"])
        if ipv4_count is None:
            raise ValueError("无法探测本口 IPv4 地址表项数，不能确定免费 ARP 掩码长度。")
        return announce_mask_item(ipv4_count)

    def exchange(self, op, item, index=0, value=b"", new_target=None, *, probing=False):
        item = self.item_for_index(item, index)
        self.seq = (self.seq + 1) % 32
        frame = request_frame(op, self.seq, item.code, index, value)
        destination = self.demo or self.target
        target = f"{self.target[0]}:{self.target[1]}"
        peers = {destination}
        if not self.demo:
            for host, port in (self.target, new_target or self.target):
                # Older FPGA images swapped the reply source port bytes.
                peers.update(((host, port), (host, ((port & 255) << 8) | (port >> 8))))
        command = {"target": target, "attemptedPeer": f"{destination[0]}:{destination[1]}",
                   "rtlItem": f"CFG_{item.name}", "item": item.code, "index": index,
                   "sequence": self.seq, "opcode": op}
        for attempt in range(1, (3 if op == GET else 1) + 1):
            try:
                self.sock.sendto(frame, destination)
                tx = {"direction": "TX", "time": time.time_ns() // 1_000_000, "target": target,
                      "hex": frame.hex(" "), "peer": f"{destination[0]}:{destination[1]}",
                      "fields": packet_fields(frame, item, False), "command": command, "attempt": attempt}
                self.trace.append(tx)
                deadline = time.monotonic() + 0.25
                discarded = 0
                while (remaining := deadline - time.monotonic()) > 0:
                    self.sock.settimeout(remaining)
                    data, source = self.sock.recvfrom(1024)
                    received_at = time.time_ns() // 1_000_000
                    response = decode_response(data, self.seq, item, index, op) if source in peers else None
                    if response is not None:
                        rx = {"direction": "RX", "time": received_at, "target": target,
                              "hex": data.hex(" "), "peer": f"{source[0]}:{source[1]}",
                              "fields": packet_fields(data, item, True), "command": command, "attempt": attempt}
                        status, raw = response
                        rx["statusCode"] = status
                        if status == OK and op == GET:
                            error = self.value_error(item, raw)
                            if error:
                                rx["validationError"] = error
                        elif status >= len(STATUS):
                            rx["validationError"] = "设备返回了未定义的应答状态。"
                        if probing and status == BAD_INDEX:
                            tx["probeBoundary"] = rx["probeBoundary"] = True
                        self.trace.append(rx)
                        return response
                    discarded += 1
                    if discarded <= 8:
                        reason = (response_error(data, self.seq, item, index, op) if source in peers else
                                  "源地址或源端口与预期不符。")
                        self.trace.append({"direction": "DROP", "time": received_at, "target": target,
                                           "peer": f"{source[0]}:{source[1]}", "text": reason,
                                           "hex": data.hex(" "), "command": command, "attempt": attempt})
            except TimeoutError:
                pass
            except OSError as error:
                self.trace.append({"direction": "ERR", "time": time.time_ns() // 1_000_000,
                                   "target": target, "text": str(error), "command": command, "attempt": attempt})
                continue
            self.trace.append({"direction": "TIMEOUT", "time": time.time_ns() // 1_000_000, "target": target,
                               "text": "未收到匹配的应答。", "command": command, "attempt": attempt,
                               "discarded": discarded})
        return None

    def count(self, item):
        if item.code in self.table_counts:
            return self.table_counts[item.code]
        if item.code == ARP_ANNOUNCE_MASK:
            ipv4_count = self.count(TABLES["ipv4"])
            if ipv4_count is None or ipv4_count + 1 > VALUE_BYTES * 8:
                return None
            mask = announce_mask_item(ipv4_count)
            reply = self.exchange(GET, mask, probing=True)
            if reply is None or reply[0] != OK:
                return None
            self.table_counts[item.code] = 1
            return 1
        lower, upper = 0, 254
        while lower < upper:
            index = (lower + upper) // 2
            reply = self.exchange(GET, item, index, probing=True)
            if reply is None or reply[0] not in (OK, BAD_INDEX):
                return None
            if reply[0] == OK:
                lower = index + 1
            else:
                upper = index
        if lower:
            self.table_counts[item.code] = lower
        return lower or None
