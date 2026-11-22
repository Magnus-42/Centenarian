"""Checks that depend on more than the configuration item being edited."""

from ipaddress import IPv4Address, IPv4Network

from protocol import BAD_INDEX, GET, ITEMS, OK, UDP_IPV4_RX_PORT_RANGE, UDP_IPV6_RX_PORT_RANGE, decode_value


LOCAL_IPV4 = (0x11, 0x20)
LOCAL_IPV6 = (0x40,)
LOCAL_MAC = (0x10, 0x21, 0x41)
SUBNET = (0x20, 0x22, 0x23)
IPV6_DEST = (0x42, 0x43)
UDP_IPV4 = (0x12, UDP_IPV4_RX_PORT_RANGE)
UDP_IPV6 = (UDP_IPV6_RX_PORT_RANGE,)


def related_items(code):
    """Return the item codes needed on the current port and its peer."""
    if code in LOCAL_IPV4:
        local = LOCAL_IPV4 if code == 0x11 else (0x11, *SUBNET)
        return local, LOCAL_IPV4
    if code in LOCAL_IPV6:
        return LOCAL_IPV6, LOCAL_IPV6
    if code in LOCAL_MAC:
        return (code,), LOCAL_MAC
    for family in (UDP_IPV4, UDP_IPV6):
        if code in family:
            return family, family
    for group in (SUBNET, IPV6_DEST):
        if code in group:
            return group, ()
    return (), ()


def read_config(client, codes, known=None):
    values = dict(known or {})
    complete = True
    for code in codes:
        item = ITEMS[code]
        for index in range(254 if item.table else 1):
            if (code, index) in values:
                continue
            reply = client.exchange(GET, item, index)
            if reply and reply[0] == BAD_INDEX and item.table and index:
                break
            if not reply or reply[0] != OK:
                complete = False
                break
            values[code, index] = decode_value(item, reply[1])
    return values, complete


def location(code, index):
    item = ITEMS[code]
    return f"{item.label}（索引 {index}）" if item.table else item.label


def duplicates(values, codes, value, scope, skipped=None):
    return [f"{value} 已用于{scope}的{location(code, index)}。"
            for (code, index), existing in values.items()
            if code in codes and existing == value and (code, index) != skipped]


def ipv4_priority(values, key, value):
    matches = [(code, index) for (code, index), address in values.items()
               if code in LOCAL_IPV4 and address == value]
    if len(matches) < 2:
        return []
    others = "、".join(location(*entry) for entry in sorted(matches) if entry != key)
    # Management occupies hardware slot 0 and the business slots follow it.
    winner = location(*max(matches))
    return [f"{value} 与本口的{others}重复。ARP 应答和发送时的地址查找优先使用{winner}。"]


def subnet_issues(values, index):
    address, gateway, mask = (values.get((code, index)) for code in SUBNET)
    if not address or not mask or address == "0.0.0.0":
        return [], []
    mask_bits = int(IPv4Address(mask))
    zero_bits = 0xFFFFFFFF - mask_bits
    if zero_bits & (zero_bits + 1):
        return [], [f"索引 {index} 的现有掩码无效，无法核对子网与网关。"]
    network = IPv4Network((address, mask_bits.bit_count()), strict=False)
    errors, warnings = [], []
    if gateway == address:
        errors.append(f"索引 {index} 的本机 IPv4 与网关相同。")
    if network.prefixlen <= 30:
        for label, value in (("本机 IPv4", address), ("网关", gateway)):
            if value and value != "0.0.0.0" and IPv4Address(value) in (network.network_address, network.broadcast_address):
                errors.append(f"索引 {index} 的{label} {value} 是该子网的网络地址或广播地址。")
    if gateway and gateway != "0.0.0.0" and network.prefixlen < 32 and IPv4Address(gateway) not in network:
        warnings.append(f"索引 {index} 的网关 {gateway} 不在本机 IPv4 所属的子网 {network} 内。")
    return errors, warnings


