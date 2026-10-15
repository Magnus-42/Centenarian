# 02 · 参数与配置

## 三层参数体系

```text
全局 *_MAX      → 决定边界位宽（所有口一致）
逐口 *_ARR      → 槽位打包的逐口配置（口 0 在最低段，新增口往高位拼）
逐口 IDX_*      → 顶层接线的索引常量（改完字典核对这张表即可）
```

每口只用槽内低 `N` 段；槽内多余的通道由循环自动补零 / 排水，**加端口不改变已有端口的索引**。

## 参数一览

| 参数                           | 含义                                                  |
| ---------------------------- | --------------------------------------------------- |
| `ETH_PORT_NUM`               | 网口数                                                 |
| `CFG_NUM_WIDTH`              | 计数项位宽 ⇒ 单口通道数上限 `2^N - 1`                           |
| `PENDING_TIME_WIDTH`         | ARP 待发超时计数位宽                                        |
| `PRIORITY_WIDTH`             | `usr` 优先级位宽                                         |
| `*_RX_TYPE_NUM_MAX` / `_ARR` | 每口接收用户通道数（不含内部通道与未匹配通道）                             |
| `*_RX_TYPE_DICT_ARR`         | 每口接收分发规则：MAC 16bit/项、IPv4 与 IPv6 8bit/项、UDP 32bit/项 |
| `*_TX_TYPE_NUM_ARR`          | 每口发送路数                                              |
| `UDP_DST_PORT_RANGE_ARR`     | 每口 UDP 目的端口区间 `[hi，lo]`（区间不可重叠）                     |
| `CFG_PENDING_TIME_ARR`       | 每口 ARP 待发超时（单位为用户时钟周期）                              |
| `LOCAL_*_NUM_ARR`            | 本口 MAC、IPv6 目的 / 源 MAC 表项数                          |

## 分发规则（字典）书写规则

