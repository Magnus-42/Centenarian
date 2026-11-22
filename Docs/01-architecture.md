# 架构与数据路径

框图展示单口 `eth_stack_port`。IPv4 和 IPv6 各有 UDP 载荷通路。

![Centenarian 单口硬件框图，从 QSFP、CMAC 到 Ethernet、ARP、IP、ICMPv4 和 UDP](architecture.svg)

## 接收路径

| 接口 | 匹配依据 | 业务收到的数据 |
| --- | --- | --- |
| MAC | EtherType | 从目的 MAC 开始的 Ethernet 帧 |
| IPv4 | Protocol | 从 IPv4 首部开始的完整包 |
| IPv6 | 基本首部的 Next Header | 从 IPv6 首部开始的完整包 |
| ICMPv4 | IPv4 的 Protocol 为 1 | 未进入自动回显通路的完整 IPv4 包 |
| UDP | UDP 目的端口区间 | UDP 载荷 |

各层先匹配内部规则，再按业务通道编号从小到大匹配。UDP(IPV4) 的管理端口优先于该通路的业务端口区间。MAC、IPv4、IPv6 和 UDP 的最后一路 RX 接收本通路未匹配的报文。

UDP(IPV4) 与 UDP(IPV6) 的侧带位宽和字段见 [AXI-Stream 位段](03-integration.md#usr-位段)。

## 发送路径

| 接口 | 业务提供 |
| --- | --- |
| MAC | 从目的 MAC 开始的 Ethernet 帧内容 |
| IPv4 | 完整 IPv4 包，含已填写的 IPv4 首部校验和 |
| ICMPv4 | 完整 IPv4 包，`Protocol=1`，含 IPv4 和 ICMPv4 校验和 |
| IPv6 | 完整 IPv6 包，源和目的地址须分别在本口的 IPv6/MAC 表中配置 |
| UDP | UDP 载荷，通过 `usr` 提供 IP 地址、UDP 端口、TTL（IPv4）或 Hop Limit（IPv6），以及优先级 |

UDP 发送由协议栈生成 UDP 首部和对应的 IP 首部。IPv4 发送时，下一跳 ARP 未命中会触发解析并丢弃当前包，业务侧在解析完成后重发。IPv6 发送时，源或目的地址查表未命中会丢弃当前包。 [参数和默认值](02-configuration.md)
