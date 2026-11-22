# Centenarian 参考工程。Vivado 工程输出到仓库的上一级目录。
#
# vivado -mode batch -source usr/Scripts/create_project.tcl \
#        -tclargs -top subsys_test_top -jobs 8 -name My100G
#
# -top <module>  综合顶层，默认 subsys_test_top。可选 eth_stack_top、
#                eth_stack_port、eth_stack_port_a、eth_stack_port_b 或自定义顶层。
# -name <name>   工程名（省略 .xpr 后缀），默认为工作区目录名。
#                生成 <工作区>/<name>.xpr。
# -jobs <n>      综合任务数，默认 4。
# -xdc <name>    选择 XDC 基名（可带 .xdc），以及配套的 <name>_impl.xdc。
#                约束必须与顶层端口和层级匹配。默认按顶层名选择。
# -synth         创建后运行 synth_1。
# -ooc           生成 IP 产物后显式运行 IP OOC 综合。
# -force         允许覆盖同名工程及其构建结果。

proc centenarian_collect_files {dir extensions} {
    set files {}
    foreach path [lsort [glob -nocomplain -directory $dir -type f *]] {
        if {[string tolower [file extension $path]] in $extensions} {
            lappend files $path
        }
    }
    foreach path [lsort [glob -nocomplain -directory $dir -type d *]] {
        set name [file tail $path]
        if {[string match .* $name] || [string equal -nocase $name Backup]} {
            continue
        }
        lappend files {*}[centenarian_collect_files $path $extensions]
    }
    return $files
}