def udp_warnings(values, code, index):
    warnings = []
    management = values.get((0x12, 0)) if code in UDP_IPV4 else None
    range_code = UDP_IPV4_RX_PORT_RANGE if code in UDP_IPV4 else UDP_IPV6_RX_PORT_RANGE
    ranges = {slot: tuple(map(int, bounds.split("-")))
              for (item, slot), bounds in values.items() if item == range_code}
    if management is not None:
        port = int(management)
        for slot, (low, high) in ranges.items():
            if (code == 0x12 or slot == index) and low <= port <= high:
                warnings.append(f"管理 UDP 端口 {port} 位于业务索引 {slot} 的区间 {low}–{high} 内。该端口由管理接口优先接收。")
    if code == range_code:
        low, high = ranges[index]
        for other, (start, end) in ranges.items():
            if other != index and max(start, low) <= min(end, high):
                if other < index and start <= low and high <= end:
                    warnings.append(f"该区间完全被业务索引 {other} 的区间 {start}–{end} 覆盖，报文会由索引 {other} 接收。")
                else:
                    warnings.append(f"与业务索引 {other} 的区间 {start}–{end} 重叠。重叠部分由索引 {min(index, other)} 优先接收。")
    return warnings


def udp_bounds(code, value):
    if code == 0x12:
        return int(value), int(value)
    return tuple(map(int, value.split("-")))


def udp_peer_warnings(code, value, peer, peer_label):
    low, high = udp_bounds(code, value)
    family = UDP_IPV4 if code in UDP_IPV4 else UDP_IPV6
    matches = []
    for (other, slot), configured in sorted(peer.items()):
        if other not in family:
            continue
        start, end = udp_bounds(other, configured)
        overlap_low, overlap_high = max(low, start), min(high, end)
        if overlap_low > overlap_high:
            continue
        ports = str(overlap_low) if overlap_low == overlap_high else f"{overlap_low}–{overlap_high}"
        label = "管理端口" if other == 0x12 else f"业务索引 {slot}"
        matches.append(f"{label} {configured}（重叠端口 {ports}）")
    if not matches:
        return []
    return [f"与{peer_label}的{'、'.join(matches)}重叠。两口独立分流，可以共用这些端口号。"]


def check_conflicts(code, index, value, current, peer, peer_label, *, audit=False, block_cross_port=True):
    key = code, index
    if not audit and current.get(key) == value:
        return [], []
    values = {**current, key: value}
    errors, warnings = [], []
    cross_port = errors if block_cross_port else warnings
    if code in LOCAL_IPV4 and value != "0.0.0.0":
        warnings.extend(ipv4_priority(values, key, value))
        cross_port.extend(message + "两个物理网口之间没有固定的接收优先级。"
                          for message in duplicates(peer, LOCAL_IPV4, value, peer_label))
    if code in LOCAL_IPV6 and value != "::":
        errors.extend(duplicates(current, LOCAL_IPV6, value, "本口", key))
        cross_port.extend(duplicates(peer, LOCAL_IPV6, value, peer_label))
    if code in LOCAL_MAC and value != "00:00:00:00:00:00" and not int(value[:2], 16) & 1:
        cross_port.extend(duplicates(peer, LOCAL_MAC, value, peer_label))
    if code in SUBNET:
        existing_errors = [] if audit else subnet_issues(current, index)[0]
        subnet_errors, subnet_warnings = subnet_issues(values, index)
        errors.extend(error for error in subnet_errors if error not in existing_errors)
        warnings.extend(subnet_warnings)
    if code in IPV6_DEST:
        address, mac = (values.get((item, index)) for item in IPV6_DEST)
        if address and address != "::" and mac:
            for (item, other), existing in current.items():
                if item != 0x42 or other == index or existing != address:
                    continue
                other_mac = current.get((0x43, other))
                if other_mac and other_mac != mac:
                    errors.append(f"IPv6 目的地址 {address} 已在本口索引 {other} 绑定到不同的 MAC：{other_mac}。")
    if code in (*UDP_IPV4, *UDP_IPV6):
        warnings.extend(udp_warnings(values, code, index))
        warnings.extend(udp_peer_warnings(code, value, peer, peer_label))
    return errors, warnings
