# ============================================================================
# hw_ila_vio.tcl —— subsys_test_top 上板控制：VIO 使能 + ILA 探针读取 + 场景化验证
#
# 依赖：Vivado（2025.2 验证，其余版本命令一致）+ 板卡经 JTAG 连到本机 hw_server。
#
# 标准用法：在 Vivado GUI 里下载 bit 与 ltx（Hardware Manager → Program Device /
#         刷新调试核）之后，直接在 Tcl Console 输入：
#             source ./Scripts/hw_ila_vio.tcl
#         脚本会自动连上 hw_server、枚举调试核、打印使能位映射与可用命令；
#         之后用 hw_run <命令...> 逐条调用即可（也可用 -tclargs 一次性批处理）。
#
# 命令一览（多条按顺序执行）：
#   list                 列出 VIO 位映射、VIO/ILA 探针识别情况与归类表
#   map                  只打印「打流机 → 计数种类」归类表（核对 ILA 拓扑用）
#   vionames             诊断：打印 VIO 核与全部探针的真实名称、可用属性、当前输出值
#   iladiag              诊断：打印 ILA 触发相关属性、采集上传结果、探针原始值与解析值
#   csvpeek              诊断：打印本次采集导出的 CSV 的前两行（核对列名与数值格式）
#   paths                打印「路径统计」：各分支/策略实际被走到的次数（清理死代码用）
#   refresh              重新枚举调试核（重新下载 bit 后调用）
#   bit  <file>          下载 bitstream
#   set  <num>           按 23 位位图设置使能（支持 0x 十六进制），如 set 0x5
#   on   <名|位>...      打开指定使能，其余位保持不变，如 on en_a_udp en_b_udp
#   off  <名|位>...      关闭指定使能
#   read [filter]        立即触发一次 ILA 采集并打印探针值（filter 为名称子串）
#   csv  <file> [f]      同 read，并把原始波形另存为 CSV
#   monitor <n> [f]      连续采集 n 次（间隔约 1 秒），只打印匹配探针
#
#   —— 场景化验证（自动完成「设使能 → 等待 → 采集 → 判定」，输出 PASS/FAIL）——
#   sc1 [settle]         场景 1 · 通道连通性：逐位单开，核对收端打流机与错误计数
#   sc2 [chan...] [s]    场景 2 · 单通道线速：双向同开，换算线速并与门限比较
#   sc3 [settle]         场景 3 · 严格优先级：自高向低逐路关闭，核对独占与饿死
#   sc4 [settle]         场景 4 · 未匹配通道：四个兜底探测位，核对落档与错误计数
#   scall [settle]       依次跑 sc1~sc4 并给出总判定表
#
# 示例：
#   source ./Scripts/hw_ila_vio.tcl          # GUI：连接 + 打印映射与命令
#   hw_run sc1                               # 逐路连通性全自动核对
#   hw_run sc2 udp icmp ospf                 # 只测这三个通道的双向线速
#   hw_run scall 3                           # 全部场景，每步稳定 3 秒
#   hw_run on en_a_udp monitor 10 rx_bw      # 手工：开 A 口 UDP，连采 10 次
#   hw_run set 0                             # 手工：全部关闭
#
# 批处理等价写法：
#   vivado -mode batch -source Scripts/hw_ila_vio.tcl -tclargs scall 3
# ============================================================================

# ---- 日志降噪 ----
# 每次 ILA 采集都会打印两条 INFO（trigger was armed / triggered），逐路验证时刷屏且无信息量；
# 这里静音掉。需要恢复时执行：
#   reset_msg_config -id {Labtools 27-1964}
#   reset_msg_config -id {Labtools 27-1966}
if {![info exists ::QUIET_ILA_MSG]} { set ::QUIET_ILA_MSG 1 }
if {$::QUIET_ILA_MSG} {
  foreach mid {Labtools 27-1964 Labtools 27-1966} {
    catch { set_msg_config -id $mid -suppress }
  }
}

# ---- 编码自检（脚本为 UTF-8；被按系统编码误读时中文日志会乱码，但不影响功能）----
if {[string length "通道"] != 2} {
  puts "\[hw\] NOTE: script is UTF-8 but was decoded as '[encoding system]';"
  puts "\[hw\]       Chinese log text may look garbled (functions unaffected)."
  puts "\[hw\]       batch mode fix: source -encoding utf-8 Scripts/hw_ila_vio.tcl"
}

# ---- 连接参数（按环境修改）----
if {![info exists ::HW_URL ]} { set ::HW_URL  "localhost:3121" }

# ---- 帧与判定参数（与 RTL/Top/subsys_test_top.v 的本地参数保持一致）----
if {![info exists ::FRAME_BYTES   ]} { set ::FRAME_BYTES    1024 }
# 满载总线吞吐参考值（B/s，1024B 帧实测值），用于"背景流量 vs 真残留"的比例判据
if {![info exists ::BW_FULL_REF   ]} { set ::BW_FULL_REF   12213921472 } ;# PKT_LEN_BEATS(16) × 64B
# 线速换算的"额外长度"（字节）：按打流机所在层次
#   MAC 层  +24（前导码/SFD 8 + FCS 4 + IFG 12）
#   IPv4/IPv6  +38（= 24 + 14 以太网首部，打流机发的是完整 IP 包）
#   UDP        +58（= 38 + 20 IPv4 首部，打流机发的是 UDP 载荷）
if {![info exists ::CHAN_OVH]} {
  set ::CHAN_OVH {udp 58 fb_udp 58 ipv4_06 38 icmp 38 ospf 38 ip6icmp 38 ip6ospf 38 \
                  fb_ipv4 38 fb_ipv6 38 mac_88b5 24 mac_88cc 24 fb_mac 24}
}
if {![info exists ::LINE_TH_GBPS  ]} { set ::LINE_TH_GBPS   99.0 } ;# 线速判定门限 (Gbps)
if {![info exists ::STARVE_RATIO  ]} { set ::STARVE_RATIO   0.05 } ;# 低优先级「饿死」判据(占线速比)
# 「另有通道计数非零」是否判 WARN：本环境交换机流量会自然落进部分通道（其使能未开），
# 默认只作提示；要让该现象计入 WARN 时置 1
if {![info exists ::STRICT_EXTRA  ]} { set ::STRICT_EXTRA    0 }
# 「全关基线」判据：残留吞吐低于全速的这个比例时视为背景流量（交换机零星帧），不计为残留
if {![info exists ::BASE_LEAK_RATIO]} { set ::BASE_LEAK_RATIO 0.005 }
if {![info exists ::DEFAULT_SETTLE]} { set ::DEFAULT_SETTLE 3.0  } ;# 使能后等待秒数(计数每秒锁存)

# ---- VIO 位 → 使能名（与 RTL/Top/subsys_test_top.v 的 probe_out 注释一致）----
set ::EN_NAMES {
  en_a_udp      en_a_icmp     en_a_ospf     en_a_ipv4_06  en_a_mac_88b5
  en_b_udp      en_b_icmp     en_b_ospf     en_b_ipv4_06  en_b_mac_88b5
  en_a_ip6icmp  en_a_ip6ospf  en_b_ip6icmp  en_b_ip6ospf
  en_a_fb_mac   en_a_fb_ipv4  en_a_fb_ipv6  en_a_fb_udp
  en_b_mac_88cc en_b_fb_mac   en_b_fb_ipv4  en_b_fb_ipv6 en_b_fb_udp
}

# ---- 23 台打流机例化名（与 subsys_test_top.v 一致；用于把 ILA 探针归到"哪台"）----
set ::TESTERS {
  u_ta_udp      u_ta_icmp     u_ta_ospf     u_ta_ipv4_06  u_ta_mac_88b5
  u_ta_ip6icmp  u_ta_ip6ospf
  u_ta_fb_mac   u_ta_fb_ipv4  u_ta_fb_ipv6  u_ta_fb_udp
  u_tb_udp      u_tb_icmp     u_tb_ospf     u_tb_ipv4_06  u_tb_mac_88b5
  u_tb_mac_88cc u_tb_ip6icmp  u_tb_ip6ospf
  u_tb_fb_mac   u_tb_fb_ipv4  u_tb_fb_ipv6  u_tb_fb_udp
}

