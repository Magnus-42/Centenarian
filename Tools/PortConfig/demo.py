"""Loopback UDP fixture for trying the web console without hardware."""

import socket
from threading import Thread

from protocol import (
    ACCESS_DENIED, ARP_ANNOUNCE_MASK, BAD_INDEX, BAD_ITEM, BAD_OP, BAD_VALUE_LENGTH, EXEC, GET,
    ICMP_ECHO_PRIORITY, ICMP_ERROR_FLAGS, ITEMS, OK, PROFILES, RESPONSE, SET, STAMP, UDP_IPV4_RX_PORT_RANGE,
    UDP_IPV6_RX_PORT_RANGE, VALUE_BYTES, announce_mask_item, decode_value, encode_value,
)


class DemoDevice:
    def __init__(self):
        host, port = PROFILES["A"]
        defaults = {
            0x10: ["00:00:19:31:00:f1"], 0x11: [host], 0x12: [str(port)],
            0x20: ["192.168.1.18", "192.168.1.17", "192.168.1.16"],
            0x21: ["00:00:19:31:00:03", "00:00:19:31:00:02", "00:00:19:31:00:01"],
            0x22: ["192.168.1.1"] * 3, 0x23: ["255.255.255.0"] * 3,
            0x24: ["1000"], 0x25: ["15"], ICMP_ECHO_PRIORITY: ["12"],
            UDP_IPV4_RX_PORT_RANGE: ["0-8", "16-16", "32-48"],
            UDP_IPV6_RX_PORT_RANGE: ["0-8", "16-16", "32-48"],
            0x40: ["fe80::1931:12", "fe80::1931:11"],
            0x41: ["00:00:19:31:00:12", "00:00:19:31:00:11"],
            0x42: ["fe80::1931:23", "fe80::1931:22", "fe80::1931:21"],
            0x43: ["00:00:19:31:00:23", "00:00:19:31:00:22", "00:00:19:31:00:21"],
        }
        self.defaults = {code: tuple(encode_value(ITEMS[code], value) for value in values)
                         for code, values in defaults.items()}
        mask = announce_mask_item(len(defaults[0x20]))
        self.defaults[ARP_ANNOUNCE_MASK] = ((2 ** mask.value_bits - 1).to_bytes(mask.width, "little"),)
        self.values = {code: [bytes((int(code == 0x13),))]
                       for code in (0x13, 0x14, 0x26, 0x27, ICMP_ERROR_FLAGS)}
        self.reset()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.address = self.sock.getsockname()
        Thread(target=self.serve, daemon=True).start()

    def reset(self):
        self.values.update({code: list(values) for code, values in self.defaults.items()})

    @property
    def endpoint(self):
        host = decode_value(ITEMS[0x11], self.values[0x11][0])
        port = decode_value(ITEMS[0x12], self.values[0x12][0])
        return host, int(port)

    def serve(self):
        while True:
            try:
                data, peer = self.sock.recvfrom(1024)
                if len(data) != 22 or data[:2] != STAMP:
                    continue
                control, code, index, length = data[2:6]
                status, value = self.handle(control & 7, code, index, length, data[6:])
                reply = STAMP + bytes((control & 0xF8 | RESPONSE, status, code, index, len(value)))
                self.sock.sendto(reply + value.ljust(VALUE_BYTES, b"\0"), peer)
            except OSError:
                return

    def handle(self, op, code, index, length, value):
        item = ITEMS.get(code)
        if op not in (GET, SET, EXEC):
            return BAD_OP, b""
        if item is None:
            return BAD_ITEM, b""
        if index >= len(self.values.get(code, (None,))):
            return BAD_INDEX, b""
        if code == ARP_ANNOUNCE_MASK:
            item = announce_mask_item(len(self.defaults[0x20]))
        if not ((op == GET and item.access != "exec") or
                (op == SET and item.access == "rw") or
                (op == EXEC and item.access == "exec")):
            return ACCESS_DENIED, b""
        if length != (item.width if op == SET else 0):
            return BAD_VALUE_LENGTH, b""
        if op == GET:
            return OK, self.values[code][index]
        if op == SET:
            raw = value[:length]
            if code == ARP_ANNOUNCE_MASK:
                mask = int.from_bytes(raw, "little") & ((1 << item.value_bits) - 1)
                raw = mask.to_bytes(item.width, "little")
            self.values[code][index] = raw
        elif code == 0x16:
            self.reset()
        elif code == 0x15:
            for flag in (0x14, 0x26, ICMP_ERROR_FLAGS):
                self.values[flag][0] = b"\0"
        elif code in (0x28, 0x29):
            self.values[0x27][0] = bytes((self.values[0x27][0][0] | (1 << (code - 0x28)),))
        return OK, b""
