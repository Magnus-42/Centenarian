# 配置上位机（cfgctl）

操作 Centenarian 配置通道（UDP 内部档）的完整工具集。

**Windows / Linux 通用，纯 Python 标准库**，不需要 `pip install` 任何东西。

协议定义见 [`Docs/05-config-command.md`](../../Docs/05-config-command.md)；
实现以 `RTL/Config/*.v` 为唯一依据。

---

## 三个入口

| 入口 | 命令 | 适用场景 |
|---|---|---|
| **Web UI**（推荐） | `python server.py --open` | 日常配置 —— 浏览器里点选，实时日志 |
| **命令行** | `python cfgctl.py -H <ip> <cmd>` | 脚本化 / 批量 / 自动化测试 |
| **tkinter GUI** | `python cfg_gui.py` | 无浏览器的环境（功能与 Web 版重叠） |

三端共用同一份协议核心 `cfgproto.py`，行为完全一致。

---

## 快速开始

### 1. 没有硬件时：先起虚拟设备

```bash
python vdev.py                    # 监听 127.0.0.1:49374 (0xC0DE)
python vdev.py --shuffle -v       # 顺带模拟应答乱序 + 打印每根 TLV
```

### 2. Web UI（推荐）

```bash
python server.py --open           # 起后端并自动开浏览器
```

浏览器打开 <http://127.0.0.1:8770/>：

- **顶栏**填设备 IP / UDP 端口 → 点「连接」（已连接时按钮变「重新连接」，✕ 断开）
- 右侧指示灯显示链路状态
- **左侧导航**：概览 / 地址 / 分流 / 行为 / 状态 / 统计 / 边界 / 动作 / 原始帧
- **底部日志抽屉**：实时通信流水（SSE 推送），可折叠
- 配置项**直接在输入框里改**，值变了那一行的「↑」才亮起；顶部显示「N 项待写入」，
  点「写入修改」批量提交
- 读失败的项会出现「↻」重读按钮
- 危险项（`CMD_UDP_PORT` / `CMD_UDP_PRIO` / `RESET_DEF`）强制二次确认
- **边界页只有一张「配置能力表」**：9 个能力字段逐个给出中文名、含义、
  各口的实际份数、全局上限、约束了哪些 ITEM —— 不用再对着数字猜
- **概览页**是速览：状态条（固件/口数/命令端口/能力）+ 网口状态表 + 当前配置只读快照

其它参数：

```bash
python server.py --host 0.0.0.0   # 允许局域网其它机器访问
python server.py --port 9000       # 换端口
python server.py --vdev            # 同时起虚拟设备，无硬件也能试
```

> 浏览器发不了裸 UDP，所以必须由这个 Python 进程做桥。
> 默认只监听本机回环。

### 3. 命令行

```bash
# 探测：版本 / 几何 / 口数 / 每口链路
python cfgctl.py -H 192.168.1.9 probe

# 读一项（ITEM 可写名称、0x 编号或十进制编号）
python cfgctl.py -H 192.168.1.9 get IPV4_LOCAL_IP
python cfgctl.py -H 192.168.1.9 get 0x00 --port 1      # 口 1

# 写一项
python cfgctl.py -H 192.168.1.9 set IPV4_LOCAL_IP 192.168.1.100
python cfgctl.py -H 192.168.1.9 set UDP_PORT_RANGE 2-8 --set 2
python cfgctl.py -H 192.168.1.9 set IPV4_LOCAL_MAC 00:19:31:00:00:01

# 动作（不重试，避免重复副作用）
python cfgctl.py -H 192.168.1.9 action reset
python cfgctl.py -H 192.168.1.9 action stat-clear --port 1

# 全量导出
python cfgctl.py -H 192.168.1.9 dump
python cfgctl.py -H 192.168.1.9 dump --json > cfg.json

# 查配置边界（每口实际有几档几套）
python cfgctl.py -H 192.168.1.9 geom

# 列出所有 ITEM
python cfgctl.py items
```

**参数说明**：`-P/--udp-port` 是设备 UDP 端口，`--port` 是**网口号**。
两者不同名，避免混淆（早期版本用 `-p` 兼作两者，是个坑）。

### 4. 自测

```bash
python selftest.py             # 82 条用例（含 Web 后端 API 全链路）
python selftest.py --shuffle   # 额外验证乱序应答下的匹配
```

预期输出结尾：`*** 全部通过：110 PASS / 0 FAIL ***`

---

## 界面设计取舍