# ---- 打流机统计寄存器 → 简称（长名在前，避免子串误判）----
set ::CNT_KEYS {
  {rx_bw_bytes_per_s bw}
  {rx_pkt_per_s      pkt}
  {rx_error_cnt      err}
  {rx_len_err_cnt    lenerr}
  {debug_rx_lock     lock}
}

# ---- 通道分组 ----
set ::DUAL_CHANS {udp icmp ospf ipv4_06 mac_88b5 ip6icmp ip6ospf} ;# A/B 两侧都有的
set ::FB_CHANS   {fb_mac fb_ipv4 fb_ipv6 fb_udp}                   ;# 未匹配兜底探测
# 场景 3 的通道优先级（自高向低）：取自 RTL/Top/subsys_test_top.v 的 PRIO_* 常量
#   OSPF 13 > ICMPv4 12(A)/11(B) > UDP 8(A)/9(B) > MAC-88B5 6(A)/5(B) > 兜底探测 2
set ::PRIO_ORDER {ospf icmp udp mac_88b5 fb_ipv4}

proc log {m} { puts "\[hw\] $m" }

# ---------------------------------------------------------------------------
# 路径统计埋点：记录各分支实际被走到的次数（用于清理死代码 / 定位环境差异）
#   mark <key> [detail]  累加一次；detail 记录首次出现时的细节
# ---------------------------------------------------------------------------
proc mark {key {detail ""}} {
  if {[info exists ::MARK($key)]} {
    incr ::MARK($key)
  } else {
    set ::MARK($key) 1
  }
  if {$detail ne "" && ![info exists ::MARK_D($key)]} { set ::MARK_D($key) $detail }
  return
}

proc mark_reset {} {
  array unset ::MARK
  array unset ::MARK_D
}

proc mark_report {{title {}}} {
  if {[info exists ::MARK_QUIET] && $::MARK_QUIET && $title ne ""} { return }
  if {$title ne ""} { log "---- 路径统计: $title ----" }
  if {![info exists ::MARK] || [array size ::MARK] == 0} { log "（本次没有任何埋点记录）"; return }
  foreach k [lsort [array names ::MARK]] {
    set d ""
    if {[info exists ::MARK_D($k)]} { set d "  ← $::MARK_D($k)" }
    puts [format "  %-34s %6d%s" $k $::MARK($k) $d]
  }
}

# ----------------------------------------------------------------------------
# 连接 JTAG / 枚举调试核
# ----------------------------------------------------------------------------
proc hw_connect {} {
  # 已连接过且器件仍在，直接复用（避免反复 source 时重复连接）
  if {[info exists ::HW_READY] && $::HW_READY} {
    catch {
      if {[llength [get_hw_devices]] > 0} {
        set ::VIOS [get_hw_vios]
        set ::ILAS [get_hw_ilas]
        return
      }
    }
    set ::HW_READY 0
  }
  if {[catch {connect_hw_server -url $::HW_URL}]} {
    catch {disconnect_hw_server}
    connect_hw_server -url $::HW_URL
  }
  set tgts [get_hw_targets]
  if {[llength $tgts] == 0} { error "没有找到 JTAG target，请确认板卡与 hw_server" }
  open_hw_target [lindex $tgts 0]
  set devs [get_hw_devices]
  if {[llength $devs] == 0} { error "没有找到器件" }
  current_hw_device [lindex $devs 0]
  refresh_hw_device [current_hw_device]
  set ::HW_READY 1

  set ::VIOS [get_hw_vios]
  set ::ILAS [get_hw_ilas]
  vio_cache_clear
  log "器件: [current_hw_device]  VIO 核: [llength $::VIOS] 个  ILA 核: [llength $::ILAS] 个"
  if {[llength $::VIOS] == 0} { log "警告: 未发现 VIO（bit 是否含 vio_enable？）" }
  if {[llength $::ILAS] == 0} { log "警告: 未发现 ILA（bit 是否含调试核 / ltx 是否已刷新？）" }
  if {[llength $::VIOS] > 0} {
    set wp [vio_out_prop]
    if {$wp eq ""} {
      log "警告: 未找到 VIO 输出可写属性（hw_run vionames 可查看属性列表）"
    } else {
      log "VIO 写输出属性: $wp"
    }
  }
}

# 等待 sec 秒（打流机统计每 1 秒锁存一次，切换使能后必须等够）
proc sleep_s {sec} {
  catch {update}
  after [expr {int($sec * 1000)}]
  catch {update}
}

# ----------------------------------------------------------------------------
# VIO：位图读写
# ----------------------------------------------------------------------------
# 清空 VIO / ILA 侧缓存（重新下载 bit 或刷新调试核后调用）
proc vio_cache_clear {} {
  unset -nocomplain ::VIO_MAP_D
  unset -nocomplain ::VIO_OUT_PROP
  unset -nocomplain ::VIO_BM
  array unset ::TP
  array unset ::PNK
  array unset ::CSV_VALS
  set ::N_PROBE 0
  set ::CSV_READY 0
  unset -nocomplain ::ILA_DATA
  unset -nocomplain ::CSV_ERR
  unset -nocomplain ::CSV_FILE
}

# 返回 位号 → 探针对象 的 dict。
# 识别方式：探针名 / 路径里的"使能网络名"（en_x_yyy）——
# 本工程 Vivado 2025.2 下 get_hw_probes 返回的 NAME 就是网络名。
# 注意：其返回顺序是「按名称排序」而非位号顺序，因此不做顺序兜底，避免静默错位。
proc vio_map {} {
  if {[info exists ::VIO_MAP_D] && [dict size $::VIO_MAP_D]} { return $::VIO_MAP_D }
  set map [dict create]
  if {![info exists ::VIOS] || [llength $::VIOS] == 0} { return $map }

  set probes {}
  if {[catch {set probes [get_hw_probes -of_objects $::VIOS]} e]} {
    log "读取 VIO 探针失败: $e（可先执行 hw_run refresh）"
    return $map
  }
  if {[llength $probes] == 0} { return $map }

  # 探针名即"使能网络名"（本工程实测命名，形如 u_test_vio_enable/en_a_udp）
  foreach p $probes {
    set txt ""
    foreach prop {NAME PATH FULL_NAME LONG_NAME} {
      if {![catch {get_property $prop $p} v]} { append txt "$v " }
    }
    set i 0
    foreach en $::EN_NAMES {
      if {[string first $en $txt] >= 0} { dict set map $i $p }
      incr i
    }
  }

  set ::VIO_MAP_D $map
  mark "vioident.netname" "[dict size $map] 位"
  if {[dict size $map] != [llength $::EN_NAMES]} {
    log "警告: 识别到 [dict size $map] 位 VIO 输出探针（期望 [llength $::EN_NAMES] 位），可用 vionames 核对"
  }
  return $map
}

proc vio_bit_probes {} {
  set pairs {}
  foreach n [lsort -integer [dict keys [vio_map]]] { lappend pairs $n [dict get [vio_map] $n] }
  return $pairs
}

proc vio_probe_of {bit} {
  set map [vio_map]
  if {[dict exists $map $bit]} { return [dict get $map $bit] }
  return ""
}

