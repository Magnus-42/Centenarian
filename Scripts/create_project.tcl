# ============================================================================
# Centenarian · 快速建工程脚本（外层建工程，内层只放源码）
# ----------------------------------------------------------------------------
# 目录约定（本脚本位于「源码目录」的 Scripts/ 下，源码目录名字任意）：
#
#   <工作区>/                          ← 外层：Vivado 工程创建在这里
#   ├── <工程名>.xpr
#   ├── <工程名>.runs/  <工程名>.cache/  <工程名>.gen/ …（Vivado 生成）
#   └── <源码目录>/                     ← 内层：只有用户源码，如 usr/ 或 Centenarian.user/
#       ├── RTL/  TB/  XDC/  IP/  Docs/
#       └── Scripts/
#           ├── create_project.tcl      ← 本脚本
#           └── hw_ila_vio.tcl
#
#   脚本按「自己所在位置」推导内层与外层，因此内层文件夹叫什么都行。
#
# 用法（在“外层”目录下执行，或给绝对路径）：
#   vivado -mode batch -source <源码目录>/Scripts/create_project.tcl \
#          -tclargs -top subsys_test_top -jobs 8 [-synth] [-ooc] [-name <工程名>] [-force]
#
#   -top    综合顶层，默认 subsys_test_top
#            可选：subsys_test_top / cmac_test_top / ipv4_test_top / 你自己的顶层
#   -jobs   并行线程数，默认 4
#   -synth  建完工程后立即启动 synth_1（默认不启动）
#   -ooc    IP 生成产物后额外跑 OOC 综合（很慢，默认不跑）
#   -name   工程名，默认取「外层目录名」
#   -force  外层已存在同名工程时，删除并重建（**会丢弃该工程的 runs 结果**，慎用）
#
# 说明：本脚本**复用仓库里已提交的 .xci 配置**（<源码目录>/IP/*/*.xci），
#       不手写 CMAC 的 CONFIG 参数 —— IP 定制项很多，手抄极易与实际板卡不一致。
# ============================================================================

# ---------- 参数解析 ----------
set TOP        "subsys_test_top"
set JOBS       4
set RUN_SYNTH  0
set RUN_OOC    0
set PRJ_NAME   ""
set FORCE      0
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -exact -- [lindex $argv $i] {
        -top   { incr i; set TOP      [lindex $argv $i] }
        -jobs  { incr i; set JOBS     [lindex $argv $i] }
        -name  { incr i; set PRJ_NAME [lindex $argv $i] }
        -synth { set RUN_SYNTH 1 }
        -ooc   { set RUN_OOC   1 }
        -force { set FORCE     1 }
        default { puts "WARNING: 忽略未知参数 [lindex $argv $i]" }
    }
}

# ---------- 路径推导（与文件夹名字无关）----------
#   SCRIPT_DIR = <源码目录>/Scripts
#   SRC_DIR    = <源码目录>          ← 内层：只放源码
#   PROJ_DIR   = <工作区>            ← 外层：工程创建在这里
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set SRC_DIR    [file dirname $SCRIPT_DIR]
set PROJ_DIR   [file dirname $SRC_DIR]
# 目录特征校验：内层必须像"源码目录"（含有 RTL/ 或 XDC/ 或 IP/），否则说明脚本位置不对
if {[string equal $SRC_DIR $PROJ_DIR] ||     !([file isdirectory [file join $SRC_DIR RTL]] ||       [file isdirectory [file join $SRC_DIR XDC]] ||       [file isdirectory [file join $SRC_DIR IP]])} {
    error "脚本位置不符合约定：应放在 <工作区>/<源码目录>/Scripts/ 下（当前脚本在 $SCRIPT_DIR，推到内层=$SRC_DIR）"
}
if {[string trim $PRJ_NAME] eq ""} { set PRJ_NAME [file tail $PROJ_DIR] }

set RTL_DIR  [file join $SRC_DIR RTL]
set XDC_DIR  [file join $SRC_DIR XDC]
set IP_DIR   [file join $SRC_DIR IP]
set XPR      [file join $PROJ_DIR ${PRJ_NAME}.xpr]
set PART     "xcvu37p-fsvh2892-2L-e"

puts "=============================================="
puts " Centenarian 工程创建"
puts " 脚本位置 : $SCRIPT_DIR"
puts " 源码目录 : $SRC_DIR        （内层，只有源码）"
puts " 工程目录 : $PROJ_DIR       （外层，工程建在这里）"
puts " 工程名   : $PRJ_NAME"
puts " 顶层     : $TOP"
puts " 器件     : $PART"
puts "=============================================="

# ---------- 保护已有工程 ----------
if {[file exists $XPR] && !$FORCE} {
    puts ""
    puts "!! 已存在同名工程：$XPR"
    puts "!! 若只是要使用现有工程，请直接打开它："
    puts "!!     vivado $XPR"
    puts "!! 若确实要重建（会丢弃现有 runs 结果），请先备份外层工程文件，再加 -force 重跑。"
    error "工程已存在，已中止（未改动任何文件）"
}

# ---------- 建工程（外层）----------
create_project -force $PRJ_NAME $PROJ_DIR -part $PART
set_property target_language  Verilog [current_project]
set_property default_lib      work    [current_project]
set_property source_mgmt_mode All     [current_project]   ;# 引用源文件而非拷贝进工程目录

