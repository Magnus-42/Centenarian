# -------------------------------------------------------------------------
# Scoped TCL Constraints for axis_fifo_async                —— v3（2026-09-23 落盘）
# 备份: Centenarian.user/XDC/axis_fifo_async.tcl.bak_20260923_2305
#
# 作用:
#   1. 自动提取 sclk / mclk 实际周期，对格雷码指针 / 包计数同步链设
#      set_max_delay -datapath_only（真 CDC 路径，异步时钟间 hold 无意义）
#   2. 动态识别异步复位引脚类型 (PRE/CLR)，避免硬编码 S/R
#   3. 逐节自检 + SUMMARY 打印，便于在 runme.log 里直接确认约束命中
# -------------------------------------------------------------------------

# =========================================================================
# 0. scope 定位
# =========================================================================
if {[catch {set _scope [current_instance .]}]} {
    set _scope "<top-level>"
}
set _warn_prefix {WARNING: [axis_fifo_async.tcl] }
append _warn_prefix "scope=$_scope : "

if {$_scope eq "<top-level>"} {
    puts "${_warn_prefix}当前未处于 scoped 上下文！-hierarchical 将跨实例命中，请确认 XDC 的 ScopedToRef=axis_fifo_async"
}

# =========================================================================
# 1. 提取两端时钟周期
# =========================================================================
set wr_clk_regs [get_cells -quiet -hierarchical -filter {NAME =~ *wr_ptr_bin_reg*}]
set rd_clk_regs [get_cells -quiet -hierarchical -filter {NAME =~ *rd_ptr_bin_reg*}]

set wr_period 0
set rd_period 0

if {$wr_clk_regs != ""} {
    set wr_clk [get_clocks -quiet -of_objects $wr_clk_regs]
    if {$wr_clk != ""} {
        set _pl [lsort -real [get_property PERIOD $wr_clk]]
        set wr_period [expr {[llength $_pl] ? [lindex $_pl 0] : 0}]
    }
}
if {$wr_period <= 0} {
    puts "${_warn_prefix}未能从 wr_ptr_bin_reg* 提取写时钟周期，请检查 sclk 是否约束"
}

if {$rd_clk_regs != ""} {
    set rd_clk [get_clocks -quiet -of_objects $rd_clk_regs]
    if {$rd_clk != ""} {
        set _pl [lsort -real [get_property PERIOD $rd_clk]]
        set rd_period [expr {[llength $_pl] ? [lindex $_pl 0] : 0}]
    }
}
if {$rd_period <= 0} {
    puts "${_warn_prefix}未能从 rd_ptr_bin_reg* 提取读时钟周期，请检查 mclk 是否约束"
}

# =========================================================================
# 2. 读时钟域 (mclk) -> 写时钟域 (sclk) 的同步约束
# =========================================================================
if {$wr_period > 0} {
    set dst_rd_ptr [get_cells -quiet -hierarchical -filter {NAME =~ *rd_ptr_gray_sync_0_reg*}]
    set src_rd_ptr [get_cells -quiet -hierarchical -filter {NAME =~ *rd_ptr_gray_reg* || NAME =~ *rd_ptr_bin_reg*}]

    if {$src_rd_ptr == "" && $dst_rd_ptr != ""} {
        set _nets [get_nets -quiet -of_objects \
                        [get_pins -quiet -of_objects $dst_rd_ptr -filter {REF_PIN_NAME == D}]]
        set src_rd_ptr [get_cells -quiet -of_objects \
                            [get_pins -quiet -of_objects $_nets -filter {DIRECTION == OUT}]]
        if {$src_rd_ptr == ""} {
            set src_rd_ptr [get_cells -quiet -of_objects $_nets]
        }
    }

    if {[llength $src_rd_ptr] < [llength $dst_rd_ptr]} {
        puts "${_warn_prefix}rd_ptr 源寄存器数([llength $src_rd_ptr])少于目的([llength $dst_rd_ptr])，可能漏抓取！"
    }

    if {$src_rd_ptr != "" && $dst_rd_ptr != ""} {
        set_max_delay -datapath_only -from $src_rd_ptr -to $dst_rd_ptr $wr_period
    } else {
        puts "${_warn_prefix}rd_ptr 源/目的集为空(src=[llength $src_rd_ptr], dst=[llength $dst_rd_ptr])，读->写方向同步约束未生效"
    }
}

