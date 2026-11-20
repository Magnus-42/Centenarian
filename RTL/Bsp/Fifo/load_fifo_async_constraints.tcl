# 在综合后且顶层时钟已定义时source本文件；也可作为impl_1的OPT_DESIGN前置脚本。
set fifo_constraint_dir [file dirname [file normalize [info script]]]
foreach fifo_constraint_file {
  fifo_async_constraints.tcl
  fifo_async_fwft_constraints.tcl
  axis_fifo_async_constraints.tcl
} {
  source [file join $fifo_constraint_dir $fifo_constraint_file]
}
