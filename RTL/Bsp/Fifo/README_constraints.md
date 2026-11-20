# 异步 FIFO 时序约束

对应当前 RTL，分别提供：

| 文件 | 本层负责的路径 |
|---|---|
| fifo_async_constraints.tcl | 两组Gray读写指针；两域复位同步器的原始异步复位脚；分布式RAM到实际读域捕获寄存器的数据路径 |
| fifo_async_fwft_constraints.tcl | 额外的实际消费Gray指针，底层仍需加载fifo_async约束 |
| axis_fifo_async_constraints.tcl | 完整包Gray计数，底层两种FIFO的约束也需加载 |
| load_fifo_async_constraints.tcl | 一次加载以上三份文件，推荐使用 |

这些是 Vivado 的**非托管 Tcl 约束脚本**，不是可直接用 read_xdc 导入的 XDC。Vivado XDC 只允许有限的 Tcl 内建命令，不能执行按实例逐条检查所需的循环。脚本不修改RTL，也不自动创建或猜测时钟。

## 非工程模式

先综合当前RTL、加载顶层真实时钟约束，再执行：

```tcl
source RTL/Bsp/Fifo/load_fifo_async_constraints.tcl
opt_design
place_design
phys_opt_design
route_design
report_cdc -details -file fifo_cdc.rpt
report_exceptions -ignored -file fifo_ignored.rpt
report_bus_skew -file fifo_bus_skew.rpt
```

路径以上述工程根目录为当前目录。若只实例化 fifo_async，可仅 source fifo_async_constraints.tcl；单独使用 fifo_async_fwft 需加载 core+FWFT 两份，AXIS 则加载三份。加载全部三份也可，未使用的类型会打印匹配数量0。

## Vivado工程模式

不将这几个 Tcl 文件作为普通 XDC 加入 constraints fileset。可将加载器设置为实现流程的 opt_design 前置脚本：

```tcl
set_property STEPS.OPT_DESIGN.TCL.PRE \
  [file normalize RTL/Bsp/Fifo/load_fifo_async_constraints.tcl] \
  [get_runs impl_1]
```

如果已有前置脚本，不要覆盖它：在已有脚本中 source 加载器。进行综合后分析时，open_run synth_1 后也要手动 source 加载器，之后再报告CDC和例外。

通过 load_fifo_async_constraints.tcl 一次加载对应约束，避免重复加载。若需要固定对象的 XDC，可在约束已应用后使用 write_xdc 导出该具体网表的约束；导出结果包含当前设计其他约束，不宜当作通用FIFO约束复用。

## 选择范围与预算

- 全局加载，脚本按父模块的 ORIG_REF_NAME/REF_NAME 及实际第一级同步器筛选，不要求固定的顶层实例名。支持当前 Vivado 的 rebuilt/none 层级和带数组下标的 generate 实例。不要设置 SCOPED_TO_REF，也不要完全展平并抹除这些模块边界。
- Gray源寄存器时钟脚C到第一级同步器D使用 set_max_delay -datapath_only。多位总线同时设置 set_bus_skew，预算取实际源、目的时钟的较短周期。命令从合法时序起点开始，不在组合逻辑或层次引脚上截断路径。
- 同步器的第二级D及其后本域逻辑继续正常进行setup/hold检查。ASYNC_REG、SHREG_EXTRACT由RTL保留。
- 原始srst只对wr_rst_sync/rd_rst_sync自身的PRE/CLR脚建立例外，不对全部功能寄存器的复位脚一刀切，也不屏蔽本域同步释放后的恢复/移除时序。
- 分布式RAM数据先追踪到真正的读域捕获寄存器，再从RAM写时钟脚施加 datapath_only 延迟预算。last RAM到rd_last输出寄存器由此获得明确预算，后续包控制逻辑仍正常计时。消费者必须遵守FIFO有效/空标志或AXIS握手，约束本身不能修复错误的消费协议。
- 组合数据直接到达顶层端口、不同读时钟的消费者或其他未识别终点时，会打印 FIFO_XDC_INTERFACE，留给顶层接口延迟约束处理，不猜测板级时序、不对组合输出作路径截断。

不要在同一对时钟之间增加全局 set_clock_groups -asynchronous 或全局 set_false_path；它们优先级更高，会覆盖Gray总线的max_delay。无关的跨域路径应单独约束。脚本不会给FIFO以外的同名寄存器建立例外。

## 检查结果如何理解

日志中的 FIFO_XDC_GRAY、FIFO_XDC_RESET、FIFO_XDC_LUTRAM 给出实际对象和数量；关键时钟或目标丢失时会报错。必须同时检查 report_exceptions -ignored，确认没有更高优先级例外覆盖这些约束。

report_cdc 仍可能把多位Gray标成CDC-6、把按指针保护的RAM数据标成CDC-1。这些结构不自动waiver；应结合Gray约束、FIFO地址所有权及RAM数据稳定协议审查，不能只以告警数量判断是否安全。

本次验证针对 xcvu37p-fsvh2892-2L-e / Vivado 2025.2，涵盖普通distributed/block FIFO、FWFT、四种AXIS存储组合、多实例/不同频率/generate层次，以及一组小规模布局布线。没有替代用户完整工程的I/O预算、真实时钟树和400MHz时序签核。

官方依据：
- [AMD：XDC支持的Tcl范围及非托管Tcl脚本](https://docs.amd.com/r/2023.1-English/ug903-vivado-using-constraints/About-XDC-Constraints)
- [AMD：异步路径约束及例外优先级](https://docs.amd.com/r/2022.2-English/ug903-vivado-using-constraints/Constraining-Asynchronous-Signals)
- [AMD：避免路径截断，使用寄存器时钟脚作为起点](https://docs.amd.com/r/en-US/ug903-vivado-using-constraints/Path-Segmentation)
