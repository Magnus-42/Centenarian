# 仿真测试（TB）

本目录是工程的**仿真测试集合**：每个 `.v` 文件都是一个完整、可独立运行的测试台，自带时钟、激励、参考模型与 PASS / FAIL 判定，用 Vivado `xsim` 直接跑，不需要另外写 testbench。

覆盖范围从通用 AXI-Stream 组件（`axis_fifo`、`skid`、N 选 1 合并）到以太网各层（MAC 分流 / 最小帧长补齐、ARP 引擎、IPv4 收发与 ARP 服务），再到 UDP 长度与校验和生成、单口自环、跨时钟域、双网口直连等链路级集成场景。

> 板级顶层 `subsys_test_top` 的上板验证与实测记录见[Docs/04 · 验证与测试](../Docs/04-verification.md)；本目录只做仿真，不覆盖 CMAC / GT 硬核。

---

## 环境要求

- **Vivado 2025.2**（用到 `xvlog` / `xelab` / `xsim`）
- 无需额外器件库：测试台只依赖 `RTL/` 下的源码，不例化 Vivado IP 硬核

---

## 目录结构

```text
TB/
├── README.md                          ← 本文件
├── Bsp/                               通用 AXI-Stream 组件
│   ├── Axis/tb_axis_n_to_1.v
│   ├── Fifo/tb_axis_fifo_async.v
│   ├── Fifo/tb_axis_fifo_sync.v
│   ├── Fifo/tb_fifo_sync.v
│   └── Skid/tb_axis_skid_buffer.v
├── Link/Mac/                          以太网链路层
│   ├── tb_eth_type_demux.v
│   └── tb_eth_frame_pad60.v
├── Network/                           网络层
│   ├── Arp/                           ARP 引擎
│   │   └── tb_arp_engine_top.v
│   ├── Icmp/                          ICMPv4
│   │   ├── tb_icmpv4_type_demux.v
│   │   ├── tb_icmpv4_echo_reply.v
│   │   └── tb_icmpv4_top.v
│   └── Ipv4/                          IPv4 协议栈
│       ├── tb_ipv4_arp_service.v
│       ├── tb_ipv4_eth_rx.v
│       ├── tb_ipv4_eth_tx.v
│       ├── tb_ipv4_eth_header_add.v
│       └── tb_ipv4_top.v
└── Transport/Udp/Ipv4/                传输层（UDP over IPv4）
    ├── tb_udp_ipv4_len_checksum.v
    ├── tb_udp_ipv4_header_add.v
    └── tb_udp_ipv4_tx.v
```

命名约定：**单元级测试台按 `tb_<被测模块>.v` 命名**（被测模块即 `RTL/` 下对应的模块名）；链路级 / 多模块联合测试用语义化命名（如 `tb_ipv4_top.v`）。

---

## 运行一个测试台

以 `tb_ipv4_top.v` 为例，在**源码目录**（`RTL/`、`TB/` 所在的那一层）执行：

```bash
# 1) 收集要编译的源文件：RTL(排除 Backup / Top / Test/Top) + 打流机(RTL/Test) + 目标测试台
find RTL -name '*.v' -not -path 'RTL/Backup/*' -not -path 'RTL/Top/*' -not -path 'RTL/Test/Top/*' | sort > tb_files.txt
echo "TB/Network/Ipv4/tb_ipv4_top.v" >> tb_files.txt

# 2) 编译 → 精化 → 运行
xvlog -work work -sv -f tb_files.txt
xelab work.tb_ipv4_top -s snap_tb_ipv4_top
xsim  snap_tb_ipv4_top -runall
```

Windows 下把 `xvlog` / `xelab` / `xsim` 换成 Vivado 安装目录下的`<Vivado>/bin/xvlog.bat`、`xelab.bat`、`xsim.bat` 即可，参数完全相同。