几条关键的设计取舍：

| 决定 | 理由 |
|---|---|
| 配置行三列：名称 / 值 / 行内写按钮 | 原来的「当前值」列和编辑框内容**完全相同**，是最大的冗余源 |
| 删掉每行的「读」按钮 | 页面级「读取本页」覆盖 99% 场景；仅读失败的项显示「↻」 |
| 「读写」标签只在只读时显示 | 绝大多数项都是读写，标了等于没标 |
| 写按钮未改动时极淡、hover 行才显现 | 渐进披露：没改动就不该有写按钮 |
| 描述文字跟在字段名后（窄屏隐藏、tooltip 常驻） | 原来每行两行字，纵向密度翻倍 |
| 侧栏去掉几何符号图标 | `◈◉⇄⚙◔▤▦⚡⌘` 风格不统一，且 `⌘` 在 Windows 上语义错误 |
| 概览页 4 张大卡片 → 一行状态条 | 版本/口数/命令端口都不常变，不该占那么大地方 |
| 网口状态卡 → 表格 | 两个口要能横向对比，表格比卡片快 |
| 边界页去掉 `GEOMETRY`/`GEOMETRY_MAX`/`PORT_NUM` 三行 | 它们的内容已被能力表完整覆盖，重复展示同一批数字 |
| 移除「超时」输入框 | 固定 200ms；真要调的人会去读文档 |
| 主按钮恒为「连接/重新连接」，断开用独立 ✕ | 一个按钮两种语义会让"改 IP 换设备"变绕 |
| 只读项显示用 `fmt_value` | `ARP_STAT` 显示成 `0x00000048 ← 源 IP 非本网段; 请求超时` 而非裸 `0` |
| **网口选择器整体删除** | 它把 `S.port` 混用为「UDP 端口」与「网口索引」，高亮判断永不成立 —— 功能从未生效；且配置页已按口分节、概览是全口表格，与它重复 |
| 概览页加「当前配置」只读速查表 | IP/MAC/网关/掩码 —— 地址页是「改」的入口，这里是「看一眼」，两种用途 |
| 输入框 `max-width:340px`、名称列 300px | IP/MAC/端口都是短值，拉满只显得空；名与值之间也不该留大空档 |

### 设计系统与响应式

视觉值全部来自 `style.css` 顶部的 `:root` token（色彩 / 间距 `--sp-*` / 字号 `--fs-*` /
圆角 / 阴影 / 动效时长），**不写散落的硬编码** —— 调整视觉从改 token 开始。

| 断点 | 策略 |
|---|---|
| `>1100` | 全量桌面布局 |
| `900~1100` | 侧栏收窄，隐藏描述文字，连接状态收敛 |
| `768~900` | 顶栏间距收紧 |
| `<768` | **移动端**：侧栏转顶部横向滚动标签条；配置行单列；触控目标 ≥40px；表格横向滚动 |
| `<420` | 超小屏进一步收拢 |

桌面 / 平板 / 手机三视口均实测通过（无溢出、无 JS 错误）；`prefers-reduced-motion` 已尊重。

---

## 文件

| 文件 | 作用 | 需要设备 |
|---|---|---|
| `cfgproto.py` | **协议核心库**：TLV 编解码、ITEM 表、状态码、四元组匹配、值格式化、档数推导 | — |
| `server.py` | Web 后端：JSON API + SSE 日志流 + 静态资源 | — |
| `static/` | 前端页面（原生 JS，无构建步骤） | — |
| `cfgctl.py` | 命令行工具 | ✅ |
| `cfg_gui.py` | tkinter 图形界面（轻量备用） | ✅ |
| `vdev.py` | 虚拟设备：没硬件时验证上位机 | — |
| `selftest.py` | 自测：110 项检查（`python selftest.py`） | — |

---

## 协议要点：四个必须记住的坑

### ① 请求与应答的字段布局【不对称】

```
请求 TLV                        应答帧
------                          ------
byte0 = OP                      byte0 = OP
byte1 = SEQ                     byte1 = SEQ
byte2 = ITEM                    byte2 = STATUS
byte3 = (SET<<4) | PORT         byte3 = ITEM
byte4 = LEN                     byte4 = (SET<<4) | PORT
byte5.. = VALUE（小端）          byte5 = LEN
                                byte6.. = VALUE（仅 GET_RSP 有）
```

请求里 `SET` 和 `PORT` **挤在同一个字节**（SET 高 4 位、PORT 低 4 位）；
应答把 `ITEM` 单独占一个字节，`{SET,PORT}` 仍合成一个字节。
两者的头部长度不同：请求 5 字节，应答 6 字节。

