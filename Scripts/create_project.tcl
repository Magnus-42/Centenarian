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
#          -tclargs -top subsys_test_top -jobs 8 [-synth] [-ooc] [-name <工程名>] [-xdc <约束名>] [-force]
#
#   -top    综合顶层，默认 subsys_test_top
#            可选：subsys_test_top / cmac_test_top / ipv4_test_top / net_stack_top / 你自己的顶层
#   -jobs   并行线程数，默认 4
#   -synth  建完工程后立即启动 synth_1（默认不启动）
#   -ooc    IP 生成产物后额外跑 OOC 综合（很慢，默认不跑）
#   -name   工程名，默认取「外层目录名」
#   -force  外层已存在同名工程时，删除并重建（**会丢弃该工程的 runs 结果**，慎用）
#   -xdc    强制启用指定的 XDC（可省略 .xdc 后缀），默认启用与 -top 同名的那个；
#            产品顶层（如 net_stack_top）复用某个板级顶层引脚约束时用它，例如
#              vivado -mode batch -source ... -tclargs -top net_stack_top -xdc subsys_test_top
#
# 说明：本脚本**复用仓库里已提交的 .xci 配置**（<源码目录>/IP/*/*.xci），
#       不手写 CMAC 的 CONFIG 参数 —— IP 定制项很多，手抄极易与实际板卡不一致。
#
# RTL 收集：**按目录全深度递归**（RTL/A/B/C/*.v 都在内），自动跳过任一层级的
#       `Backup/` 与以 `.` 开头的目录 —— 因此 RTL 分层（Bsp/Axis、Transport/Udp/Ipv4 …）
#       增减层级都不需要改脚本。
# ============================================================================