**判定**：日志末尾出现 `*** ALL TESTS PASSED ***`（或等价的成功提示）即通过；出现 `[FAIL]` 或 `CHECK(S) FAILED` 即失败，并会打印具体是哪一项、期望值多少。**超时也计失败**：卡死时打印 `[FAIL] FATAL: timeout`，不会出现"既没有 PASS 也没有 FAIL"的假通过。

说明：

- `RTL/Test/` 下的三个打流机（`ipv4_100g_tester`、`eth_100g_tester`、`subsys_100g_tester`）  
  要一起编译，链路级测试台会例化它们；
- `RTL/Top/` 与 `RTL/Test/Top/` 下的顶层**不参与**仿真编译：`Top/net_stack_top` 是产品顶层，
  `Test/Top/subsys_test_top` / `ipv4_test_top` / `cmac_test_top` 是板级顶层（例化 CMAC 等 IP），都只用于综合实现；
- `RTL/Backup/` 是历史归档，也不参与编译。

---

## 测试台一览

### 通用组件（Bsp）

| 文件                               | 被测模块               | 覆盖内容                                                                                     |
| -------------------------------- | ------------------ | ---------------------------------------------------------------------------------------- |
| `Bsp/Axis/tb_axis_n_to_1.v`        | `axis_n_to_1`        | 单路收发、两路严格优先仲裁、输出随机反压、长跑稳定性；逐拍数据与 `tlast` 记分板比对                                           |
| `Bsp/Fifo/tb_axis_fifo_async.v`  | `axis_fifo_async`  | 包模式基础功能；写 100 MHz / 读 38 MHz 的指针回绕与满 / 空压力；随机包长与间隔 + 异步复位压力；超长包（`PACKET_FIFO` 的已知限制）行为演示 |
| `Bsp/Fifo/tb_axis_fifo_sync.v`   | `axis_fifo_sync`   | **一次运行覆盖三种存储配置**（distributed / block+`BRAM_DO_REG=2` / auto+`BRAM_DO_REG=2`，各一份独立 DUT），逐拍全字段比对；包模式、背靠背、反压与排空 |
| `Bsp/Fifo/tb_fifo_sync.v`        | `fifo_sync`        | 稀疏单脉冲读（含读走最后一条）/ 空读后写入防污染 / 连续读至空的顺序完整性（块 RAM + `BRAM_DO_REG=2`）                         |
| `Bsp/Skid/tb_axis_skid_buffer.v` | `axis_skid_buffer` | 下游反压时的保持与恢复、全吞吐、AXI-Stream 协议稳定性                                                         |

### 以太网链路层（Link/Mac）

| 文件                             | 被测模块              | 覆盖内容                                                             |
| ------------------------------ | ----------------- | ---------------------------------------------------------------- |
| `Link/Mac/tb_eth_type_demux.v`  | `eth_type_demux`  | 按以太类型分流到 ipv4 / arp 通道，未命中类型进 other 兜底通道；背靠背 + 下游反压下不重复、不丢失、不串通道 |
| `Link/Mac/tb_eth_frame_pad60.v` | `eth_frame_pad60` | 短帧（如 ARP）补齐到 60 字节最小帧长，长帧不受影响                                    |

### ARP 引擎（Network/Arp）

