# 核心仿真回归

这里保留 11 项可复现测试，供修改 RTL 后发现功能回退，也供读者了解接口用法。
测试含 AI 辅助编写内容；可信依据是独立判据、明确覆盖范围和可复现结果。
旧接口与重复用例已移除，历史内容可从 Git 找回；本集合不等同于旧测试的全部覆盖。

## 运行

需要 Python 3.10+ 和 Vivado 的 `xvlog`、`xelab`、`xsim`，已验证版本为 2025.2。
从仓库根目录执行；Vivado 已加入 PATH 时可省略 `--vivado-bin`。

```sh
python TB/run.py --vivado-bin "D:/2025.2/Vivado/bin"
python TB/run.py --list
python TB/run.py --test tb_cfg_port_top tb_udp_ipv6_top
```

也可用环境变量 `VIVADO_BIN` 指定工具目录。`--jobs 2` 同时运行两个用例；
`--timeout 600` 设置每个工具阶段的墙钟超时秒数，默认 600。

通过需同时满足：编译、精化和仿真正常结束，无错误信息，且出现对应的最终
`PASS: <测试名>`。错误、缺少标记或超时均返回非零退出码。
每次运行冻结受测源码，SHA256、逐阶段日志和 `summary.json` 保存到
`build/tb/<UTC时间戳>/`，不写回 RTL。

可选检查测试本身是否能发现错误：

```sh
python TB/run.py --mutation-check
```

先运行正常回归，再仅在独立副本中破坏 skid 的 keep、配置响应和 UDP4 校验和。
三项都须在仿真中触发指定断言并报告 `DETECTED`；编译失败或超时不算检出。
这只能验证所列判据能捕捉这些错误。

## 检查范围

| 测试名（省略 `tb_`） | 主要判据 |
| --- | --- |
| `fifo_sync` | 独立队列；满空、计数、指针回绕、分布式/块 RAM、非二次幂深度、复位 |
| `axis_buffers` | skid 与同步/异步 FIFO；逐拍 data/keep/usr/last、包模式、反压、复位恢复 |
| `value_rr_arbiter` | 独立扫描模型；数值优先、同值轮询、无请求、刷新保持、寄存参数 |
| `axis_value_rr_arbiter` | 包内锁定、同值轮询顺序、各路顺序与全部字段、反压稳定性 |
| `cfg_port_top` | GET/SET、字节序、错误码、坏帧丢弃、清表动作、恢复默认、复位恢复 |
| `arp_engine_top` | 请求/应答整帧、学习与命中、网关、免费 ARP、坏帧、广播、清表 |
| `icmpv4_top` | echo/other 分流；应答地址、校验和和载荷；业务并发发送、反压稳定性 |
| `udp_ipv4_top` | 独立计算 IPv4/UDP 首部与校验和；逐字节收发、端口分流、边界、复位 |
| `udp_ipv6_top` | 独立计算 IPv6/UDP 首部与校验和；逐字节收发、端口分流、边界、复位 |
| `arp_announce_integration` | 双口启动宣告、软件触发、配置错误、排队与端口隔离 |
| `udp_ipv6_integration` | 实际板级顶层；双口回环、四路 IPv6 打流、配置和分流更新/恢复 |

UDP4 测试载荷至 32768 B（当前 TX 包 FIFO 容量），UDP6 至 65527 B。
两者覆盖TX空载荷、RX空载荷丢弃及跨拍边界、校验和计算值为零时编码为 FFFF。
接收测试按当前接口约定检查：不验证 UDP 校验和，IP 层裁剪 Ethernet 最小帧填充，UDP 层沿用上游载荷边界；
RX无载荷单拍报文静默丢弃，UDP6 的 Next Header 由上级 IP 分流；剥头模块信任上游协议字段。
这些行为记录当前约定，不代表完整协议合规性。

`Top/ip_sim/` 是 CMAC 与 SLR 的功能替身；集成测试还提供时钟、VIO、ILA 替身，
ARP 定时器使用加速参数。它们不验证真实 IP 时延、SerDes/FEC、线速或实际链路。
本集合也不替代综合、STA、CDC 检查、上板验证及完整异常包/参数组合测试；
MAC、IPv4 各子模块和 ARP 哈希冲突等场景尚无完整独立回归。
上板步骤见 [验证指南](../Docs/04-verification.md)，报文约定见 [配置协议](../Docs/05-config-command.md)。

## 后续维护

- 改 RTL 后运行相关用例；合并 main 或发布前运行全部用例。
- 修 bug 时先加能复现问题的用例，再验证修复；参考结果从协议或接口约定推导。
- 只有接口约定改变时才改期望值，同时更新说明；不要为得到 PASS 放宽判据。
- 新用例登记到 `run.py`，检查内容、包数、反压和超时，末尾统一输出成功标记。
- 遇到自己无法确认的测试，先标注未验证并移出默认回归，核实后再纳入。

最近一次整理的验证记录见 [2026-11-23](Results/2026-11-23.md)。