- **排列**：书写序 `{左..右}`，**最右端 = 通道 0**；
- **字节序**：按**小端序**（least-significant byte first）书写 —— 配置值 `V` 的最低字节对应线上第一个字节。小端序的定义可参考[Endianness — Wikipedia](https://en.wikipedia.org/wiki/Endianness#Little-endian)。

  例：EtherType `0x0800` 写作 `16'h0008`；IP 地址 `192.168.1.100` 写作 `32'h6401A8C0`；
- **只填用户项**：内部通道（MAC 层的 ARP / IPv4 / IPv6、IPv4 层的 UDP）不要写进字典。

## 通道数必须写足位宽

`*_NUM_ARR` 每个通道占 `CFG_NUM_WIDTH` 位。仅写 `4'd3` 而 `CFG_NUM_WIDTH = 8` 时会被零扩展，导致通道整体错位且**编译不报错**。推荐写法：

```verilog
{ETH_PORT_NUM{ {CFG_NUM_WIDTH{1'b0}} | 4'd3 }}     // 宽度 = max(CFG_NUM_WIDTH, 4)
```

## 关闭某一层（N = 0）

某层不启用时，该口只占位一条哑通道：不接收、不参与发送调度，无需条件编译。

## 配置示例一：单网口，IPv4 + UDP 为主

需求：

| 层        | 通道数                             | 内容                                  |
| -------- | ------------------------------- | ----------------------------------- |
| MAC 接收   | 1                               | 自定义类型 `0x88B5`                      |
| IPv4 接收  | 3                               | ICMP（`0x01`）、OSPF（`0x59`）、协议 `0x06` |
| IPv6 接收  | 0                               | 不启用                                 |
| UDP 接收   | 3                               | 端口区间 `[0,0]`、`[1,1]`、`[2,8]`        |
| 发送路数     | MAC 1 / IPv4 3 / IPv6 0 / UDP 8 | 与 `*_axis_susr` 一一对应                |
| ARP 待发超时 | 1 秒（按用户时钟周期数填）                  |                                     |

参考实现（参数部分；端口连接见 README「用法」节）：

```verilog
eth_subsys_top #(
  .ETH_PORT_NUM        (1),
  .CFG_NUM_WIDTH       (8),
  .PRIORITY_WIDTH      (4),
  .MAC_RX_TYPE_NUM_ARR    ({ {8{1'b0}}|4'd1 }),
  .MAC_RX_TYPE_DICT_ARR   (16'hB588),
  .MAC_TX_TYPE_NUM_ARR    ({ {8{1'b0}}|4'd1 }),
  .IPV4_RX_TYPE_NUM_ARR   ({ {8{1'b0}}|4'd3 }),
  .IPV4_RX_TYPE_DICT_ARR  ({8'h06, 8'h59, 8'h01}),          // ch0=icmp ch1=ospf ch2=0x06
  .IPV4_TX_TYPE_NUM_ARR   ({ {8{1'b0}}|4'd3 }),
  .IPV6_RX_TYPE_NUM_ARR   ({ {8{1'b0}}|4'd0 }),              // 不启用 IPv6
  .IPV6_TX_TYPE_NUM_ARR   ({ {8{1'b0}}|4'd0 }),
  .UDP_RX_PORT_NUM_ARR    ({ {8{1'b0}}|4'd3 }),
  .UDP_DST_PORT_RANGE_ARR ({32'h00080002, 32'h00010001, 32'h00000000}),
  .UDP_TX_PORT_NUM_ARR    ({ {8{1'b0}}|4'd8 }),
  .CFG_PENDING_TIME_ARR   (57'd400_000_000)
) u_dut ( /* 端口连接略 */ );
```

## 配置示例二：双网口自测配置（`subsys_test_top` 实配）

需求：两口交叉对接自发自收，每口配齐各协议的用户通道与"未匹配"探测通道——这是验证环境 `RTL/Top/subsys_test_top.v` 的实际配置，可直接对照上板。

| 层          | 口 A                                      | 口 B                                      |
| ---------- | ---------------------------------------- | ---------------------------------------- |
| MAC 接收     | 2：`0x88B5`、`0x88CC`                      | 1：`0x88B5`                               |
| IPv4 接收    | 3：icmp、ospf、`0x06`                       | 3：`0x06`、icmp、ospf                       |
| IPv6 接收    | 3：udp、icmpv6、ospfv3                      | 3：udp、ospfv3、icmpv6                      |
| UDP 接收     | 3 区间：`[0,0]` `[1,1]` `[2,8]`             | 2 区间：`[2,2]` `[4,8]`                     |
| 发送路数       | MAC 2 / IPv4 4 / IPv6 3 / UDP 8          | MAC 3 / IPv4 4 / IPv6 3 / UDP 4          |
| 本机地址       | IP `192.168.1.9`，MAC `00:19:31:00:00:01` | IP `192.168.1.8`，MAC `00:19:31:00:00:02` |
| 网关 / 子网    | `192.168.1.1` / `255.255.255.0`（两口同）     | 同左                                       |
| IPv6 MAC 表 | 目的 2 项 / 源 2 项                           | 目的 2 项 / 源 2 项                           |
| ARP 待发超时   | 1.0 s                                    | 0.5 s                                    |

参考实现（摘自 `subsys_test_top.v`，`*_ARR` 的打包顺序为 `{口B 槽位, 口A 槽位}`，口 A 在低位）：

```verilog
localparam ETH_PORT_NUM     = 2;
localparam CFG_NUM_WIDTH    = 8;
localparam PRIORITY_WIDTH   = 4;
localparam PENDING_TIME_WIDTH = 57;

localparam [CFG_NUM_WIDTH-1:0] MAC_RX_TYPE_NUM_MAX  = 2;
localparam [CFG_NUM_WIDTH-1:0] MAC_TX_TYPE_NUM_MAX  = 3;
localparam [CFG_NUM_WIDTH-1:0] IPV4_RX_TYPE_NUM_MAX = 3;
localparam [CFG_NUM_WIDTH-1:0] IPV4_TX_TYPE_NUM_MAX = 4;
localparam [CFG_NUM_WIDTH-1:0] IPV6_RX_TYPE_NUM_MAX = 3;
localparam [CFG_NUM_WIDTH-1:0] IPV6_TX_TYPE_NUM_MAX = 3;
localparam [CFG_NUM_WIDTH-1:0] UDP_RX_PORT_NUM_MAX  = 3;
localparam [CFG_NUM_WIDTH-1:0] UDP_TX_PORT_NUM_MAX  = 8;

localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] MAC_RX_TYPE_NUM_ARR
  = { {CFG_NUM_WIDTH{1'b0}}|4'd1 , {CFG_NUM_WIDTH{1'b0}}|4'd2 };            // B:1  A:2
localparam [(MAC_RX_TYPE_NUM_MAX*16)*ETH_PORT_NUM-1:0] MAC_RX_TYPE_DICT_ARR
  = { {16'h0000,16'hB588} , {16'hCC88,16'hB588} };                          // B ch0=88B5 ; A ch0=88B5 ch1=88CC
localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] MAC_TX_TYPE_NUM_ARR
  = { {CFG_NUM_WIDTH{1'b0}}|4'd3 , {CFG_NUM_WIDTH{1'b0}}|4'd2 };            // B:3  A:2
localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] IPV4_RX_TYPE_NUM_ARR
  = { {CFG_NUM_WIDTH{1'b0}}|4'd3 , {CFG_NUM_WIDTH{1'b0}}|4'd3 };
localparam [(IPV4_RX_TYPE_NUM_MAX*8)*ETH_PORT_NUM-1:0] IPV4_RX_TYPE_DICT_ARR
  = { {8'h59,8'h01,8'h06} , {8'h06,8'h59,8'h01} };                          // B ch0=06 ch1=01 ch2=59 ; A ch0=01 ch1=59 ch2=06
localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] IPV4_TX_TYPE_NUM_ARR
  = { {CFG_NUM_WIDTH{1'b0}}|4'd4 , {CFG_NUM_WIDTH{1'b0}}|4'd4 };
localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] IPV6_RX_TYPE_NUM_ARR
  = { {CFG_NUM_WIDTH{1'b0}}|4'd3 , {CFG_NUM_WIDTH{1'b0}}|4'd3 };
localparam [(IPV6_RX_TYPE_NUM_MAX*8)*ETH_PORT_NUM-1:0] IPV6_RX_TYPE_DICT_ARR
  = { {8'h3A,8'h59,8'h11} , {8'h59,8'h3A,8'h11} };                          // B ch0=11 ch1=59 ch2=3A ; A ch0=11 ch1=3A ch2=59
localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] IPV6_TX_TYPE_NUM_ARR
  = { {CFG_NUM_WIDTH{1'b0}}|4'd3 , {CFG_NUM_WIDTH{1'b0}}|4'd3 };
localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] UDP_RX_PORT_NUM_ARR
  = { {CFG_NUM_WIDTH{1'b0}}|4'd2 , {CFG_NUM_WIDTH{1'b0}}|4'd3 };
localparam [(UDP_RX_PORT_NUM_MAX*32)*ETH_PORT_NUM-1:0] UDP_DST_PORT_RANGE_ARR
  = { {32'd0,32'h00080004,32'h00020002} , {32'h00080002,32'h00010001,32'h00000000} };
                                                                            // B ch0=[2,2] ch1=[4,8] ; A ch0=[0,0] ch1=[1,1] ch2=[2,8]
localparam [CFG_NUM_WIDTH*ETH_PORT_NUM-1:0] UDP_TX_PORT_NUM_ARR
  = { {CFG_NUM_WIDTH{1'b0}}|4'd4 , {CFG_NUM_WIDTH{1'b0}}|4'd8 };            // B:4  A:8
localparam [PENDING_TIME_WIDTH*ETH_PORT_NUM-1:0] CFG_PENDING_TIME_ARR
  = { 57'd200_000_000 , 57'd400_000_000 };                                  // B:0.5s@400MHz  A:1.0s@400MHz
```

> 发送路数可以大于实际使用的路数：多余的路保持空闲（不发送、不参与调度），无需裁剪。
>
> 本机 IP / MAC、网关 / 子网与 IPv6 MAC 表的完整写法，以及逐口通道索引表（`IDX_*`），
>
> 见 `RTL/Top/subsys_test_top.v` 源文件。