# ---------------------------------------------------------------------------
# 自动发现「写 VIO 输出」用的属性名
# 不同 Vivado 版本 / 核类型下属性名可能是 OUTPUT / OUTPUT_VALUE / VALUE ...
# 且 get_property 读回未必可行，因此这里用 list_property + 试写来确定。
# ---------------------------------------------------------------------------
proc vio_out_prop {{p {}}} {
  if {[info exists ::VIO_OUT_PROP] && $::VIO_OUT_PROP ne ""} { return $::VIO_OUT_PROP }
  if {$p eq ""} {
    set probe_list [get_hw_probes -of_objects $::VIOS]
    if {[llength $probe_list] == 0} { return "" }
    set p [lindex $probe_list 0]
  }
  # 试写探测（不 commit，不改动硬件）：本工程实测 OUTPUT 不存在、OUTPUT_VALUE 可写
  foreach c {OUTPUT OUTPUT_VALUE} {
    if {![catch {set_property $c 0 $p}]} {
      set ::VIO_OUT_PROP $c
      mark "viowrite.prop.$c"
      return $c
    }
  }
  mark "viowrite.prop.none"
  set ::VIO_OUT_PROP ""
  return ""
}

proc vio_props_note {} {
  set probe_list [get_hw_probes -of_objects $::VIOS]
  if {[llength $probe_list] == 0} { log "VIO 没有探针"; return }
  set p [lindex $probe_list 0]
  set props {}
  catch {set props [list_property $p]}
  log "VIO 探针可用属性: [join $props {, }]"
  set wp [vio_out_prop $p]
  if {$wp eq ""} {
    log "未找到可写的输出属性（这是一个异常，请反馈上面的属性列表）"
  } else {
    log "写输出使用属性: $wp"
  }
}

# 诊断：打印 VIO 核与全部探针的真实名称（位映射异常时用）
proc vio_diag {} {
  set probe_list {}
  catch {set probe_list [get_hw_probes -of_objects $::VIOS]}
  log "VIO 核: [llength $::VIOS] 个, 探针 [llength $probe_list] 个"
  set wp [vio_out_prop]
  if {$wp eq ""} { vio_props_note } else { log "写输出使用属性: $wp" }
  if {[llength $probe_list] > 0} {
    set props {}
    catch {set props [list_property [lindex $probe_list 0]]}
    log "探针可用属性: [join $props {, }]"
  }
  foreach p $probe_list {
    set nm "-"
    catch {set nm [get_property NAME $p]}
    set o "-"
    if {$wp ne ""} { catch {set o [get_property $wp $p]} }
    puts [format "    NAME=%-30s %s=%s" $nm [expr {$wp eq "" ? "OUTPUT" : $wp}] $o]
  }
  vio_cache_clear
  set pairs [vio_bit_probes]
  if {[llength $pairs] == 0} {
    log "  → 未识别出任何 VIO 输出探针位号（请把上面的 NAME 列表反馈）"
  } else {
    log "  → 已识别 [expr {[llength $pairs] / 2}] 位输出探针（按位号升序）"
  }
  return [expr {[llength $pairs] / 2}]
}

# 重新枚举调试核（重新下载 bit 后调用；GUI 里需重新打开 ILA / VIO 仪表盘）
proc hw_refresh {} {
  if {![info exists ::HW_READY] || !$::HW_READY} { hw_connect; return }
  if {[catch {refresh_hw_device [current_hw_device]} e]} { log "refresh_hw_device 失败: $e" }
  # 调试核没能枚举出来时，重新打开 JTAG target 再试一次
  if {[llength [get_hw_vios]] == 0 || [llength [get_hw_ilas]] == 0} {
    log "调试核未枚举出来，尝试重新打开 JTAG target ..."
    catch {close_hw_target}
    catch {open_hw_target [lindex [get_hw_targets] 0]}
    catch {current_hw_device [lindex [get_hw_devices] 0]}
    catch {refresh_hw_device [current_hw_device]}
  }
  set ::VIOS [get_hw_vios]
  set ::ILAS [get_hw_ilas]
  vio_cache_clear
  log "已刷新器件: VIO 核 [llength $::VIOS] 个, ILA 核 [llength $::ILAS] 个"
  if {[llength [get_hw_vios]] > 0} {
    log "VIO 探针: [llength [get_hw_probes -of_objects [get_hw_vios]]] 个（可执行 hw_run vionames 查看名称）"
  }
  log "提示: 若 GUI 里 ILA / VIO 仪表盘消失，在 Hardware Manager 中重新打开即可"
}

# 读回当前位图；属性不可读时回退到脚本影子值，返回 "" 表示未知
proc vio_get {} {
  set wp [vio_out_prop]
  if {$wp eq ""} { return "" }
  set cur 0
  foreach {n p} [vio_bit_probes] {
    if {[catch {get_property $wp $p} v]} { return "" }
    if {$v eq "true" || $v == 1} { set cur [expr {$cur | (1 << $n)}] }
  }
  set ::VIO_BM $cur
  mark "vioread.ok"
  return $cur
}

proc vio_set {bitmap} {
  set pairs [vio_bit_probes]
  if {[llength $pairs] == 0} {
    error "没有可用的 VIO 输出探针：bit/ltx 是否已下载并刷新？可先执行 hw_run vionames 或 hw_run refresh"
  }
  set wp [vio_out_prop]
  if {$wp eq ""} {
    error "找不到可写的 VIO 输出属性：请执行 hw_run vionames 查看探针属性列表并反馈"
  }
  set ps {}
  foreach {n p} $pairs {
    set_property $wp [expr {($bitmap >> $n) & 1}] $p
    lappend ps $p
  }
  commit_hw_vio $ps
  set ::VIO_BM $bitmap
  log [format "VIO 使能位图 -> 0x%06X（%d 路）" $bitmap [popcount $bitmap]]
  return $bitmap
}

# 只写某一位（on/off 用）：不依赖读回，也不会动到其它位
proc vio_poke {bit val} {
  set p [vio_probe_of $bit]
  if {$p eq ""} { error "位 $bit 没有对应的 VIO 输出探针（可执行 hw_run vionames 核对）" }
  set wp [vio_out_prop]
  if {$wp eq ""} { error "找不到可写的 VIO 输出属性（可执行 hw_run vionames）" }
  set_property $wp $val $p
  commit_hw_vio [list $p]
  if {![info exists ::VIO_BM]} { set ::VIO_BM 0 }
  if {$val} { set ::VIO_BM [expr {$::VIO_BM | (1 << $bit)}] } \
  else       { set ::VIO_BM [expr {$::VIO_BM & ~(1 << $bit)}] }
  log [format "VIO bit%d %s -> 0x%06X" $bit [expr {$val ? "ON" : "OFF"}] $::VIO_BM]
  return $::VIO_BM
}

proc popcount {v} {
  set c 0
  while {$v} { set c [expr {$c + ($v & 1)}]; set v [expr {$v >> 1}] }
  return $c
}

# 使能名 / 位号互查
proc en_resolve {s} {
  set i [lsearch -exact $::EN_NAMES $s]
  if {$i >= 0} { return $i }
  # 纯数字（含 09 这类非常规写法）按位号处理
  if {[regexp {^[0-9]+$} $s]} {
    set n [dec_num $s]
    if {$n eq "" || $n < 0 || $n > 31} { error "位号非法: $s（应为 0~22）" }
    return $n
  }
  error "未知使能名: $s（用 list 命令查看全部）"
}

proc en_print {} {
  log "VIO 位映射（bit 使能名 → 对应打流机）："
  set i 0
  foreach n $::EN_NAMES {
    puts [format "  %2d  %-14s %s" $i $n [en_tester $n]]
    incr i
  }
}

# 使能名 → 对应打流机例化名（en_a_udp → u_ta_udp）
proc en_tester {en} { return "u_t[string range $en 3 end]" }

# 通道名 → 该通道实际存在的两侧使能名，如 udp → {en_a_udp en_b_udp}
proc chan_bits {ch} {
  set bits {}
  foreach side {a b} {
    set en "en_${side}_$ch"
    if {[lsearch -exact $::EN_NAMES $en] >= 0} { lappend bits $en }
  }
  return $bits
}

