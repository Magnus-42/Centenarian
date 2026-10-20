# 03 · 集成指南

## 端口位宽公式

| 信号族            | 位宽                                                  |
| -------------- | --------------------------------------------------- |
| `mac_axis_m*`  | `(MAC_RX_TYPE_NUM_MAX + 1) * ETH_PORT_NUM` 通道       |
| `ipv4_axis_m*` | `(IPV4_RX_TYPE_NUM_MAX + 1) * ETH_PORT_NUM` 通道      |
| `icmp_axis_m*` | **`ETH_PORT_NUM` 通道**（每口 1 路，只含非 echo 的 ICMP）        |
| `ipv6_axis_m*` | `(IPV6_RX_TYPE_NUM_MAX + 1) * ETH_PORT_NUM` 通道      |
| `udp_axis_m*`  | `(UDP_RX_PORT_NUM_MAX + 1) * ETH_PORT_NUM` 通道       |
| `*_axis_s*`    | `*_TX_N_MAX * ETH_PORT_NUM` 路                       |
| `*_axis_susr`  | `ARBITER_VAL_WIDTH * *_TX_N_MAX * ETH_PORT_NUM`        |
| `*_axis_musr`  | 每通道位宽由顶层常量给出：MAC `MAC_RX_USR_WIDTH`(1) / IPv4·IPv6 `*_RX_USR_WIDTH`(97) / UDP `UDP_RX_USR_WIDTH`(193) |
| `AXIS_ARBITER_WIDTH` | TX 侧优先级/仲裁值位宽 = `ARBITER_VAL_WIDTH`（默认 4） |

数据 / `keep` 按通道（或路）展开：`data` 通道 k = `[k*512 +: 512]`，`keep` = `[k*64 +: 64]`。

> `icmp_axis_m*` 是 IPv4 之下 ICMP **单独引出的出口**（每口 1 路），`usr` 为 IPv4 层 **97bit**。
> 该口 **不包含 echo 请求**：Echo Request 在 `icmpv4_top` 内部直接转成 Echo Reply，从 IPv4 发送链路发出，不会出现在此口；此口只输出 ICMP 的其它类型（目的不可达 / 时间超时 / 重定向等）。若不需要 ICMP 边界出口，把 `icmp_axis_mready` 接 `1'b1` 排空即可。

## 时钟与复位

| 时钟         | 频率            | 说明                                              |
| ---------- | ------------- | ----------------------------------------------- |
| `sys_clk`  | 100 MHz       | 板级输入                                            |
| `clk`（用户域） | 200 / 400 MHz | **由外部时钟方案提供**（示例工程用时钟向导从 100 MHz 倍频），全部内部逻辑的工作域 |
| GT 参考时钟    | 322.269 MHz   | 由 CMAC 自带约束定义                                   |

复位：外部复位建议在顶层做两级同步后释放；GT 域复位由 CMAC 输出提供

（`usr_tx_reset` / `usr_rx_reset`），时钟域跨越处已由 CDC 处理。

## 约束

- 引脚与时钟：`XDC/*.xdc`（按顶层同名生效），可作为模板改写；
- 布局：按每个网口的以太网层划分 pblock（SLR 边界）。

## 时序

- 设计在 VU37P 上以 400 MHz 用户时钟完成实现，无时序违例（数据见 README 安装节）；换器件或大幅增加通道数后请重新评估；
- 跨 SLR 的路径已统一插入寄存级，新增跨 SLR 逻辑时请同样处理；

## 建议的最小集成自检

1. 先对 `net_stack_top` 单独跑一次综合，确认时序收敛；
2. 顶层综合后检查「端口未连接 / 无驱动」类告警 —— 它们通常对应某条通道被静默优化；
3. 用 ILA 挂各层统计口与调度授予信号，确认流量落到预期通道。