| 文件                            | 被测模块             | 覆盖内容                                                                                                                                                                                                      |
| ----------------------------- | ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Network/Arp/tb_arp_engine_top.v` | `arp_engine_top` | 完整覆盖（多个 phase 顺序执行）：主功能 9 场景（清表 / 学习+应答 / 命中 / 未命中 / pending 去重 / 错误注入 / 本网段广播 / 跨网段走网关 / 反压 / ack 溢出）；一口多 IP（同子网双 IP、跨子网双 IP 两套配置）；学习策略（只学"问到自己头上"的发送方）；多 IP 共享 ARP / pending 表的 key 归属；末尾附决策流水线内部信号诊断打印 |

### IPv4 协议栈（Network/Ipv4）

| 文件                               | 被测模块               | 覆盖内容                                                                                                                |
| -------------------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `Network/Ipv4/tb_ipv4_arp_service.v` | `ipv4_arp_service` | 命中转发 / 未命中整包丢弃 / 多拍包逐拍转发 / 下游反压不丢不重；10 级流水线与 ARP 查表延迟对齐、背靠背与反压下归属不错位；真实引擎 + 线速连发 + 随机反压逼出缓冲分支；缓冲分支命中次数诊断量化          |
| `Network/Ipv4/tb_ipv4_eth_rx.v`      | `ipv4_eth_rx`      | 剥掉 14 字节以太网首部，提取目的 / 源 MAC，逐拍一致性                                                                                    |
| `Network/Ipv4/tb_ipv4_eth_tx.v`      | `ipv4_eth_tx`      | 帧首拍发起 ARP 查询、插入 14 字节以太网首部、未命中时整包丢弃；目的 IP 不被 ARP 结论覆盖的回归防护；与真实 ARP 引擎联测的端到端（未命中→发 ARP→学习→转发、跨网段查网关、广播直发）            |
| `Network/Ipv4/tb_ipv4_eth_header_add.v`     | `ipv4_eth_header_add`     | 插入以太网首部，且**不改写** IPv4 头里的目的 IP                                                                                      |
| `Network/Ipv4/tb_ipv4_top.v`         | `ipv4_top` 链路      | 链式集成（多 phase 顺序执行）：单口自环（上电自解析 / 反压 / 长跑）；打流之后主机再发 ARP 仍必须应答的回归；跨时钟域（用户时钟 ↔ 线路时钟）数据完整性与停流排空；双网口直连（发 ARP → 应答 → 数据直达） |

### ICMPv4（Network/Icmp）

| 文件                                     | 被测模块                | 覆盖内容                                                                                                                              |
| -------------------------------------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `Network/Icmp/tb_icmpv4_type_demux.v`  | `icmpv4_type_demux` | echo / other 两路分流：首拍匹配（IPv4 `IHL=5`、非分片、`type/code=8/0`）；合法 echo 进 echo 口，reply / dest-unreachable / IHL=6 / MF=1 分片 / frag_off≠0 / 短帧一律进 other；背靠背交错 + echo 口反压抖动不串口 |
| `Network/Icmp/tb_icmpv4_echo_reply.v`  | `icmpv4_echo_reply` | 回显应答整包比对（交换 src/dst IP、`type 8→0`、ICMP 校验和 +8、TTL 继承、`musr=12`）；丢弃防御（TTL=0 / MAC 错 / 非 echo 三类，各验 drop 脉冲 + 3bit 原因）；单拍包、背靠背合法+丢弃交错不串包 |
| `Network/Icmp/tb_icmpv4_top.v`         | `icmpv4_top` 链路   | 分流语义验证：echo 请求（8/0，含 2 拍包）只走应答口且应答 `type=0`；非 echo（type≠8 / code≠0 / MF=1 / frag_off≠0）全部走 other 口并与输入逐字节一致；两路互斥（包数之和 = 发送数）、`usr` 透传、输出无 X；全速 + 随机反压两 phase |

### 传输层（Transport/Udp/Ipv4）

| 文件                                              | 被测模块                   | 覆盖内容                                                                                                                                                                                                 |
| ----------------------------------------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Transport/Udp/Ipv4/tb_udp_ipv4_len_checksum.v` | `udp_ipv4_len_checksum` | 侧带通道极限压力（10 类判定）：首拍 `total_len` / 头校验和、包内侧带恒定、载荷与 keep 逐字节、拍数 / `tlast` / 包数、`usr` 透传、3 次中途复位后恢复、输出无 X、写侧守法、包 FIFO 与侧带 FIFO 水位及收尾配平；6 段流量含 1 字节包背靠背、32704 B 巨帧链、包长边界交替 |
| `Transport/Udp/Ipv4/tb_udp_ipv4_header_add.v` | `udp_ipv4_header_add` | 插 20 B IPv4 首部后**按 keep 重建字节流**与独立参考模型逐字节比对（与拍内打包方式解耦）：首部各字段（0x45 / TOS / 总长 / id / DF / TTL / proto / 校验和 / src·dst IP）、`usr` 原样透传、末拍高 20 字节有数据时的补插拍、背靠背交替 keep 不串包；6 类判定（字节 / 字节数 / usr / 包数与多余拍 / 输出 X / 复位）+ keep 低位连续提示；5 段含长度扫描 12 种、随机反压与流中复位 |
| `Transport/Udp/Ipv4/tb_udp_ipv4_tx.v`          | `udp_ipv4_tx`        | 端到端发送链整包逐字节比对（`len_checksum → udp_header_add → ipv4_header_add → skid`）：6 包混合长度 1 / 55 / 56 / 57 / 44 / 128 B，覆盖两级补拍边界与 IPv4 头校验和；含 108bit `usr` 每包元数据 |