# 只打开给定使能名（自动关掉其余）
proc en_only {names} {
  set bm 0
  foreach n $names { set bm [expr {$bm | (1 << [en_resolve $n])}] }
  vio_set $bm
  return $bm
}

# ----------------------------------------------------------------------------
# ILA：触发一次采集并读取
# ----------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 采集一次并上传数据。关键点：
#   ① 触发模式：IMMEDIATE / ALWAYS 逐个尝试（不同版本取值不同），失败则沿用原设置
#   ② 采集完必须 upload_hw_ila_data 才会产生可读的 hw_ila_data 对象，
#      只调 get_hw_ila_data 是拿不到数据的（这是"探针值读不出"的常见原因）
# ---------------------------------------------------------------------------
proc ila_capture {ila} {
  # 本工程实测：CONTROL.TRIGGER_MODE 改不动（保持 BASIC_ONLY），
  # "立即采集"靠 CAPTURE_MODE=ALWAYS
  catch { set_property CONTROL.CAPTURE_MODE ALWAYS $ila }
  catch { set_property CONTROL.TRIGGER_POSITION 0 $ila }
  if {[catch {run_hw_ila $ila} e]} { log "run_hw_ila 失败: $e"; return "" }
  if {[catch {wait_on_hw_ila -timeout 10 $ila} e]} { log "wait_on_hw_ila 失败: $e"; return "" }
  mark "ilawait.timeout"
  # 新采集：清掉上一次的取值 / CSV 缓存
  set ::ILA_DATA ""
  set ::CSV_READY 0
  unset -nocomplain ::CSV_ERR
  set data ""
  if {[catch {set data [upload_hw_ila_data $ila]} e]} {
    set ::ILA_UPLOAD_ERR $e
    mark "ilaupload.fail"
    return ""
  }
  set ::ILA_DATA $data
  mark "ilaupload.upload"
  return $data
}

proc ila_snap {} {
  set datas {}
  foreach ila $::ILAS {
    set d [ila_capture $ila]
    if {$d ne ""} { lappend datas $d }
  }
  return $datas
}

# 触发一次采集但不打印（场景用）
proc snapi {} { ila_snap }

# 试读一个探针的原始值；返回 {} 表示读不出
# ---------------------------------------------------------------------------
# 读取探针值。不同 Vivado 版本取值方式不同，逐级尝试：
#   ① 核心探针的 VALUE 属性（旧版流程）
#   ② 采集数据对象（hw_ila_data）上的同名探针的 VALUE 属性
#   ③ 核心探针的 DATA / VALUE_DATA 等属性
#   ④ 以上都不行 → 由 ila_csv_cache 导出 CSV 兜底（见 probe_num 的退路）
# ---------------------------------------------------------------------------
# 探针取值：先试核心探针的 VALUE 属性（个别版本可用），拿不到就走 CSV 退路（见 probe_raw）
proc probe_value {p} {
  if {$p eq ""} { return "" }
  if {![catch {get_property VALUE $p} v] && $v ne ""} { mark "val.probe_VALUE"; return $v }
  return ""
}

# 采集数据导出为 CSV 的临时路径（每次运行用唯一名字，免去"文件已存在"）
proc tmp_csv_path {} {
  if {[info exists ::CSV_FILE] && $::CSV_FILE ne ""} { return $::CSV_FILE }
  set d ""
  foreach e {TEMP TMP TMPDIR} {
    if {[info exists ::env($e)] && $::env($e) ne ""} { set d $::env($e); break }
  }
  if {$d eq ""} {
    foreach cand {/tmp /var/tmp .} {
      if {[file isdirectory $cand] && [file writable $cand]} { set d $cand; break }
    }
  }
  if {$d eq ""} { set d [pwd] }
  set ::CSV_FILE [file join $d "hw_ila_snap_[pid]_[clock seconds].csv"]
  return $::CSV_FILE
}

# CSV 列名 / 探针名归一化：去掉位域、把非字母数字统一成下划线（兼容 / 与 _ 两种分隔）
proc hdr_key {s} {
  set s [string trim $s]
  regsub -all {\[[^\]]*\]} $s "" s
  regsub -all {[^0-9A-Za-z]} $s "_" s
  return [string tolower $s]
}

# CSV 单元格 → 整数：兼容 35'h2D7EF7600 / 1'b0 / 8'd12 / 0x.. / 0b.. / 纯十进制
proc cell_num {cell {radix ""}} {
  set c [string map {" " "" "_" ""} [string trim $cell]]
  if {$c eq ""} { return "" }
  set r [string toupper $radix]
  if {[string first "HEX" $r] >= 0} {
    if {[regexp -nocase {^[0-9a-f]+$} $c]} { mark "cell.radix_hex"; return [expr {"0x$c" + 0}] }
  } else {
    set dn [dec_num $c]
    if {$dn ne ""} { mark "cell.radix_dec"; return $dn }
  }
  mark "cell.none"
  return ""
}

proc csv_peek {{limit 300}} {
  set f ""
  if {[info exists ::CSV_FILE] && $::CSV_FILE ne ""} { set f $::CSV_FILE } else { set f [tmp_csv_path] }
  if {![file exists $f]} { log "CSV 文件不存在: $f"; return }
  set fh [open $f r]
  set n 0
  while {[gets $fh line] >= 0 && $n < 2} {
    if {[string trim $line] eq ""} { continue }
    puts "    [string range $line 0 $limit][expr {[string length $line] > $limit ? " ..." : ""}]"
    incr n
  }
  close $fh
  log "CSV 文件: $f"
}

# 把本次采集导出 CSV 并解析成「探针名 → 值」；成功返回 1
proc ila_csv_cache {} {
  if {[info exists ::CSV_READY] && $::CSV_READY} { return 1 }
  if {![info exists ::ILA_DATA] || $::ILA_DATA eq ""} { return 0 }
  array unset ::CSV_VALS
  set f [tmp_csv_path]
  set okcsv [expr {![catch {write_hw_ila_data -force -csv_file $f $::ILA_DATA} e]}]
  if {!$okcsv} {
    mark "csv.export.fail"
    if {![info exists ::CSV_ERR]} { set ::CSV_ERR $e; log "导出 CSV 失败（探针值退路不可用）: $e" }
    return 0
  }
  mark "csv.export.force"
  if {![info exists ::CSV_LOGGED]} { set ::CSV_LOGGED 1; log "探针取值走 CSV 导出: $f" }
  set fh ""
  if {[catch {set fh [open $f r]} e]} { set ::CSV_ERR $e; return 0 }
  set hdr {}
  set ti -1
  while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line eq ""} { continue }
    if {[llength $hdr] == 0} {
      if {[string first "," $line] >= 0} {
        set hdr [split $line ","]
        set ti [lsearch -exact $hdr "TRIGGER"]
      }
      continue
    }
    set cells [split $line ","]
    if {$ti >= 0 && [llength $cells] > $ti} {
      set tv [string trim [lindex $cells $ti]]
      if {$tv ne "1" && $tv ne "true"} { continue }
    }
    foreach h $hdr c $cells {
      set hk [hdr_key $h]
      if {$hk eq "" || $hk eq "sample_in_buffer" || $hk eq "sample_in_window" || $hk eq "trigger"} { continue }
      set radix ""
      if {[info exists ::PNK($hk)]} { catch {set radix [get_property DISPLAY_RADIX $::PNK($hk)]} }
      if {$radix ne ""} { mark "radix.DISPLAY_RADIX" $radix } else { mark "radix.none" }
      set num [cell_num $c $radix]
      array set ::CSV_VALS [list $hk [expr {$num eq "" ? [string trim $c] : $num}]]
    }
    break
  }
  close $fh
  set ::CSV_READY 1
  return [expr {[array size ::CSV_VALS] > 0}]
}