# ---------- 参数解析 ----------
set TOP        "subsys_test_top"
set JOBS       4
set RUN_SYNTH  0
set RUN_OOC    0
set PRJ_NAME   ""
set FORCE      0
set XDC_FORCE  ""
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -exact -- [lindex $argv $i] {
        -top   { incr i; set TOP       [lindex $argv $i] }
        -jobs  { incr i; set JOBS      [lindex $argv $i] }
        -name  { incr i; set PRJ_NAME  [lindex $argv $i] }
        -xdc   { incr i; set XDC_FORCE [lindex $argv $i] }
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
if {[string equal $SRC_DIR $PROJ_DIR] ||
    !([file isdirectory [file join $SRC_DIR RTL]] ||
      [file isdirectory [file join $SRC_DIR XDC]] ||
      [file isdirectory [file join $SRC_DIR IP]])} {
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

# ---------- 递归收集 HDL 源文件 ----------
#   dir       : 起始目录
#   exts      : 扩展名白名单（小写，如 {.v .sv}）
#   skip_dirs : 任一层级都要跳过的目录名（如 Backup）
# 说明：不限层级 —— RTL 分层怎么加都不会漏；隐藏目录（.xxx）一律跳过。
proc collect_hdl_files {dir exts skip_dirs} {
    set out [list]
    if {![file isdirectory $dir]} { return $out }
    foreach f [lsort [glob -nocomplain -directory $dir -type f *]] {
        if {[lsearch -exact $exts [string tolower [file extension $f]]] >= 0} {
            lappend out $f
        }
    }
    foreach d [lsort [glob -nocomplain -directory $dir -type d *]] {
        set base [file tail $d]
        if {[string index $base 0] eq "."} { continue }
        if {[lsearch -exact $skip_dirs $base] >= 0} { continue }
        foreach f [collect_hdl_files $d $exts $skip_dirs] { lappend out $f }
    }
    return $out
}

# ---------- 加入 RTL（源码目录下的 RTL/，全深度递归，跳过历史备份）----------
if {![file isdirectory $RTL_DIR]} { error "未找到 RTL 目录：$RTL_DIR" }
set rtl_files [collect_hdl_files $RTL_DIR {.v .sv} {Backup}]
if {[llength $rtl_files] == 0} { error "未在 $RTL_DIR 下找到任何 .v/.sv 文件" }
add_files -norecurse -fileset sources_1 $rtl_files
puts "  RTL : [llength $rtl_files] 个源文件（来自 $RTL_DIR，递归全深度）"
# 按「RTL 下一级目录」分组统计 —— 漏扫/多扫一眼可见
array set _rtl_cnt {}
foreach f $rtl_files {
    set rel     [lrange [file split $f] [llength [file split $RTL_DIR]] end]
    set top_dir [expr {[llength $rel] > 1 ? [lindex $rel 0] : "<RTL 根>"}]
    if {[info exists _rtl_cnt($top_dir)]} { incr _rtl_cnt($top_dir) } else { set _rtl_cnt($top_dir) 1 }
}
foreach k [lsort [array names _rtl_cnt]] {
    puts [format "        - %-16s %2d" $k $_rtl_cnt($k)]
}
unset _rtl_cnt

# ---------- 重复模块定义自检 ----------
# 搬目录 / 改名后最容易出现「同一模块被两份文件定义」（Vivado 会静默挑一个），这里提前拦。
array set _mod_seen {}
set _dup_cnt 0
foreach f $rtl_files {
    set _fh [open $f r]
    set _src [read $_fh]
    close $_fh
    foreach {- m} [regexp -all -line -inline {^[ \t]*module[ \t]+([A-Za-z_][A-Za-z0-9_]*)} $_src] {
        if {[info exists _mod_seen($m)]} {
            puts "  WARNING: 模块 $m 重复定义 —— [file tail $_mod_seen($m)] 与 [file tail $f]"
            incr _dup_cnt
        } else {
            set _mod_seen($m) $f
        }
    }
}
puts "  模块自检: [array size _mod_seen] 个模块名，重复定义 $_dup_cnt 处"
unset _mod_seen

# ---------- 加入约束 ----------
# 引脚/时钟约束与「板级顶层」一一对应：默认启用与 -top 同名的 XDC；
# 可用 -xdc <名> 覆盖（例如 -top net_stack_top -xdc subsys_test_top）。
# 其余 *_test_top.xdc 一律置为禁用，避免多个引脚约束互相冲突。
set xdc_enable "${TOP}.xdc"
if {[string trim $XDC_FORCE] ne ""} {
    set xdc_enable [string trim $XDC_FORCE]
    if {![string match "*.xdc" $xdc_enable]} { append xdc_enable ".xdc" }
}
set xdc_files [glob -nocomplain -directory $XDC_DIR -type f *.xdc]
if {[llength $xdc_files] > 0} {
    add_files -norecurse -fileset constrs_1 $xdc_files
    puts "  XDC : [llength $xdc_files] 个约束文件（来自 $XDC_DIR），启用目标 = $xdc_enable"
    set _xdc_hit 0
    foreach f $xdc_files {
        set _base [file tail $f]
        if {[string equal $_base $xdc_enable]} {
            set_property IS_ENABLED true [get_files $f]
            puts "        - $_base（启用）"
            set _xdc_hit 1
        } elseif {[string match "*_test_top.xdc" $_base]} {
            set_property IS_ENABLED false [get_files $f]
            puts "        - $_base（已禁用：不是本次的目标约束）"
        } else {
            puts "        - $_base（通用约束，保持启用）"
        }
    }
    if {!$_xdc_hit} {
        puts "        WARNING: 没有找到 $xdc_enable —— 本次不会加载任何引脚约束"
        puts "                 若顶层是产品顶层（如 net_stack_top），请用 -xdc <板级顶层名> 指定复用哪套引脚约束"
    }
} else {
    puts "  WARNING: 未找到 XDC，将无引脚/时钟约束"
}

# ---------- 加入模块级约束（XDC/*.tcl：文件名 = 作用模块名，如 axis_fifo_async.tcl）----------
# 约定：文件名（去扩展名）必须等于被约束模块名 —— SCOPED_TO_REF 直接取它；
#       若该模块在 RTL 里不存在，SCOPED_TO_REF 会指向空对象，这里提前告警。
set _rtl_mods {}
foreach f $rtl_files { lappend _rtl_mods [file rootname [file tail $f]] }
set tcl_cstr_files [glob -nocomplain -directory $XDC_DIR -type f *.tcl]
foreach f $tcl_cstr_files {
    add_files -norecurse -fileset constrs_1 $f
    set _base [file rootname [file tail $f]]
    set_property SCOPED_TO_REF    $_base                                [get_files $f]
    set_property PROCESSING_ORDER LATE                                  [get_files $f]
    set_property USED_IN          {synthesis implementation simulation} [get_files $f]
    if {[lsearch -exact $_rtl_mods $_base] >= 0} {
        puts "  CSTR: [file tail $f]（SCOPED_TO_REF=$_base，USED_IN=synthesis/implementation/simulation，PROCESSING_ORDER=LATE）"
    } else {
        puts "  CSTR: [file tail $f]（SCOPED_TO_REF=$_base）  WARNING: RTL 中未找到同名模块，约束将不生效"
    }
}

# ---------- 加入 IP（复用已提交的 .xci：<源码目录>/IP 下任意深度的 *.xci）----------
set ip_files [list]
if {[file isdirectory $IP_DIR]} {
    set ip_files [collect_hdl_files $IP_DIR {.xci} {Backup}]
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

# ---------- 设置顶层（精确匹配文件名，兜底按 module 声明查找）----------
set top_file ""
foreach f $rtl_files {
    if {[string equal [file tail $f] "${TOP}.v"]} { set top_file $f; break }
}
if {$top_file eq ""} {
    # 文件名与模块名不一致时（非本仓库约定，但允许）按 "module <TOP>" 声明查找
    set _pat [format {(^|\n)\s*module\s+%s\s*[#(;]} $TOP]
    foreach f $rtl_files {
        set _fh [open $f r]
        set _src [read $_fh]
        close $_fh
        if {[regexp $_pat $_src]} { set top_file $f; break }
    }
}
if {$top_file eq ""} {
    error "未在 RTL 中找到顶层 ${TOP}（既没有 ${TOP}.v，也没有 module ${TOP} 声明）——请检查 -top 参数或 RTL 目录"
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
