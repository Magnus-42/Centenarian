# -----------------------------------------------------------------------------
# File Name   : fifo_async_fwft_constraints.tcl
# Description : FWFT附加约束：实际消费Gray指针；底层另加载fifo_async_constraints.tcl
# Note        : 先创建时钟，在综合后用source加载；也可作为impl_1的OPT_DESIGN前置脚本。
#               按父模块类型和实际同步器选择路径，不依赖顶层实例名。
# -----------------------------------------------------------------------------
set fifo_xdc_kind fifo_async_fwft
set fifo_xdc_groups [dict create]
set fifo_xdc_roots [dict create]
set fifo_xdc_applied 0
set fifo_xdc_payload_total 0
foreach fifo_xdc_ff [get_cells -quiet -hier -regexp {.*wr_consume_ptr_gray_sync_d1_reg(\[[0-9]+\])?}] {
  set fifo_xdc_name [get_property NAME $fifo_xdc_ff]
  set fifo_xdc_slash [string last / $fifo_xdc_name]
  set fifo_xdc_parent [string range $fifo_xdc_name 0 [expr {$fifo_xdc_slash-1}]]
  if {$fifo_xdc_slash < 0} {
    set fifo_xdc_parent ""
    set fifo_xdc_ref [get_property TOP [current_design]]
  } else {
    set fifo_xdc_obj [get_cells -quiet $fifo_xdc_parent]
    if {[llength $fifo_xdc_obj] != 1} {error "FIFO_XDC: missing hierarchy for $fifo_xdc_name; use rebuilt/none hierarchy"}
    set fifo_xdc_ref [get_property -quiet ORIG_REF_NAME $fifo_xdc_obj]
    if {$fifo_xdc_ref eq ""} {set fifo_xdc_ref [get_property REF_NAME $fifo_xdc_obj]}
  }
  if {$fifo_xdc_ref ne $fifo_xdc_kind && ![regexp [format {^%s_+[0-9]+$} $fifo_xdc_kind] $fifo_xdc_ref]} {continue}
  regsub {\[[0-9]+\]$} $fifo_xdc_name {} fifo_xdc_key
  dict lappend fifo_xdc_groups $fifo_xdc_key $fifo_xdc_ff
}

# Gray源寄存器的C到第一级同步器D：限定传播时间及位间偏斜。
dict for {fifo_xdc_key fifo_xdc_cells} $fifo_xdc_groups {
  set fifo_xdc_dst [get_pins -of_objects $fifo_xdc_cells -filter {REF_PIN_NAME == D}]
  set fifo_xdc_starts [all_fanin -flat -startpoints_only -to $fifo_xdc_dst]
  set fifo_xdc_src_cells [get_cells -of_objects $fifo_xdc_starts]
  set fifo_xdc_src [get_pins -of_objects $fifo_xdc_src_cells -filter {REF_PIN_NAME == C}]
  set fifo_xdc_dst_c [get_pins -of_objects $fifo_xdc_cells -filter {REF_PIN_NAME == C}]
  set fifo_xdc_sclks [get_clocks -quiet -of_objects $fifo_xdc_src]
  set fifo_xdc_mclks [get_clocks -quiet -of_objects $fifo_xdc_dst_c]
  if {[llength $fifo_xdc_src] == 0 || [llength $fifo_xdc_sclks] == 0 || [llength $fifo_xdc_mclks] == 0} {
    error "FIFO_XDC: clocks/registered Gray source missing for $fifo_xdc_key; define clocks first"
  }
  set fifo_xdc_budget 1.0e30
  foreach fifo_xdc_clk [concat $fifo_xdc_sclks $fifo_xdc_mclks] {
    set fifo_xdc_period [get_property PERIOD $fifo_xdc_clk]
    if {$fifo_xdc_period <= 0} {error "FIFO_XDC: invalid clock period on $fifo_xdc_clk"}
    set fifo_xdc_budget [expr {min($fifo_xdc_budget,$fifo_xdc_period)}]
  }
  set_max_delay $fifo_xdc_budget -datapath_only -from $fifo_xdc_src -to $fifo_xdc_dst
  if {[llength $fifo_xdc_dst] >= 2 && [llength $fifo_xdc_src] >= 2} {
    set_bus_skew $fifo_xdc_budget -from $fifo_xdc_src -to $fifo_xdc_dst
  }
  # datapath_only不使用异步时钟相位，保留第二级同步器正常setup/hold。
  set fifo_xdc_slash [string last / $fifo_xdc_key]
  set fifo_xdc_parent [string range $fifo_xdc_key 0 [expr {$fifo_xdc_slash-1}]]
  if {$fifo_xdc_slash < 0} {set fifo_xdc_parent ""}
  if {[string match *wr_ptr_gray_sync_d1_reg $fifo_xdc_key]} {
    dict set fifo_xdc_roots $fifo_xdc_parent $fifo_xdc_mclks
  }
  incr fifo_xdc_applied
  puts "FIFO_XDC_GRAY $fifo_xdc_kind $fifo_xdc_key bits=[llength $fifo_xdc_dst] budget_ns=$fifo_xdc_budget"
}

puts "FIFO_XDC_DONE $fifo_xdc_kind gray_buses=$fifo_xdc_applied"