proc csv_val_of {p} {
  set nm ""
  catch {set nm [get_property NAME $p]}
  if {$nm eq ""} { return "" }
  set hk [hdr_key $nm]
  if {$hk ne "" && [info exists ::CSV_VALS($hk)]} { mark "csvmatch.normalized"; return $::CSV_VALS($hk) }
  mark "csvmatch.none"
  return ""
}

# 取原始值字符串（含 CSV 退路）；读不到返回 ""，原因记在 ::PROBE_READ_ERR
proc probe_raw {p} {
  if {$p eq ""} { return "" }
  set v [probe_value $p]
  if {$v ne ""} { set ::PROBE_READ_ERR ""; return $v }
  if {[ila_csv_cache]} {
    set cv [csv_val_of $p]
    if {$cv ne ""} { set ::PROBE_READ_ERR ""; return $cv }
  }
  mark "val.none"
  set err "取值失败"
  if {[info exists ::CSV_ERR]} { append err "（CSV 退路: $::CSV_ERR）" } \
  elseif {[info exists ::PV_STRAT] && $::PV_STRAT eq ""} { append err "（探针 VALUE 等属性均不可用）" }
  set ::PROBE_READ_ERR $err
  return ""
}

# 检查 ILA 数据是否可读；不可读时返回 0 并记录原因
proc ila_readable {} {
  foreach t $::TESTERS {
    foreach k {pkt bw err} {
      set key "$t|$k"
      if {![info exists ::TP($key)]} { continue }
      set raw [probe_raw $::TP($key)]
      if {$raw ne ""} { return 1 }
      set ::PROBE_READ_ERR_LAST $::PROBE_READ_ERR
      return 0
    }
  }
  return 0
}

# 场景入口统一检查：读不到 ILA 数据就没必要跑 23 轮
proc ila_require_readable {} {
  ila_probe_index
  if {$::N_PROBE == 0} { error "没有可用探针：请确认 bit 已下载、ltx 已刷新（ILA 核）" }
  snapi
  mark "ilareadable.precheck"
  if {![ila_readable]} {
    set why ""
    if {[info exists ::ILA_UPLOAD_ERR]} { set why $::ILA_UPLOAD_ERR }
    if {[info exists ::PROBE_READ_ERR_LAST] && $::PROBE_READ_ERR_LAST ne ""} { set why $::PROBE_READ_ERR_LAST }
    mark "ilareadable.fail"
    error "ILA 探针数据读不出（$why）：请先执行 hw_run iladiag 诊断"
  }
  return 1
}

# 诊断：打印 ILA 触发相关属性 + 采集上传结果 + 几个探针的原始值
proc ila_diag {} {
  foreach ila $::ILAS {
    log "ILA [get_property NAME $ila] 属性："
    foreach prop {CONTROL.TRIGGER_MODE CONTROL.TRIGGER_POSITION CONTROL.DATA_DEPTH \
                  CONTROL.CAPTURE_MODE CONTROL.IS_ARMED CORE_STATUS} {
      set v "-"
      catch {set v [get_property $prop $ila]}
      puts [format "    %-28s = %s" $prop $v]
    }
  }
  set data [ila_capture [lindex $::ILAS 0]]
  log "采集上传: [expr {$data eq "" ? "失败 / 无数据" : "成功"}]"
  if {[info exists ::ILA_UPLOAD_ERR]} { log "upload_hw_ila_data 报错: $::ILA_UPLOAD_ERR" }
  if {$data ne ""} {
    set dprops {}
    catch {set dprops [list_property $data]}
    log "数据对象可用属性: [join $dprops {, }]"
  }
  ila_probe_index
  set firstp ""
  foreach t $::TESTERS {
    if {[info exists ::TP($t|pkt)]} { set firstp $::TP($t|pkt); break }
  }
  if {$firstp ne ""} {
    set pprops {}
    catch {set pprops [list_property $firstp]}
    log "探针可用属性: [join $pprops {, }]"
  }
  set n 0
  foreach t $::TESTERS {
    foreach k {pkt bw err lock} {
      if {[info exists ::TP($t|$k)]} {
        set raw [probe_raw $::TP($t|$k)]
        set num [probe_num $::TP($t|$k)]
        puts [format "    %-14s %-5s VALUE=%-40s 解析=%s %s" $t $k \
              [expr {$raw eq "" ? "<读不出>" : $raw}] \
              [expr {$num eq "" ? "-" : $num}] \
              [expr {$::PROBE_READ_ERR eq "" ? "" : "ERR: $::PROBE_READ_ERR"}]]
        incr n
      }
    }
    if {$n >= 12} { break }
  }
  if {[info exists ::PV_STRAT] && $::PV_STRAT ne ""} { log "取值方式: $::PV_STRAT" } \
  elseif {[info exists ::CSV_READY] && $::CSV_READY} {
    log "取值方式: CSV 导出（探针 VALUE 属性不可用）"
    log "CSV 前两行（表头 + 触发点数据，供核对列名/数值格式）:"
    catch { csv_peek 260 }
  }
  return [expr {$data ne ""}]
}

proc ila_read {{filter {}} {csv {}}} {
  set datas [ila_snap]
  set now [clock format [clock seconds] -format "%H:%M:%S"]
  foreach ila $::ILAS {
    log "ILA [get_property NAME $ila] 采集于 $now："
    foreach p [get_hw_probes -of_objects $ila] {
      set nm [get_property NAME $p]
      if {$filter ne "" && ![string match *$filter* $nm]} { continue }
      set v [probe_raw $p]
      if {$v eq ""} { set v "<读取失败: $::PROBE_READ_ERR>" } else {
        set num [str_num $v]
        if {$num ne ""} { set v "$v（$num）" }
      }
      puts [format "  %-46s = %s" $nm $v]
    }
  }
  if {$csv ne ""} {
    foreach d $datas { catch { write_hw_ila_data -csv_file $csv $d } }
    log "波形已写出: $csv"
  }
}

proc ila_monitor {n {filter {}}} {
  for {set i 1} {$i <= $n} {incr i} {
    log "---- 第 $i/$n 次 ----"
    ila_read $filter
    if {$i < $n} { sleep_s 1 }
  }
}

# ----------------------------------------------------------------------------
# 探针归类：按「打流机例化名 + 计数种类」建索引
# ----------------------------------------------------------------------------
proc ila_probe_index {{quiet 1}} {
  array unset ::TP
  array unset ::PNK
  set unknown {}
  foreach ila $::ILAS {
    foreach p [get_hw_probes -of_objects $ila] {
      set nm [get_property NAME $p]
      set t ""
      foreach cand $::TESTERS {
        if {[string first $cand $nm] >= 0} { set t $cand; break }
      }
      set k ""
      foreach pair $::CNT_KEYS {
        if {[string first [lindex $pair 0] $nm] >= 0} { set k [lindex $pair 1]; break }
      }
      if {$t ne "" && $k ne ""} {
        set ::TP($t|$k) $p
        set ::PNK([hdr_key $nm]) $p
      } else {
        lappend unknown $nm
      }
    }
  }
  set ::N_PROBE  [array size ::TP]
  if {!$quiet} {
    map_print $unknown
    foreach ila $::ILAS {
      log "ILA [get_property NAME $ila] 探针共 [llength [get_hw_probes -of_objects $ila]] 个，已归类 $::N_PROBE 个"
    }
  }
  return $::N_PROBE
}

proc map_print {{unknown {}}} {
  log "探针归类（打流机 → 已识别计数种类）："
  foreach t $::TESTERS {
    set ks {}
    foreach pair $::CNT_KEYS {
      if {[info exists ::TP($t|[lindex $pair 1])]} { lappend ks [lindex $pair 1] }
    }
    puts [format "  %-14s %s" $t [expr {[llength $ks] ? [join $ks ","] : "（无探针）"}]]
  }
  if {[llength $unknown]} {
    log "未归类探针 [llength $unknown] 个（名称与打流机 / 计数种类不匹配，前 5 个）："
    foreach nm [lrange $unknown 0 4] { puts "  $nm" }
  }
}

