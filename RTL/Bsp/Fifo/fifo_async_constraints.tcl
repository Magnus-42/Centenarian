# -----------------------------------------------------------------------------
# File Name   : fifo_async_constraints.tcl
# Description : 普通异步FIFO：读写Gray指针、复位同步器及分布式RAM数据通路
# Note        : 先创建时钟，在综合后用source加载；也可作为impl_1的OPT_DESIGN前置脚本。
#               按父模块类型和实际同步器选择路径，不依赖顶层实例名。
# -----------------------------------------------------------------------------
set fifo_xdc_kind fifo_async
set fifo_xdc_groups [dict create]
set fifo_xdc_roots [dict create]
set fifo_xdc_applied 0
set fifo_xdc_payload_total 0
foreach fifo_xdc_ff [get_cells -quiet -hier -regexp {.*(rd_wr_ptr_gray|wr_rd_ptr_gray)_sync_d1_reg(\[[0-9]+\])?}] {
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
  if {[string match *rd_wr_ptr_gray_sync_d1_reg $fifo_xdc_key]} {
    dict set fifo_xdc_roots $fifo_xdc_parent $fifo_xdc_mclks
  }
  incr fifo_xdc_applied
  puts "FIFO_XDC_GRAY $fifo_xdc_kind $fifo_xdc_key bits=[llength $fifo_xdc_dst] budget_ns=$fifo_xdc_budget"
}

# 只对复位同步器自身的异步PRE/CLR脚切断恢复/移除检查。
# 不切断wr_arst/rd_arst到功能寄存器的本域复位释放检查。
set fifo_xdc_reset_cells {}
foreach fifo_xdc_reset_ff [get_cells -quiet -hier -regexp {.*(wr|rd)_rst_sync_reg(\[[0-9]+\])?}] {
  set fifo_xdc_reset_name [get_property NAME $fifo_xdc_reset_ff]
  set fifo_xdc_reset_parent [string range $fifo_xdc_reset_name 0 [expr {[string last / $fifo_xdc_reset_name]-1}]]
  set fifo_xdc_reset_obj [get_cells -quiet $fifo_xdc_reset_parent]
  if {[llength $fifo_xdc_reset_obj] != 1} {continue}
  set fifo_xdc_reset_ref [get_property -quiet ORIG_REF_NAME $fifo_xdc_reset_obj]
  if {$fifo_xdc_reset_ref eq ""} {set fifo_xdc_reset_ref [get_property REF_NAME $fifo_xdc_reset_obj]}
  if {![regexp {^axis_fifo_async(_+[0-9]+)?$} $fifo_xdc_reset_ref]} {continue}
  lappend fifo_xdc_reset_cells $fifo_xdc_reset_ff
}
if {[llength $fifo_xdc_reset_cells] > 0} {
  set fifo_xdc_reset_pins [get_pins -of_objects $fifo_xdc_reset_cells -filter {REF_PIN_NAME == PRE || REF_PIN_NAME == CLR}]
  set_false_path -to $fifo_xdc_reset_pins
  puts "FIFO_XDC_RESET axis_shared_async_pins=[llength $fifo_xdc_reset_pins]"
}

# Gray指针保护有效读取，避免同地址读写碰撞；空FIFO写入不属于有效读取。
# 禁用RAM内部WCLK到输出的异步弧；读地址到输出仍正常计时。
set fifo_xdc_all_mem [get_cells -quiet -hier -filter {IS_PRIMITIVE && PRIMITIVE_LEVEL != MACRO && REF_NAME =~ RAM* && REF_NAME !~ RAMB*}]
dict for {fifo_xdc_parent fifo_xdc_read_clks} $fifo_xdc_roots {
  set fifo_xdc_mem {}
  foreach fifo_xdc_cell $fifo_xdc_all_mem {
    set fifo_xdc_name [get_property NAME $fifo_xdc_cell]
    if {$fifo_xdc_parent eq "" || [string first ${fifo_xdc_parent}/ $fifo_xdc_name] == 0} {lappend fifo_xdc_mem $fifo_xdc_cell}
  }
  if {[llength $fifo_xdc_mem] == 0} {continue}
  set fifo_xdc_mem_q [get_pins -of_objects $fifo_xdc_mem -filter {DIRECTION == OUT}]
  set fifo_xdc_mem_clk [get_pins -of_objects $fifo_xdc_mem -filter {REF_PIN_NAME == CLK || REF_PIN_NAME == WCLK}]
  set fifo_xdc_mem_clks [get_clocks -quiet -of_objects $fifo_xdc_mem_clk]
  if {[llength $fifo_xdc_mem_clk] == 0 || [llength $fifo_xdc_mem_clks] == 0} {error "FIFO_XDC: LUTRAM clock missing at $fifo_xdc_parent"}
  set fifo_xdc_endpoints [all_fanout -flat -endpoints_only -from $fifo_xdc_mem_q]
  set fifo_xdc_capture {}
  set fifo_xdc_ports 0
  set fifo_xdc_other 0
  foreach fifo_xdc_ep $fifo_xdc_endpoints {
    if {[get_property CLASS $fifo_xdc_ep] eq "port"} {incr fifo_xdc_ports;continue}
    set fifo_xdc_cap_cell [get_cells -quiet -of_objects $fifo_xdc_ep]
    if {[llength $fifo_xdc_cap_cell] != 1} {continue}
    if {![string match FD* [get_property REF_NAME $fifo_xdc_cap_cell]]} {incr fifo_xdc_other;continue}
    set fifo_xdc_cap_clks [get_clocks -quiet -of_objects [get_pins -of_objects $fifo_xdc_cap_cell -filter {REF_PIN_NAME == C}]]
    set fifo_xdc_matches 0
    foreach fifo_xdc_clk $fifo_xdc_cap_clks {
      if {[lsearch -exact $fifo_xdc_read_clks $fifo_xdc_clk] >= 0} {set fifo_xdc_matches 1}
    }
    if {$fifo_xdc_matches} {lappend fifo_xdc_capture $fifo_xdc_ep} else {incr fifo_xdc_other}
  }
  set fifo_xdc_capture [lsort -unique $fifo_xdc_capture]
  if {[llength $fifo_xdc_capture] > 0} {
    foreach fifo_xdc_cell $fifo_xdc_mem {
      set fifo_xdc_wclk [get_pins -of_objects $fifo_xdc_cell -filter {REF_PIN_NAME == WCLK || REF_PIN_NAME == CLK}]
      set fifo_xdc_q [get_pins -of_objects $fifo_xdc_cell -filter {DIRECTION == OUT}]
      foreach fifo_xdc_clk_pin $fifo_xdc_wclk {
        foreach fifo_xdc_q_pin $fifo_xdc_q {
          set_disable_timing -from [get_property REF_PIN_NAME $fifo_xdc_clk_pin] \
              -to [get_property REF_PIN_NAME $fifo_xdc_q_pin] $fifo_xdc_cell
        }
      }
    }
    incr fifo_xdc_payload_total [llength $fifo_xdc_capture]
    puts "FIFO_XDC_LUTRAM $fifo_xdc_parent captures=[llength $fifo_xdc_capture] write_clock_arcs_disabled=[llength $fifo_xdc_mem]"
  }
  if {$fifo_xdc_ports > 0 || $fifo_xdc_other > 0} {
    puts "FIFO_XDC_INTERFACE $fifo_xdc_parent ports=$fifo_xdc_ports other_endpoints=$fifo_xdc_other : require top-level interface timing budgets"
  }
}

puts "FIFO_XDC_DONE $fifo_xdc_kind gray_buses=$fifo_xdc_applied"