### ② `SET_RSP` / `ERR_RSP` 的 LEN 是回显，不跟 VALUE

`ERR_RSP` 的 `LEN` 会回显请求里的 `LEN`，但**后面没有 VALUE 字节**
（`cfg_error.v` 的 `err_axis_mkeep = 6'b111111` 印证）。

**不能拿 `LEN` 去切 `ERR_RSP`**，否则会把紧随其后的下一条应答吃掉。
正确做法是按 `OP` 区分：只有 `0x82 GET_RSP` 才读 `LEN` 字节的 VALUE。

### ③ 应答顺序不保证与请求一致

三路应答经 3 口轮询合并，一帧内多根 TLV 会交错返回。
必须按 **`(SEQ, ITEM, SET, PORT)` 四元组**匹配，不要依赖收包顺序。
`cfgproto.CfgClient` 已自动处理；自己写时请照做。

### ④ IP / MAC / IPv6 的 VALUE 是【网络序】，不反转

**这是最容易写错、后果最严重的一条。**

`cfg_cmd_rx.v` 里 `val_reg[val_index +: 8] <= active_data` ——
第 0 个字节进 `bit[7:0]`，**线上字节序原样进寄存器低位**。
所以 `192.168.1.9` 的 VALUE 字节是 `C0 A8 01 09`，**不是** `09 01 A8 C0`。

RTL 佐证：`cfg_map.vh` 的默认值 `CFG_DEF_IPV4_IP_P0 = 32'h0901_A8C0`
正是网络序字节按小端解释的结果。

判定过程见 `TB/Config/tb_cfg_byteorder.v`（用真实 RTL 跑出来的结论）。

> 其余数值项（端口区间、以太类型、优先级、周期数…）仍走通用的
> 「小端整数」规则，两类不要混。

其它约定：

- **同一 socket 收发**：应答回到请求的源端口，换 socket 收不到
- **准入**：请求的目的 IP 必须是绑定网口 set0 的本机 IP，否则设备**静默丢弃**
- **超时重发**：应答要先解析 ARP，首包可能因表项缺失被丢；默认 3 次 × 200 ms
- **动作类不重试**：`RESET_DEF` / `*_CLEAR` 重发可能造成重复副作用
- **先查边界再写**：读 `0x70 GEOMETRY` 拿每口份数，避免 `BAD_SET`

---

## 状态码

| 值 | 名称 | 触发条件 |
|---|---|---|
| `0x00` | OK | 成功 |
| `0x01` | BAD_OP | `OP` 不是 `0x01` / `0x02` |
| `0x02` | BAD_ITEM | ITEM 未定义（含已删除的 `0x56` / `0x62` / `0x63`） |
| `0x03` | BAD_SET | 档索引越界 |
| `0x04` | BAD_PORT | `PORT ≥ ETH_PORT_NUM` |
| `0x05` | BAD_LEN | `LEN` 越界，或 SET 的 `LEN` ≠ 该 ITEM 值宽 |
| `0x06` | WRITE_ONLY | 对**不可读**项发 GET（动作类 `0x40~0x43`） |
| `0x07` | READ_ONLY | 对**不可写**项发 SET（`0x51~0x72`） |

校验顺序固定，**命中第一个即返回**：

```
OP → ITEM → SET → PORT → LEN → 读写权限
```

---

## 在 Python 里直接用

```python
import cfgproto as P

with P.CfgClient("192.168.1.9", 0xC0DE, timeout=0.2, retries=3) as c:
    print(c.get("VERSION"))                      # 读一项
    c.set("IPV4_LOCAL_IP", "192.168.1.100")      # 写一项
    c.action("STAT_CLEAR", port=1)               # 触发动作

    rsps = c.get_many([("LINK_STATUS", 0, 0),
                       ("LINK_STATUS", 1, 0),
                       ("ARP_STAT",   0, 0)])    # 一次往返读多项
    for r in rsps:
        print(r.item_name, r.port, P.fmt_value(r.item, r.value))
```

`CfgClient.set(..., precheck=False)` 可跳过本地「只读项」拦截，
直接把请求发给设备，用于验证设备端的真实状态码。

---

## Web 后端 API