# ILA 探针的数值：兼容二进制 / 十六进制 / 十进制三种呈现

# 安全十进制解析：scan 不会把 0106 当八进制（expr {$v+0} 会，且遇到 09 直接报错）
proc dec_num {v} {
  set v [string trim $v]
  if {$v eq ""} { return "" }
  if {![regexp {^[0-9]+$} $v]} { return "" }
  # 去掉前导零后 expr 才按十进制解释（否则 0106 会被当八进制、09 直接报错）；
  # 不用 scan %d：部分 32 位 Tcl 上会截断到 2^31-1
  set v [string trimleft $v 0]
  if {$v eq ""} { return 0 }
  if {[catch {expr {$v + 0}} n]} { return "" }
  return $n
}

# 字符串 → 整数：兼容二进制 / 十六进制 / 十进制三种呈现
# 字符串 → 整数（数值显示与回退路径用）
proc str_num {v} {
  set v [string map {" " "" "_" "" "\t" ""} [string trim $v]]
  if {$v eq ""} { return "" }
  if {[regexp {^[0-9]+$} $v]} { return [dec_num $v] }
  if {[regexp -nocase {^0x[0-9a-f]+$} $v]} { return [expr {"0x[string range $v 2 end]" + 0}] }
  if {[regexp {^0b[01]+$} $v]} { return [expr {"0b[string range $v 2 end]" + 0}] }
  return ""
}

proc probe_num {p} {
  if {$p eq ""} { return "" }
  set raw [probe_value $p]
  if {$raw eq ""} {
    # 退路：从本次采集导出的 CSV 里取
    if {[ila_csv_cache]} { set raw [csv_val_of $p] }
  }
  if {$raw eq ""} { return "" }
  return [str_num $raw]
}

# 读某台打流机的某类计数（pkt/bw/err/lenerr/lock）；探针不存在时返回 ""
proc cnt {tester kind} {
  set key "$tester|$kind"
  if {![info exists ::TP($key)]} { return "" }
  return [probe_num $::TP($key)]
}

# 某类计数在所有打流机上的分布：返回 {打流机 值} 成对列表
proc cnt_all {kind} {
  set out {}
  foreach t $::TESTERS {
    set v [cnt $t $kind]
    if {$v ne ""} { lappend out $t $v }
  }
  return $out
}

# 总线字节吞吐 → 以太网线速 (Gbps)：bw × 8 × (L+24) / L
# 通道的额外长度（未知通道按 MAC 层 24 处理）
proc chan_ovh {ch} {
  if {[dict exists $::CHAN_OVH $ch]} { return [dict get $::CHAN_OVH $ch] }
  return 24
}

# 总线字节吞吐 → 以太网线速 (Gbps)：bw × 8 × (L + ovh) / L
proc bw_gbps {bw {ovh 24}} {
  if {$bw eq ""} { return "" }
  return [expr {$bw * 8.0 * ($::FRAME_BYTES + $ovh) / $::FRAME_BYTES / 1e9}]
}

# MAC 层通道（成帧由打流机自己组 MAC 头）：其错误计数可能来自交换机其他帧
proc is_mac_chan {ch} { expr {[string match "mac_*" $ch] || $ch eq "fb_mac"} }

# 仅 MAC 未匹配档（fb_mac）允许非零错误计数（交换机其他帧自然落进该档）
# 错误计数豁免的通道（天然会收到交换机其它帧）：默认仅 MAC 未匹配档 fb_mac。
# 若确认某通道的错误计数同样来自交换机流量，可追加，例如：
#   set ::ERR_IGNORE_CHANS {fb_mac ip6icmp fb_ipv6 fb_udp}
if {![info exists ::ERR_IGNORE_CHANS]} { set ::ERR_IGNORE_CHANS {fb_mac} }
proc err_ignored {ch} { expr {[lsearch -exact $::ERR_IGNORE_CHANS $ch] >= 0} }

# 从使能名 / 打流机名取通道后缀：en_a_udp -> udp，u_tb_fb_mac -> fb_mac
proc en_chan {en} { return [string range $en 5 end] }
proc tester_chan {t} { return [string range $t 5 end] }

# 打印一台打流机的一行读数，返回 {pkt bw err lenerr 线速}
proc show_tester {t {tag {}} {ovh 24}} {
  set pkt [cnt $t pkt]; set bw [cnt $t bw]; set err [cnt $t err]; set le [cnt $t lenerr]
  set gb  [bw_gbps $bw $ovh]
  puts [format "    %-14s %-7s pkt=%-12s bw=%-14s 线速=%s  err=%-6s len_err=%s" \
        $t $tag $pkt $bw \
        [expr {$gb eq "" ? "  n/a" : [format "%.9f Gbps" $gb]}] $err $le]
  return [list $pkt $bw $err $le $gb]
}

proc verdict {ok {warn 0}} {
  if {$ok == "" || !$ok} { return "FAIL" }
  if {$warn} { return "WARN" }
  return "PASS"
}

# ----------------------------------------------------------------------------
# 场景 1 · 通道连通性：逐位单开，核对「该位的收端打流机」收到且无错误
# ----------------------------------------------------------------------------
proc sc1 {{settle {}}} {
  if {$settle eq ""} { set settle $::DEFAULT_SETTLE }
  ila_require_readable
  set npass 0; set nwarn 0; set nfail 0
  set i 0
  foreach en $::EN_NAMES {
    set exp [en_tester $en]
    set ch  [en_chan $en]
    set ovh [chan_ovh $ch]
    vio_set [expr {1 << $i}]
    sleep_s $settle
    snapi
    set got {}
    foreach {t v} [cnt_all pkt] { if {$v > 0} { lappend got $t } }
    set pkt [cnt $exp pkt]; set err [cnt $exp err]; set le [cnt $exp lenerr]
    set bw  [cnt $exp bw]
    set gb  [bw_gbps $bw $ovh]
    set recv  [expr {$pkt ne "" && $pkt > 0}]
    set clean [expr {($err eq "" || $err == 0) && ($le eq "" || $le == 0)}]
    # 错误计数规则：除 MAC 未匹配档（fb_mac）外，err / len_err 必须为 0
    set ign [err_ignored $ch]
    set ok [expr {$recv && ($ign || $clean)}]
    # 其它通道计数：排除天然会收到交换机流量的 MAC 未匹配档
    set extra {}
    foreach t $got {
      if {$t ne $exp && ![err_ignored [tester_chan $t]]} { lappend extra $t }
    }
    set vd [verdict $ok [expr {$ok && $::STRICT_EXTRA && [llength $extra] > 0}]]
    if {$vd eq "PASS"} { incr npass } elseif {$vd eq "WARN"} { incr nwarn } else { incr nfail }
    puts [format "  %2d  %-14s → %-14s %-4s pkt=%-12s bw=%-14s 线速=%s err=%-5s len_err=%-5s%s" \
          $i $en $exp $vd $pkt $bw \
          [expr {$gb eq "" ? "  n/a" : [format "%.9f Gbps" $gb]}] $err $le \
          [expr {$recv ? "" : "【收端无包】"}]]
    if {[is_mac_chan $ch] && !$clean} { puts "       注：MAC 层通道——错误计数可能来自交换机其它帧，请确认交换机是否有其它帧发到该网口" }
    if {[llength $extra]} { puts "       提示：另有通道计数非零（其使能未开，多为交换机流量）→ $extra" }
    incr i
  }
  vio_set 0
  log "场景 1 结果：PASS $npass / WARN $nwarn / FAIL $nfail（共 [llength $::EN_NAMES] 路）"
  mark_report "sc1"
  return [expr {$nfail == 0}]
}

