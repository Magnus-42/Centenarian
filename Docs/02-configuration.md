# 参数和默认值

## 综合期参数

| 参数 | 影响 |
| --- | --- |
| `CmacSelect` | `0` 选 A 侧 CMAC，`1` 选 B 侧 CMAC |
| `MacRxCount`、`Ipv4RxCount`、`Ipv6RxCount`、`UdpIpv4RxCount`、`UdpIpv6RxCount` | 业务匹配规则数，公开 RX 总线另有 1 路兜底 |
| `MacTxCount`、`Ipv4TxCount`、`Ipv6TxCount`、`UdpIpv4TxCount`、`UdpIpv6TxCount` | 公开 TX 通道数量 |
| `LocalIpv4Count`、`SrcIpv6Count`、`DstIpv6Count` | 本口业务地址表深度，管理 IPv4/MAC 独立接入 |
| `MacTypeDict`、`Ipv4TypeDict`、`Ipv6TypeDict` | EtherType、IPv4 Protocol、IPv6 Next Header 业务匹配字典 |
| `ClkFreqHz`、`ReqWidth`、`PendingTimeWidth` | 业务时钟频率、请求优先级位宽、ARP 待决超时位宽 |
| `MgmtGatewayIp`、`MgmtSubnetMask` | 管理 IPv4 的网关和掩码 |
| `Default*`、`MgmtMac` | 复位时装载的管理地址、业务表、UDP 区间和 ARP/ICMP 策略 |

各类收发通道数至少为 1。自定义单口实例的通道数后，按每路位宽重算业务侧总线。 [接线与位宽](03-integration.md#2-接业务-axi-stream)

## 参考设计默认值

| 项目 | A 口 | B 口 |
| --- | --- | --- |
| 管理端点 | `192.168.1.9:6` | `192.168.1.137:134` |
| 管理 MAC | `00:00:19:31:00:f1` | `00:00:19:31:80:f1` |
| 管理网关 / 掩码 | `192.168.1.1` / `255.255.255.0` | `192.168.1.1` / `255.255.255.0` |
| 业务 IPv4 / IPv6 源 / IPv6 目的表深度 | 3 / 2 / 3 | 2 / 2 / 2 |
| MAC RX / TX | 3 / 2 | 2 / 3 |
| IPv4 RX / TX | 4 / 4 | 4 / 4 |
| ICMPv4 RX / TX | 1 / 1 | 1 / 1 |
| IPv6 RX / TX | 4 / 3 | 4 / 3 |
| UDP(IPV4) RX / TX | 4 / 8 | 4 / 4 |
| UDP(IPV4) RX 业务档 0 / 1 / 2 | 0–8 / 16 / 32–48 | 0–8 / 16 / 32–48 |
| UDP(IPV6) RX / TX | 4 / 2 | 4 / 2 |
| UDP(IPV6) RX 业务档 0 / 1 / 2 | 0–8 / 16 / 32–48 | 0–8 / 16 / 32–48 |
| ARP 待决超时 | 1000 ms | 2000 ms |
| ARP / ICMPv4 回显发送优先级 | 15 / 12 | 15 / 12 |

表中各分流接口的 RX 数包含最后一路兜底。使用参考打流机时，保留测试流对应的业务地址和 UDP 端口区间。 [A 口参数](../RTL/Top/eth_stack_port_a.v) · [B 口参数](../RTL/Top/eth_stack_port_b.v)

## 排列规则与地址

- RTL 中，地址和端口字段的首个线上字节放在最低 8 位。通道 0 和表项 0 放在各自向量的低位。例：`192.168.1.9` 写为 `32'h0901_a8c0`。
- UDP 端口闭区间在 RTL 中拼成 `{上界, 下界}`，每个端点 16 位。例：32–48 写为 `32'h3000_2000`。

## 修改运行时配置

复位或执行 `RESTORE_PORT_DEFAULTS` 会把本口配置恢复为综合时设定的默认值。 [网页读写步骤](05-config-command.md#用网页读写配置)