# =========================================================================
# 3. 写时钟域 (sclk) -> 读时钟域 (mclk) 的同步约束
# =========================================================================
if {$rd_period > 0} {
    # 3.1 写指针跨域
    set dst_wr_ptr [get_cells -quiet -hierarchical -filter {NAME =~ *wr_ptr_gray_sync_0_reg*}]
    set src_wr_ptr [get_cells -quiet -hierarchical -filter {NAME =~ *wr_ptr_gray_reg* || NAME =~ *wr_ptr_bin_reg*}]

    if {$src_wr_ptr == "" && $dst_wr_ptr != ""} {
        set _nets [get_nets -quiet -of_objects \
                        [get_pins -quiet -of_objects $dst_wr_ptr -filter {REF_PIN_NAME == D}]]
        set src_wr_ptr [get_cells -quiet -of_objects \
                            [get_pins -quiet -of_objects $_nets -filter {DIRECTION == OUT}]]
        if {$src_wr_ptr == ""} {
            set src_wr_ptr [get_cells -quiet -of_objects $_nets]
        }
    }

    if {[llength $src_wr_ptr] < [llength $dst_wr_ptr]} {
        puts "${_warn_prefix}wr_ptr 源寄存器数([llength $src_wr_ptr])少于目的([llength $dst_wr_ptr])，可能漏抓取！"
    }

    if {$src_wr_ptr != "" && $dst_wr_ptr != ""} {
        set_max_delay -datapath_only -from $src_wr_ptr -to $dst_wr_ptr $rd_period
    } else {
        puts "${_warn_prefix}wr_ptr 源/目的集为空(src=[llength $src_wr_ptr], dst=[llength $dst_wr_ptr])，写->读方向同步约束未生效"
    }

    # 3.2 写包计数器跨域 (PACKET_FIFO 模式)
    # PACKET_FIFO=0 时该组寄存器被优化掉，取空集属正常，不打告警。
    set dst_wr_pkt [get_cells -quiet -hierarchical -filter {NAME =~ *wr_pkt_cnt_gray_sync_0_reg*}]
    if {$dst_wr_pkt != ""} {
        set src_wr_pkt [get_cells -quiet -hierarchical -filter {NAME =~ *wr_pkt_cnt_gray_reg* || NAME =~ *wr_pkt_cnt_bin_reg*}]
        if {$src_wr_pkt == ""} {
            set _nets [get_nets -quiet -of_objects \
                            [get_pins -quiet -of_objects $dst_wr_pkt -filter {REF_PIN_NAME == D}]]
            set src_wr_pkt [get_cells -quiet -of_objects \
                                [get_pins -quiet -of_objects $_nets -filter {DIRECTION == OUT}]]
        }
        if {$src_wr_pkt != ""} {
            set_max_delay -datapath_only -from $src_wr_pkt -to $dst_wr_pkt $rd_period
        } else {
            puts "${_warn_prefix}wr_pkt_cnt 源集为空，包计数跨域约束未生效"
        }
    }

    # =========================================================================
    # 4. LUTRAM 异步读出路径的 CDC 约束
    # =========================================================================
    set dst_data_regs [get_cells -quiet -hierarchical \
        -filter {(NAME =~ *axis_m*_direct_reg* || NAME =~ *axis_m*_do_reg*) && IS_SEQUENTIAL == 1}]

    set lutram_cells [get_cells -quiet -hierarchical \
        -filter {NAME =~ *ram_* && (REF_NAME =~ RAMD* || REF_NAME =~ RAMS*)}]

    if {$lutram_cells != "" && $dst_data_regs != ""} {
        set_max_delay -datapath_only -from $lutram_cells -to $dst_data_regs $rd_period
    } elseif {$lutram_cells != "" && $dst_data_regs == ""} {
        puts "${_warn_prefix}检测到 LUTRAM 但目标捕获寄存器集为空，LUTRAM 跨域约束无法生效"
    }
}

# =========================================================================
# 5. 复位同步器的 False Path
# =========================================================================
set mrst_sync_regs [get_cells -quiet -hierarchical -filter {NAME =~ *mrst_d*_reg*}]
if {$mrst_sync_regs != ""} {
    set async_rst_pins [get_pins -quiet -of_objects $mrst_sync_regs -filter {IS_PRESET == 1 || IS_CLEAR == 1}]
    if {$async_rst_pins != ""} {
        set_false_path -to $async_rst_pins
    } else {
        puts "${_warn_prefix}mrst_d* 上未找到 PRE/CLR 管脚，复位同步器 false_path 未生效"
    }
} else {
    puts "${_warn_prefix}未找到 mrst_d*_reg，复位同步器 false_path 未生效"
}

# =========================================================================
# 6. 写域复位同步链的 False Path
# =========================================================================
set wrst_sync_regs [get_cells -quiet -hierarchical -filter {NAME =~ *srst_d*_reg* || NAME =~ *wrst_d*_reg* || NAME =~ *srst_sync*_reg*}]
if {$wrst_sync_regs != ""} {
    set wrst_async_pins [get_pins -quiet -of_objects $wrst_sync_regs -filter {IS_PRESET == 1 || IS_CLEAR == 1}]
    if {$wrst_async_pins != ""} {
        set_false_path -to $wrst_async_pins
    } else {
        puts "${_warn_prefix}找到写域复位链但无 PRE/CLR 管脚，请复核复位同步器写法"
    }
}

# =========================================================================
# 7. 自检摘要
# 预期: wr_period=3.103 (322.269MHz GT侧)  rd_period=2.500 (400MHz clk_200m)
#       任一为 0 => 对应小节被跳过
#       规模预期: src_rd/src_wr ≈ 2N(gray+bin)，dst ≈ N(sync_0)
# =========================================================================
puts "${_warn_prefix}SUMMARY wr_period=$wr_period rd_period=$rd_period \
src_rd=[llength $src_rd_ptr] dst_rd=[llength $dst_rd_ptr] \
src_wr=[llength $src_wr_ptr] dst_wr=[llength $dst_wr_ptr] \
src_wr_pkt=[llength $src_wr_pkt] dst_wr_pkt=[llength $dst_wr_pkt] \
lutram=[llength $lutram_cells](仅统计不约束) mrst=[llength $mrst_sync_regs]"