# ----------------------------------------------------------------------------
# 场景 2 · 单通道线速：双向同开，换算线速与门限比较
# ----------------------------------------------------------------------------
proc sc2 {args} {
  set chans {}
  set settle $::DEFAULT_SETTLE
  foreach a $args {
    if {[string is double -strict $a]} { set settle $a } else { lappend chans $a }
  }
  if {[llength $chans] == 0} { set chans $::DUAL_CHANS }
  ila_require_readable
  set npass 0; set nfail 0
  foreach ch $chans {
    set bits [chan_bits $ch]
    if {[llength $bits] == 0} { log "跳过未知通道: $ch"; continue }
    en_only $bits
    sleep_s $settle
    snapi
    set bits_txt [join $bits {+}]
    log "通道 $ch , 使能 $bits_txt :"
    set ch_ok 1
    set why {}
    foreach side {a b} {
      set t "u_t${side}_$ch"
      if {[lsearch -exact $::TESTERS $t] < 0} { continue }
      set peer [expr {$side eq {a} ? {B} : {A}}]
      set tag  [format "%s→%s" [string toupper $side] $peer]
      set r [show_tester $t $tag [chan_ovh $ch]]
      set pkt [lindex $r 0]; set err [lindex $r 2]; set le [lindex $r 3]; set gb [lindex $r 4]
      if {$pkt eq "" || $pkt == 0} { lappend why "$t 收端无包"; set ch_ok 0 }
      if {$gb eq ""} { lappend why "$t 线速取不到"; set ch_ok 0 } \
      elseif {$gb < $::LINE_TH_GBPS} { lappend why [format "%s 线速 %.3f G < %.1f G" $t $gb $::LINE_TH_GBPS]; set ch_ok 0 }
      if {$err ne "" && $err != 0} { lappend why "$t err=$err（非 0）"; set ch_ok 0 }
      if {$le  ne "" && $le  != 0} { lappend why "$t len_err=$le（非 0）"; set ch_ok 0 }
    }
    if {$ch_ok} { incr npass } else { incr nfail }
    puts [format "    → %s（门限 %.1f Gbps × 双向；额外长度 +%d B）" \
          [verdict $ch_ok] $::LINE_TH_GBPS [chan_ovh $ch]]
    if {[llength $why]} { puts "      失败原因: [join $why {; }]" }
    if {[err_ignored $ch]} { puts "      注：本通道在豁免表内，错误计数按约定忽略" } \
    elseif {!$ch_ok && [lsearch -glob $why "*err=*"] >= 0} {
      puts "      提示: 若确认该错误计数来自交换机其它帧，可先执行 set ::ERR_IGNORE_CHANS {[concat $::ERR_IGNORE_CHANS [list $ch]]} 再重跑"
    }
  }
  vio_set 0
  log "场景 2 结果：PASS $npass / FAIL $nfail（通道数 [llength $chans]）"
  mark_report "sc2"
  return [expr {$nfail == 0}]
}

# ----------------------------------------------------------------------------
# 场景 3 · 严格优先级：全部打开后自高向低逐路关闭，核对「独占线速」与「低优先饿死」
# ----------------------------------------------------------------------------
proc sc3 {{settle {}}} {
  if {$settle eq ""} { set settle $::DEFAULT_SETTLE }
  ila_require_readable
  set order $::PRIO_ORDER
  set n [llength $order]
  set npass 0; set nfail 0
  for {set k 0} {$k < $n} {incr k} {
    set on  [lrange $order $k end]
    set win [lindex $order $k]
    set off [lrange $order 0 [expr {$k - 1}]]
    set names {}
    foreach ch $on { foreach en [chan_bits $ch] { lappend names $en } }
    en_only $names
    sleep_s $settle
    snapi
    log "步骤 [expr {$k + 1}]：已关 {$off}；当前最高优先级 = $win"
    set step_ok 1
    foreach ch $order {
      foreach side {a b} {
        set t "u_t${side}_$ch"
        if {[lsearch -exact $::TESTERS $t] < 0} { continue }
        set gb [bw_gbps [cnt $t bw] [chan_ovh $ch]]
        if {$gb eq ""} { continue }
        if {$ch eq $win} {
          if {$gb < $::LINE_TH_GBPS} { set step_ok 0 }
          puts [format "    %-14s %-8s 线速=%.9f Gbps  %s" $t $ch $gb \
                [expr {$gb >= $::LINE_TH_GBPS ? "占满线速" : "未达线速"}]]
        } elseif {[lsearch -exact $on $ch] >= 0} {
          if {$gb > $::LINE_TH_GBPS * $::STARVE_RATIO} { set step_ok 0 }
          puts [format "    %-14s %-8s 线速=%.9f Gbps  %s" $t $ch $gb \
                [expr {$gb <= $::LINE_TH_GBPS * $::STARVE_RATIO ? "被饿死(≈0)" : "仍有流量"}]]
        } elseif {$gb > $::LINE_TH_GBPS * $::STARVE_RATIO} {
          set step_ok 0
          puts [format "    %-14s %-8s 线速=%.9f Gbps  已关闭但仍有流量" $t $ch $gb]
        }
      }
    }
    if {$step_ok} { incr npass } else { incr nfail }
    puts [format "    → 本步 %s" [verdict $step_ok]]
  }
  # 基线：全关后应归零
  vio_set 0
  sleep_s $settle
  snapi
  # 基线残留：排除 MAC 未匹配档（fb_mac）——它天然有交换机其它帧的流量
  set leak {}
  set bg {}
  set lim [expr {$::BW_FULL_REF * $::BASE_LEAK_RATIO}]
  foreach {t v} [cnt_all bw] {
    if {$v > 0} {
      if {[err_ignored [tester_chan $t]] || $v <= $lim} { lappend bg "$t=$v" } else { lappend leak "$t=$v" }
    }
  }
  set base_ok [expr {[llength $leak] == 0}]
  if {$base_ok} { incr npass } else { incr nfail }
  set steps [expr {$n + 1}]
  puts [format "  步骤 $steps：全关基线 → %s%s" [verdict $base_ok] \
        [expr {$base_ok ? "" : "（残留: $leak）"}]]
  if {[llength $bg]} { puts "      提示：以下为背景流量（交换机零星帧），不计入基线 → $bg" }
  set steps [expr {$n + 1}]
  log "场景 3 结果：PASS $npass / FAIL $nfail（共 $steps 步）"
  mark_report "sc3"
  return [expr {$nfail == 0}]
}

# ----------------------------------------------------------------------------
# 场景 4 · 未匹配通道：四个兜底探测位逐侧单开，核对落档与错误计数
# ----------------------------------------------------------------------------
proc sc4 {{settle {}}} {
  if {$settle eq ""} { set settle $::DEFAULT_SETTLE }
  ila_require_readable
  set npass 0; set nwarn 0; set nfail 0
  foreach ch $::FB_CHANS {
    foreach en [chan_bits $ch] {
      set exp [en_tester $en]
      en_only $en
      sleep_s $settle
      snapi
      set pkt [cnt $exp pkt]; set err [cnt $exp err]; set le [cnt $exp lenerr]
      set bw  [cnt $exp bw]
      set gb  [bw_gbps $bw [chan_ovh $ch]]
      set got {}
      foreach {t v} [cnt_all pkt] {
        if {$v > 0 && $t ne $exp && ![err_ignored [tester_chan $t]]} { lappend got $t }
      }
      set clean [expr {($err eq "" || $err == 0) && ($le eq "" || $le == 0)}]
      set ign [err_ignored $ch]
      set ok [expr {$pkt ne "" && $pkt > 0 && ($ign || $clean)}]
      set vd [verdict $ok [expr {$ok && $::STRICT_EXTRA && [llength $got] > 0}]]
      if {$vd eq "PASS"} { incr npass } elseif {$vd eq "WARN"} { incr nwarn } else { incr nfail }
      puts [format "  %-14s → 落档 %-14s %-4s pkt=%-12s bw=%-14s 线速=%s err=%-5s len_err=%-5s%s" \
            $en $exp $vd $pkt $bw \
            [expr {$gb eq "" ? "  n/a" : [format "%.9f Gbps" $gb]}] $err $le \
            [expr {[llength $got] ? "  其它通道: $got" : ""}]]
      if {[is_mac_chan $ch] && !$clean} { puts "       注：MAC 层通道——错误计数可能来自交换机其它帧，请确认交换机是否有其它帧发到该网口" }
    }
  }
  vio_set 0
  log "场景 4 结果：PASS $npass / WARN $nwarn / FAIL $nfail"
  mark_report "sc4"
  return [expr {$nfail == 0}]
}

