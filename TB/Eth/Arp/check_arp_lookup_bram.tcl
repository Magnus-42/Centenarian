# 本文件位于 <仓库根>/TB/Eth/Arp/ 下 -> 仓库根为三级父目录
set repo_root [file normalize [file join [file dirname [info script]] .. .. ..]]
set report_dir [file join $repo_root build bram_check]

file mkdir $report_dir

# 读取依赖文件(arp_lookup 及其依赖的 sdp_bram)
read_verilog [file join $repo_root RTL Bsp Bram sdp_bram.v]
read_verilog [file join $repo_root RTL Eth Arp arp_lookup.v]

# 独立综合 arp_lookup
synth_design \
    -top axis_fifo_async \
    -part xcvu37p-fsvh2892-2L-e \
    -flatten_hierarchy none

# 生成报告
report_utilization \
    -hierarchical \
    -file [file join $report_dir utilization.rpt]

report_ram_utilization \
    -file [file join $report_dir ram.rpt]

# 直接打印 primitive 数量
puts "RAMB18E1=[llength [get_cells -hierarchical -quiet \
    -filter {REF_NAME == RAMB18E1}]]"

puts "RAMB36E1=[llength [get_cells -hierarchical -quiet \
    -filter {REF_NAME == RAMB36E1}]]"

puts "LUTRAM=[llength [get_cells -hierarchical -quiet \
    -filter {PRIMITIVE_SUBGROUP == DRAM}]]"

exit