proc centenarian_create_project {args} {
    set options [dict create -top subsys_test_top -jobs 4 -name "" -xdc "" \
                             -synth 0 -ooc 0 -force 0]
    for {set i 0} {$i < [llength $args]} {incr i} {
        set option [lindex $args $i]
        switch -exact -- $option {
            -top - -jobs - -name - -xdc {
                incr i
                set value [lindex $args $i]
                if {$value eq "" || [string match -* $value]} {
                    error "参数 $option 需要一个值"
                }
                dict set options $option $value
            }
            -synth - -ooc - -force { dict set options $option 1 }
            default { error "未知参数：$option" }
        }
    }

    set source_dir [file dirname [file dirname [file normalize [info script]]]]
    set project_dir [file dirname $source_dir]
    set project_name [dict get $options -name]
    if {$project_name eq ""} {
        set project_name [file tail $project_dir]
    }
    if {[file pathtype $project_name] ne "relative" || $project_name in {. ..} ||
        [regexp {[[:cntrl:]\\/:*?"<>|]} $project_name] ||
        [string trim $project_name] eq ""} {
        error "工程名必须是有效的文件名：$project_name"
    }
    set project_file [file join $project_dir $project_name.xpr]
    set overwrite [dict get $options -force]
    if {[file exists $project_file] && !$overwrite} {
        error "工程已存在：$project_file。请打开此工程，或用 -name 指定其他名称。"
    }
    set top [dict get $options -top]
    set jobs [dict get $options -jobs]
    if {![string is integer -strict $jobs] || $jobs < 1} {
        error "-jobs 必须是正整数"
    }

    set rtl_dir [file join $source_dir RTL]
    if {![file isdirectory $rtl_dir]} {
        error "未找到 RTL 目录：$rtl_dir"
    }
    set rtl_files [centenarian_collect_files $rtl_dir {.v .sv}]
    set headers [centenarian_collect_files $rtl_dir {.vh .svh}]
    set modules [dict create]
    foreach path $rtl_files {
        set fh [open $path r]
        set contents [read $fh]
        close $fh
        set contents [regsub -all {/\*.*?\*/|//[^\n]*} $contents ""]
        foreach {match module} [regexp -all -line -inline \
                {^[ \t]*module[ \t]+(?:(?:automatic|static)[ \t]+)?([A-Za-z_][A-Za-z0-9_$]*)} $contents] {
            if {[dict exists $modules $module]} {
                error "模块 $module 重复定义：[dict get $modules $module] 和 $path"
            }
            dict set modules $module $path
        }
    }
    if {![dict exists $modules $top]} {
        error "未在 $rtl_dir 找到顶层模块 $top"
    }

    set xdc_dir [file join $source_dir XDC]
    set xdc_name [dict get $options -xdc]
    if {$xdc_name eq ""} {
        set xdc_name $top
    } elseif {[string equal -nocase [file extension $xdc_name] .xdc]} {
        set xdc_name [file rootname $xdc_name]
    }
    set board_xdc [file join $xdc_dir $xdc_name.xdc]
    set impl_xdc [file join $xdc_dir [format %s_impl.xdc $xdc_name]]
    if {[dict get $options -xdc] ne "" &&
        ([regexp {[\\/:]} $xdc_name] || ![file isfile $board_xdc])} {
        error "-xdc 指定的板级约束不存在：$board_xdc"
    }
    set xdc_files [lsort [glob -nocomplain -directory $xdc_dir -type f *.xdc]]
    set scoped_files [lsort [glob -nocomplain -directory $xdc_dir -type f *.tcl]]
    set fifo_dir [file join $rtl_dir Bsp Fifo]
    set fifo_loader [file join $fifo_dir load_fifo_async_constraints.tcl]
    set fifo_scripts {}
    foreach name {load_fifo_async_constraints fifo_async_constraints
                  fifo_async_fwft_constraints axis_fifo_async_constraints} {
        set path [file join $fifo_dir $name.tcl]
        if {![file isfile $path]} {
            error "缺少异步 FIFO 约束脚本：$path"
        }
        lappend fifo_scripts $path
    }

    set ip_files [centenarian_collect_files [file join $source_dir IP] {.xci}]
    set ip_names [dict create]
    foreach path $ip_files {
        set ip [file rootname [file tail $path]]
        if {[dict exists $ip_names $ip]} {
            error "IP $ip 有多个 XCI：[dict get $ip_names $ip] 和 $path"
        }
        dict set ip_names $ip $path
    }
    puts "  工程输出: $project_file"
    set_param general.maxThreads $jobs
    create_project $project_name $project_dir -part xcvu37p-fsvh2892-2L-e \
        {*}[expr {$overwrite ? {-force} : {}}]
    set_property target_language Verilog [current_project]
    set_property default_lib work [current_project]
    set_property source_mgmt_mode All [current_project]

    set sources [get_filesets sources_1]
    add_files -norecurse -fileset $sources [concat $rtl_files $headers]
    if {[llength $headers]} {
        set include_dirs {}
        foreach header $headers {
            set_property FILE_TYPE {Verilog Header} [get_files $header]
            lappend include_dirs [file dirname $header]
        }
        set include_dirs [lsort -unique $include_dirs]
        set_property INCLUDE_DIRS $include_dirs $sources
        set_property INCLUDE_DIRS $include_dirs [get_filesets sim_1]
    }
    set_property top $top $sources
    puts "  RTL: [llength $rtl_files] 个源文件，[llength $headers] 个头文件，顶层 $top"

    if {[llength $xdc_files]} {
        add_files -norecurse -fileset constrs_1 $xdc_files
        foreach path $xdc_files {
            set xdc [get_files $path]
            if {[string match *_impl.xdc $path]} {
                set_property USED_IN {implementation} $xdc
                set_property PROCESSING_ORDER LATE $xdc
                set_property IS_ENABLED [expr {$path eq $impl_xdc}] $xdc
            } elseif {[string match *_top.xdc $path] ||
                      [file exists [file join $xdc_dir [file rootname [file tail $path]]_impl.xdc]]} {
                set_property IS_ENABLED [expr {$path eq $board_xdc}] $xdc
            }
        }
    }
    if {[file isfile $board_xdc]} {
        puts "  XDC: [file tail $board_xdc]"
        if {[file isfile $impl_xdc]} {
            puts "  XDC: [file tail $impl_xdc]（仅实现，LATE）"
        }
    } else {
        puts "  INFO: $top 未配套板级 XDC。"
    }
    foreach path $scoped_files {
        set module [file rootname [file tail $path]]
        if {![dict exists $modules $module]} {
            puts "  WARNING: 跳过 [file tail $path]，RTL 中没有模块 $module"
            continue
        }
        add_files -norecurse -fileset constrs_1 $path
        set_property -dict [list SCOPED_TO_REF $module PROCESSING_ORDER LATE \
                                 USED_IN {synthesis implementation simulation}] [get_files $path]
    }
    add_files -norecurse -fileset utils_1 $fifo_scripts
    set_property STEPS.OPT_DESIGN.TCL.PRE $fifo_loader [get_runs impl_1]
    puts "  CDC: impl_1 将在 opt_design 前加载异步 FIFO 约束"

    if {[llength $ip_files]} {
        import_ip $ip_files
        # 升级旧版 VIO 配置的工程副本。当前顶层使用 27 个使能位和一个 16 位包间隔。
        if {[dict exists $ip_names vio_enable]} {
            set vio [get_ips vio_enable]
            set vio_config [list CONFIG.C_NUM_PROBE_IN 0 CONFIG.C_EN_PROBE_IN_ACTIVITY 0 \
                                 CONFIG.C_NUM_PROBE_OUT 28 CONFIG.C_PROBE_OUT23_WIDTH 16 \
                                 CONFIG.C_PROBE_OUT24_WIDTH 1 CONFIG.C_PROBE_OUT25_WIDTH 1 \
                                 CONFIG.C_PROBE_OUT26_WIDTH 1 CONFIG.C_PROBE_OUT27_WIDTH 1]
            foreach {property value} $vio_config {
                if {[get_property $property $vio] ne $value} {
                    set_property -dict $vio_config $vio
                    puts "  VIO: 已将工程副本更新为 27 路使能和 16 位包间隔"
                    break
                }
            }
        }
        set ips [get_ips]
        generate_target all $ips
        puts "  IP: [join [dict keys $ip_names] {, }]"
        if {[dict get $options -ooc]} {
            synth_ip $ips -force
            puts "  IP OOC 综合完成"
        }
    } else {
        puts "  WARNING: IP 目录下未找到 XCI。"
    }
    update_compile_order -fileset $sources
    puts "  工程已创建: $project_file"

    if {[dict get $options -synth]} {
        set run [get_runs synth_1]
        launch_runs $run -jobs $jobs
        wait_on_run $run
        set status [get_property STATUS $run]
        if {$status ne "synth_design Complete!"} {
            error "synth_1 未完成：$status"
        }
        puts "  synth_1 完成"
    }
}

centenarian_create_project {*}$argv