---

## 结果判定的几种形式

绝大多数测试台结束时会打印 `*** ALL TESTS PASSED ***` 或 `*** N CHECK(S) FAILED ***`。  

有两个例外，看结果时请注意：

| 文件                                                             | 说明                                                                 |
| -------------------------------------------------------------- | ------------------------------------------------------------------ |
| `Transport/Udp/Ipv4/tb_udp_ipv4_len_checksum.v`                 | 成功标志是 `*** ALL TORTURE CHECKS PASSED ***`                            |
| `Network/Arp/tb_arp_engine_top.v`、`Network/Ipv4/tb_ipv4_arp_service.v` | 内含**诊断 phase**（打印内部信号 / 量化计数），这些打印**不参与 PASS/FAIL 计数**，只要最终总判定通过即可 |

另外，回归防护类检查（目的 IP 不被覆盖）期望打印 **"未复现"**，即表示被防护的缺陷没有回归。

---

## 写测试台时要遵守的工程约定

- **字节序**：所有多字节字段按"低位 = 线上首字节"（线序）书写，例如以太网类型 `0x0800`写成 `16'h0008`、`0x0806` 写成 `16'h0608`；IP `192.168.1.2` 写成 `32'h0201_A8C0`。
- **多路接口是打包（packed）矢量**：`eth_type_demux`、`eth_tx_mux`、`ipv4_top` 的多路输入 / 输出都是一条扁平总线，第 k 路取 `[k*W +: W]`；`ipv4_top` 的 RX 输出每路还带 97 位`usr`，其中 `[96:49]` 是源 MAC、`[48:1]` 是目的 MAC、`bit0` 是 user 位。
- **出口仲裁按 `usr` 值仲裁（值大者胜，`0` 视为无请求）**：所以打流机接入时必须给非 0 的`usr`（链路级测试台统一用 `AXIS_USER_VAL = 4'd8`），ARP 帧优先级为 15，天然优先于业务帧。
- **ARP 查询结果是一对**：`arp_dst_mac`（解析出的下一跳 MAC）+ `arp_src_mac`（本机源 MAC），以太网首部的源 MAC 由后者提供。
- **AXIS user 端口统一叫 `*_susr` / `*_musr`**。
- 一个文件 = 一个测试台模块；若同一模块有多组不同配置的场景，在**同一个模块内用多个DUT 实例**（`u_dut_xxx`），场景作为顺序 phase 依次执行，各 phase 独立计错、末尾统一汇总判定。
- 测试台内部自用的辅助模块（如 `tb_ipv4_top.v` 里的 `tb_axis_reg_slice`）统一带 `tb_` 前缀，避免与 `RTL/` 里的模块重名。
- **超时看门狗必须打 `[FAIL]`**：卡死时若只打印一行 `TIMEOUT`，用 `grep FAIL` 做回归会误判为通过；同时每个 phase 都要有相内超时，不能只靠全局看门狗。
- **记分板必须在 `mvalid && mready` 的拍上结算**：只看 `mvalid` 会把被反压停住的同一拍重复计数；只等 `mvalid && mlast`（不比对内容）则会漏掉数据错误。
