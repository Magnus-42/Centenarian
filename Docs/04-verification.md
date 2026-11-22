# 验证指南

## 在参考板上打流

1. 用 `subsys_test_top` 运行综合和实现，确认布线完成、时序满足约束，然后生成位流。
2. 用兼容的 100G 光模块接通 A/B 两口。两口可直连，或通过能双向转发测试流量的交换机连接。
3. 在 Vivado Hardware Manager 下载 `.bit`，关联同一构建的 `.ltx` 并刷新器件。确认能看到 VIO、ILA，且两口链路均已就绪。
4. 在 Vivado Tcl Console 中切到仓库的上一级目录。将 `usr` 替换为实际仓库目录名。

```tcl
source usr/Scripts/hw_ila_vio.tcl
hw_run scall
```

脚本依次检查通道连通性、单通道线速、发送优先级和兜底分流。四项及总判定均为 `PASS` 时，本次脚本测试通过。UDP(IPV6) 打流用 `udp_ipv6` 双向测试目的端口 2，用 `fb_udp_ipv6` 双向测试目的端口 `0x1234`。VIO 探针 24–27 依次控制 A/B 口命中和 A/B 口兜底测试。 [2026-11-22 IPv4 版上板记录](Results/scall_2026-11-22.txt)

找不到探针时，检查 `.bit` 与 `.ltx` 是否来自同一次构建。通道连通性失败时，运行 `hw_run sc1`，按失败项检查发送口、接收口和分流规则。手动中断测试后，运行 `hw_run set 0` 停止打流。