前端之外也可以直接调（`Content-Type: application/json`）：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/meta` | ITEM 表 / 分组 / 状态码 / **语义元数据**（几何字段含义、统计位含义、只读项解释、TX 通道表） |
| GET | `/api/state` | 当前连接状态 + 已读回的配置快照 |
| POST | `/api/connect` | `{host, port, timeout}` → 建连并探测 |
| POST | `/api/disconnect` | 断开 |
| POST | `/api/read` | `{items:[{item,port,set}]}` → 批量读 |
| POST | `/api/write` | `{item,port,set,value}` → 写 |
| POST | `/api/action` | `{item,port}` → 触发动作 |
| POST | `/api/dump` | 全量读回（按 GEOMETRY 展开档数） |
| POST | `/api/raw` | `{hex}` → 原始帧注入（协议调试） |
| GET | `/api/events` | SSE 实时日志流 |

`ITEM` 可写名称（`IPV4_LOCAL_IP`）、`0x` 编号或十进制编号。

---

## 语义元数据：每个数字都讲清楚

只读数据（边界、统计、状态）如果只显示一个数字，等于让人自己查手册。
所以上位机把这些数值的含义都做进了界面，来源全部是 RTL：

| 界面位置 | 展示内容 | RTL 出处 |
|---|---|---|
| **边界页 · 配置能力表** | 9 个能力字段的中文名、每口实际份数、全局上限、单位、含义、约束了哪些 ITEM | `cfg_reg_bank.v` 的 `rd_idx_*` 选路 + `cfg_map.vh` 的 `CFG_DEF_*_ARR` |
| **统计页 · 位展开** | 每个置位/未置位状态的位号、含义、详细说明、**RTL 出处**（文件:行号） | `arp_engine_top.v` / `icmpv4_echo_reply.v` / `net_stack_top.v` |
| **状态页 · 只读项解释** | VERSION / LINK / TX_IDLE / TX_ACTIVE / IS_DF 各代表什么、出问题该查什么 | `cfg_reg_bank.v` + `net_stack_top.v` |
| **状态页 · TX 通道表** | TX_ACTIVE 的 lane 0~3 分别是谁（ARP / IPv4 / IPv6 / 用户 MAC 段），当前占用高亮 | `net_stack_top.v` 的 lane 装配注释 |

举例 —— `LOCAL_IPV4_MAC_NUM = 1` 不再只是一个数字，界面会告诉你：

> **IPv4 地址套数** `LOCAL_IPV4_MAC_NUM`
> 每口可配置的 IPv4 地址套数。一套 = 本机 IP + MAC + 网关 + 掩码 四个 ITEM 共用同一个套索引。
> ↳ 约束 IPV4_LOCAL_IP / IPV4_LOCAL_MAC / IPV4_GATEWAY / IPV4_MASK

所有语义表在 `cfgproto.py` 里定义（`GEOMETRY_SEMANTICS` / `ARP_STAT_BITS` /
`ICMP_STAT_BITS` / `READONLY_HINTS` / `TX_ACTIVE_LANES`），
通过 `/api/meta` 下发给前端 —— 前端不硬编码任何 ITEM 编号或含义。
`selftest.py` 的 `[1b]` 阶段会校验这些表的完整性（21 条用例）。


---

## 排障

| 现象 | 原因 |
|---|---|
| 一直超时 | ① 目的 IP 不是设备 set0 的本机 IP（准入不过，静默丢弃）<br>② UDP 端口不是 `CMD_UDP_PORT` 的当前值<br>③ `CFG_CMD_PORT_SEL` 选的是另一口，你连错了网口 |
| `BAD_ITEM` | ITEM 编号不对；`0x56` / `0x62` / `0x63` 已删除 |
| `BAD_SET` | 档索引超过该口该 ITEM 的份数 —— 先 `geom` 查 |
| `BAD_LEN` | SET 的 `LEN` 必须精确等于值宽（GET 只查上界） |
| `READ_ONLY` | 对状态/统计/边界类（`0x51~0x72`）发 SET |
| `WRITE_ONLY` | 对动作类（`0x40~0x43`）发 GET |
| 改完 `CMD_UDP_PORT` 连不上 | 端口改错；只能靠上电复位回默认 `0xC0DE` |
| Web 页面连不上后端 | 后端没起；或浏览器访问的不是 `127.0.0.1` |
| 虚拟设备报「端口已被占用」 | 已有 vdev 在跑（Windows 下曾因 `SO_REUSEADDR` 出现双实例抢包，现已改为绑失败即报错） |

`CFG_CMD_PORT_SEL` 在 `RTL/Config/cfg_map.vh` 里，默认 `0`。
