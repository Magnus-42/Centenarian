# 架构与数据路径

框图展示单口 `eth_stack_port`。IPv4 和 IPv6 各有 UDP 载荷通路。

![Centenarian 单口硬件框图，从 QSFP、CMAC 到 Ethernet、ARP、IP、ICMPv4 和 UDP](architecture.svg)

## 接收路径

| 接口 | 匹配依据 | 业务收到的数据 |
| --- | --- | --- |
| MAC | EtherType | Ethernet 载荷 |
| IPv4 | Protocol | IPv4 载荷 |
| IPv6 | 基本首部的 Next Header | IPv6 载荷 |
| ICMPv4 | IPv4 的 Protocol 为 1 | 未进入自动回显通路的 ICMPv4 载荷 |
| UDP | UDP 目的端口区间 | UDP 载荷 |

各层先匹配内部规则，再按业务通道编号从小到大匹配。UDP(IPV4) 的管理端口优先于该通路的业务端口区间。MAC、IPv4、IPv6 和 UDP 的最后一路 RX 接收本通路未匹配的报文。

UDP(IPV4) 与 UDP(IPV6) 的侧带位宽和字段见 [AXI-Stream 位段](03-integration.md#usr-位段)。

## 发送路径

| 接口 | 业务提供 |
| --- | --- |
| MAC | Ethernet 载荷，`usr` 提供 Ethernet 首部和优先级 |
| IPv4 | IPv4 载荷，`usr` 提供 20 字节首部和优先级；首部校验和由协议栈填写 |
| ICMPv4 | ICMPv4 载荷，`usr` 提供 ICMP 基本首部、IPv4 首部和优先级 |
| IPv6 | IPv6 载荷，`usr` 提供 40 字节基本首部和优先级；源和目的地址须分别在本口的 IPv6/MAC 表中配置 |
| UDP | UDP 载荷，`usr` 提供 UDP 首部、IP 首部和优先级 |

IPv4 发送时，下一跳 ARP 未命中会触发解析并丢弃当前包，业务侧应在解析完成后重发。IPv6 发送时，源或目的地址查表未命中会丢弃当前包。 [参数和默认值](02-configuration.md)