if {$JOBS > 1} { set_param general.maxThreads $JOBS }

# ---------- 加入 RTL（源码目录下的 RTL/，递归两层，跳过历史备份）----------
if {![file isdirectory $RTL_DIR]} { error "未找到 RTL 目录：$RTL_DIR" }
set rtl_files [list]
foreach f [glob -nocomplain -directory $RTL_DIR -type f *.v] { lappend rtl_files $f }
foreach d [glob -nocomplain -directory $RTL_DIR -type d *] {
    if {[string equal [file tail $d] "Backup"]} { continue }   ;# 跳过历史备份目录
    foreach f [glob -nocomplain -directory $d -type f *.v] { lappend rtl_files $f }
    foreach sd [glob -nocomplain -directory $d -type d *] {
        foreach f [glob -nocomplain -directory $sd -type f *.v] { lappend rtl_files $f }
    }
}
if {[llength $rtl_files] == 0} { error "未在 $RTL_DIR 下找到任何 .v 文件" }
add_files -norecurse -fileset sources_1 $rtl_files
puts "  RTL : [llength $rtl_files] 个 .v 文件（来自 $RTL_DIR）"

# ---------- 加入约束 ----------
set xdc_files [glob -nocomplain -directory $XDC_DIR -type f *.xdc]
if {[llength $xdc_files] > 0} {
    add_files -norecurse -fileset constrs_1 $xdc_files
    puts "  XDC : [llength $xdc_files] 个约束文件（来自 $XDC_DIR）"
    # 引脚约束与顶层一一对应：仅启用与当前顶层同名的 XDC，其余 *_test_top.xdc 置为禁用（避免引脚约束冲突）
    foreach f $xdc_files {
        set _base [file tail $f]
        if {[string equal $_base "${TOP}.xdc"]} {
            puts "        - $_base（启用：与顶层 $TOP 匹配）"
        } elseif {[string match "*_test_top.xdc" $_base]} {
            set_property IS_ENABLED false [get_files $f]
            puts "        - $_base（已禁用：与顶层 $TOP 不匹配）"
        } else {
            puts "        - $_base"
        }
    }
} else {
    puts "  WARNING: 未找到 XDC，将无引脚/时钟约束"
}

# ---------- 加入模块级约束（XDC/*.tcl：文件名 = 作用模块名，如 axis_fifo_async.tcl）----------
set tcl_cstr_files [glob -nocomplain -directory $XDC_DIR -type f *.tcl]
foreach f $tcl_cstr_files {
    add_files -norecurse -fileset constrs_1 $f
    set _base [file rootname [file tail $f]]
    set_property SCOPED_TO_REF    $_base                                [get_files $f]
    set_property PROCESSING_ORDER LATE                                  [get_files $f]
    set_property USED_IN          {synthesis implementation simulation} [get_files $f]
    puts "  CSTR: [file tail $f]（SCOPED_TO_REF=$_base，USED_IN=synthesis/implementation/simulation，PROCESSING_ORDER=LATE）"
}

# ---------- 加入 IP（复用已提交的 .xci：<源码目录>/IP/*/*.xci）----------
set ip_files [list]
if {[file isdirectory $IP_DIR]} {
    foreach d [glob -nocomplain -directory $IP_DIR -type d *] {
        foreach f [glob -nocomplain -directory $d -type f *.xci] { lappend ip_files $f }
    }
    if {[llength $ip_files] == 0} {
        foreach f [glob -nocomplain -directory $IP_DIR -type f *.xci] { lappend ip_files $f }
    }
}
if {[llength $ip_files] > 0} {
    import_ip $ip_files
    puts "  IP  : [llength $ip_files] 个 .xci（来自 $IP_DIR）"
    foreach f $ip_files { puts "        - [file tail $f]" }
} else {
    puts "  WARNING: 未在 $IP_DIR 找到 .xci，需先在 Vivado 里定制 CMAC / clk_wiz / vio / axis_slr_crossing"
}

# ---------- 生成 IP 输出产物 ----------
if {[llength $ip_files] > 0} {
    generate_target all [get_ips]
    puts "  IP 输出产物已生成"
    if {$RUN_OOC} {
        synth_ip [get_ips] -force
        puts "  IP OOC 综合完成"
    }
}

# ---------- 设置顶层 ----------
set top_file [lindex [get_files -all -of_objects [get_filesets sources_1] "*${TOP}.v"] 0]
if {$top_file eq ""} {
    puts "  WARNING: 未找到 ${TOP}.v，请手动设置顶层"
} else {
    set_property top      $TOP      [current_fileset]
    set_property top_file $top_file [current_fileset]
    puts "  顶层已设置: $TOP ($top_file)"
}

update_compile_order -fileset sources_1
puts "  工程已创建: $XPR"

# ---------- 可选：启动综合 ----------
if {$RUN_SYNTH} {
    puts "  启动 synth_1 ..."
    launch_runs synth_1 -jobs $JOBS
    wait_on_run synth_1
    puts "  synth_1 完成"
}

puts "=============================================="
puts " 完成。GUI 打开： vivado $XPR"
puts "=============================================="