# ----------------------------------------------------------------------------
# 全场景汇总
# ----------------------------------------------------------------------------
proc scall {{settle {}}} {
  if {$settle eq ""} { set settle $::DEFAULT_SETTLE }
  set res {}
  set t0 [clock seconds]
  set ::MARK_QUIET 1
  log "=================== 全场景自动验证开始（每步稳定 $settle s）==================="
  foreach {nm desc} {sc1 "通道连通性" sc2 "单通道线速" sc3 "严格优先级" sc4 "未匹配通道"} {
    log "--- $nm · $desc ---"
    set cmd [list $nm $settle]
    set ok 0
    if {[catch {eval $cmd} e]} { log "$nm 执行异常: $e" } else { set ok [expr {$e ? 1 : 0}] }
    lappend res $nm $desc $ok
  }
  unset -nocomplain ::MARK_QUIET
  log "=================== 汇总 ==================="
  set nfail 0
  foreach {nm desc ok} $res {
    puts [format "  %-5s %-14s %s" $nm $desc [verdict $ok]]
    if {!$ok} { incr nfail }
  }
  set overall [verdict [expr {$nfail == 0}]]
  log "总判定：$overall   用时 [expr {[clock seconds] - $t0}] s"
  mark_report "scall"
  return [expr {$nfail == 0}]
}

# ----------------------------------------------------------------------------
# 命令行解析与主流程
# ----------------------------------------------------------------------------
set ::CMDS {list map vionames iladiag csvpeek paths refresh bit set on off read csv monitor sc1 sc2 sc3 sc4 scall}

# 入口：hw_run <命令...>，参数写法与批处理 -tclargs 一致
proc hw_run {args} {
  if {![info exists ::HW_READY] || !$::HW_READY} { hw_connect }

  # 把 args 切成 {命令 参数...} 的序列（参数吃掉后续非命令 token）
  set seq {}
  foreach tok $args {
    if {[lsearch -exact $::CMDS $tok] >= 0} {
      lappend seq [list $tok]
    } elseif {[llength $seq] == 0} {
      error "第一个参数必须是命令之一: $::CMDS"
    } else {
      lset seq end [concat [lindex $seq end] [list $tok]]
    }
  }

  set ret 1
  foreach cmd $seq {
    set op  [lindex $cmd 0]
    set arg [lrange $cmd 1 end]
    switch -- $op {
      list {
        en_print
        set vp [vio_bit_probes]
        set nvp [expr {[llength $vp] / 2}]
        if {$nvp == 0} {
          log "VIO 输出探针: 未识别（先执行 hw_run vionames 诊断，或 hw_run refresh 重新枚举调试核）"
        } elseif {$nvp != [llength $::EN_NAMES]} {
          log "VIO 输出探针: 识别 $nvp 位（期望 [llength $::EN_NAMES] 位），建议 hw_run vionames 核对"
        } else {
          log "VIO 输出探针: 识别 $nvp 位（与使能位一一对应）"
        }
        set wp [vio_out_prop]
        if {$nvp > 0} {
          if {$wp eq ""} {
            log "VIO 写输出属性: 未找到可写属性 —— 请执行 hw_run vionames 并把属性列表反馈"
          } else {
            set rd [vio_get]
            if {$rd ne ""} {
              log "VIO 写输出属性: $wp, 读回可用"
              log [format "VIO 当前位图: 0x%06X" $rd]
            } else {
              log "VIO 写输出属性: $wp, 读回不可用（on/off 为逐位写入，不受影响）"
            }
          }
        }
        ila_probe_index 0
        foreach ila $::ILAS {
          puts "  ILA [get_property NAME $ila]：探针 [llength [get_hw_probes -of_objects $ila]] 个，已归类 $::N_PROBE 个"
        }
      }
      map { ila_probe_index 0 }
      vionames { vio_diag }
      iladiag  { ila_diag }
      csvpeek  { csv_peek }
      paths    { mark_report "当前累计" }
      refresh  { hw_refresh }
      bit {
        if {[llength $arg] != 1} { error "bit <file>" }
        set_property PROGRAM.FILE [lindex $arg 0] [current_hw_device]
        program_hw_devices [current_hw_device]
        refresh_hw_device  [current_hw_device]
        set ::VIOS [get_hw_vios]
        set ::ILAS [get_hw_ilas]
        vio_cache_clear
        log "bitstream 已下载: [lindex $arg 0]"
        log "提示: 重新下载后 VIO 初值复位、GUI 仪表盘需重新打开"
      }
      set {
        if {[llength $arg] != 1} { error "set <num>（如 set 0x5 / set 0）" }
        vio_set [expr [lindex $arg 0]]
      }
      on  -
      off {
        if {[llength $arg] == 0} { error "$op <名|位>..." }
        # 逐位写入：不依赖读回，也不会误清其它位
        foreach s $arg {
          set b [en_resolve $s]
          vio_poke $b [expr {$op eq "on" ? 1 : 0}]
        }
      }
      read  { ila_read [lindex $arg 0] }
      csv   { ila_read [lindex $arg 1] [lindex $arg 0] }
      monitor {
        if {[llength $arg] < 1} { error "monitor <n> [filter]" }
        ila_monitor [lindex $arg 0] [lindex $arg 1]
      }
      sc1   { mark_reset; set ret [sc1 [lindex $arg 0]] }
      sc2   { mark_reset; set ret [eval sc2 $arg] }
      sc3   { mark_reset; set ret [sc3 [lindex $arg 0]] }
      sc4   { mark_reset; set ret [sc4 [lindex $arg 0]] }
      scall { mark_reset; set ret [scall [lindex $arg 0]] }
    }
  }
  return $ret
}

# 自动执行：批处理带 -tclargs 时执行命令；GUI 里 source（无参数）时只打印用法
hw_connect

if {[llength $argv] == 0} {
  en_print
  log "已连接。输入 hw_run <命令...> 开始；场景化验证命令："
  log "  hw_run list                          # 位映射 + VIO/ILA 探针识别情况"
  log "  hw_run vionames                      # 诊断：VIO 探针真实名称 / 可用属性"
  log "  hw_run iladiag                       # 诊断：ILA 触发属性 + 采集上传 + 探针原始值"
  log "  hw_run refresh                       # 重新下载 bit 后重新枚举调试核"
  log "  hw_run sc1                           # ① 通道连通性（逐路全自动核对）"
  log "  hw_run sc2                           # ② 单通道线速（双向满载，换算线速）"
  log "  hw_run sc2 udp icmp                  #    仅测指定通道"
  log "  hw_run sc3                           # ③ 严格优先级（逐路关闭 + 饿死判据）"
  log "  hw_run sc4                           # ④ 未匹配通道（四个兜底探测位）"
  log "  hw_run scall                         #  ①~④ 全跑 + 总判定表"
  log "  hw_run on en_a_udp monitor 10 rx_bw  # 手工控制（开 A 口 UDP 连采 10 次）"
  log "  hw_run set 0                         # 手工：全部关闭"
} else {
  hw_run {*}$argv
}

log "完成。"
