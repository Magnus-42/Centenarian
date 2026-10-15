`timescale 1ns / 1ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv4_test_top.v
// Module Name : ipv4_test_top
// Author      : LiXintao
// Date        : 2026-09-20 / 2026-09-24 按新分层重构
// Version     : v4.0
// ----------------------------------------------------------------------------
// Description : IPv4 链路"网口1 打流 -> ARP -> 网口2 应答 -> 数据直达"板级实验
// ============================================================================

module ipv4_test_top(
  input  wire                                          sys_clk         ,

  output wire          [                   3: 0]       gt_txp_out_a    ,
  output wire          [                   3: 0]       gt_txn_out_a    ,
  input  wire          [                   3: 0]       gt_rxp_in_a     ,
  input  wire          [                   3: 0]       gt_rxn_in_a     ,
  input  wire                                          gt_ref_clk_p_a  ,
  input  wire                                          gt_ref_clk_n_a  ,

  output wire          [                   3: 0]       gt_txp_out_b    ,
  output wire          [                   3: 0]       gt_txn_out_b    ,
  input  wire          [                   3: 0]       gt_rxp_in_b     ,
  input  wire          [                   3: 0]       gt_rxn_in_b     ,
  input  wire                                          gt_ref_clk_p_b  ,
  input  wire                                          gt_ref_clk_n_b  ,

  output wire                                          qsfp_rstn_port_a,
  output wire                                          qsfp_lp_mode_port_a,
  output wire                                          qsfp_seln_port_a,
  input  wire                                          qsfp_prsn_port_a,
  output wire                                          qsfp_led_port_a ,

  output wire                                          qsfp_rstn_port_b,
  output wire                                          qsfp_lp_mode_port_b,
  output wire                                          qsfp_seln_port_b,
  input  wire                                          qsfp_prsn_port_b,
  output wire                                          qsfp_led_port_b  
);
  localparam LOCAL_IP_NUM= 2 ;
  localparam AXIS_WIDTH= 512;
  localparam AXIS_USER_WIDTH= 1 ;

  // ---------------- 网口1 / 网口2 配置(线序) ----------------
  localparam [   48*LOCAL_IP_NUM-1: 0]       CFG_P1_MAC= {48'h554433221100,48'h665544332200};              // 00:11:22:33:44:55
  localparam [   32*LOCAL_IP_NUM-1: 0]       CFG_P1_IP_LE= {32'hf101_A8C0,32'hf001_A8C0};                // 192.168.1.241
  localparam [   48*LOCAL_IP_NUM-1: 0]       CFG_P2_MAC= {48'h664433221100,48'h776644332200};              // 00:11:22:33:44:66
  localparam [   32*LOCAL_IP_NUM-1: 0]       CFG_P2_IP_LE= {32'hf201_A8C0,32'hf301_A8C0};                // 192.168.1.242

  localparam [   32*LOCAL_IP_NUM-1: 0]       CFG_GATEWAY_IP_LE= {32'h0101_A8C0,32'h0101_A8C0};          // 192.168.1.1
  localparam [   32*LOCAL_IP_NUM-1: 0]       CFG_SUBNET_LE= {32'h00FF_FFFF,32'h00FF_FFFF};               // /24
  localparam [                  56: 0]       CFG_PENDING_TIME= 57'd400_000_000;          // 1s @400MHz

  localparam PKT_LEN_BEATS= 16;                                        // 业务包 16*64 = 1024 字节
  localparam ONE_SEC_CYCLES= 32'd400_000_000;                          // 1 秒 @400MHz

  // ---------------- 时钟 / 复位 ----------------
  wire                                                 clk_400m           ;
  wire                                                 clk_locked         ;
  wire                                                 usr_tx_reset_a,  usr_rx_reset_a;
  wire                                                 usr_tx_reset_b,  usr_rx_reset_b;
  wire                                                 qsfp_gt_rst        ;
  wire                                                 test_enable        ;

  wire                                                 gt_txusrclk_a      ;
  wire                                                 gt_rxusrclk_a      ;
  wire                                                 gt_txusrclk_b      ;
  wire                                                 gt_rxusrclk_b      ;

  // ---------------- 网口1 : eth_top_a 分出的三类收流 ----------------
  wire                 [        AXIS_WIDTH-1: 0]       a_arp_data         ;
  wire                 [      AXIS_WIDTH/8-1: 0]       a_arp_keep         ;
  wire                                                 a_arp_last         ;
  wire                                                 a_arp_valid        ;
  wire                                                 a_arp_ready        ;
  wire                 [        AXIS_WIDTH-1: 0]       a_ipv4_data        ;
  wire                 [      AXIS_WIDTH/8-1: 0]       a_ipv4_keep        ;
  wire                                                 a_ipv4_last        ;
  wire                                                 a_ipv4_valid       ;
  wire                                                 a_ipv4_ready       ;

  // ---------------- 网口2 : eth_top_b 分出的三类收流 ----------------
  wire                 [        AXIS_WIDTH-1: 0]       b_arp_data         ;
  wire                 [      AXIS_WIDTH/8-1: 0]       b_arp_keep         ;
  wire                                                 b_arp_last         ;
  wire                                                 b_arp_valid        ;
  wire                                                 b_arp_ready        ;
  wire                 [        AXIS_WIDTH-1: 0]       b_ipv4_data        ;
  wire                 [      AXIS_WIDTH/8-1: 0]       b_ipv4_keep        ;
  wire                                                 b_ipv4_last        ;
  wire                                                 b_ipv4_valid       ;
  wire                                                 b_ipv4_ready       ;

  // ---------------- ARP 引擎 <-> eth_top 的 ARP 发流 ----------------
  wire                 [        AXIS_WIDTH-1: 0]       a_arp_tx_data      ;
  wire                 [      AXIS_WIDTH/8-1: 0]       a_arp_tx_keep      ;
  wire                                                 a_arp_tx_last      ;
  wire                                                 a_arp_tx_valid     ;
  wire                                                 a_arp_tx_ready     ;
  wire                 [        AXIS_WIDTH-1: 0]       b_arp_tx_data      ;
  wire                 [      AXIS_WIDTH/8-1: 0]       b_arp_tx_keep      ;
  wire                                                 b_arp_tx_last      ;
  wire                                                 b_arp_tx_valid     ;
  wire                                                 b_arp_tx_ready     ;

  // ---------------- ipv4_top 的收/发 ----------------
  wire                 [        AXIS_WIDTH-1: 0]       t1_mdata           ;
  wire                 [      AXIS_WIDTH/8-1: 0]       t1_mkeep           ;
  wire                                                 t1_mvalid          ;
  wire                                                 t1_mlast           ;
  wire                 [   AXIS_USER_WIDTH-1: 0]       t1_muser           ;
  wire                                                 t1_mready          ;

  wire                 [        AXIS_WIDTH-1: 0]       p1_tx_data         ;
  wire                 [      AXIS_WIDTH/8-1: 0]       p1_tx_keep         ;
  wire                                                 p1_tx_last         ;
  wire                                                 p1_tx_valid        ;
  wire                                                 p1_tx_ready        ;

  wire                 [        AXIS_WIDTH-1: 0]       t2_mdata           ;
  wire                 [      AXIS_WIDTH/8-1: 0]       t2_mkeep           ;
  wire                                                 t2_mvalid          ;
  wire                                                 t2_mlast           ;
  wire                 [   AXIS_USER_WIDTH-1: 0]       t2_muser           ;
  wire                                                 t2_mready          ;

  wire                 [        AXIS_WIDTH-1: 0]       p2_tx_data         ;
  wire                 [      AXIS_WIDTH/8-1: 0]       p2_tx_keep         ;
  wire                                                 p2_tx_last         ;
  wire                                                 p2_tx_valid        ;
  wire                                                 p2_tx_ready        ;

  wire                 [        AXIS_WIDTH-1: 0]       p1_o_data          ;
  wire                 [      AXIS_WIDTH/8-1: 0]       p1_o_keep          ;
  wire                                                 p1_o_valid         ;
  wire                                                 p1_o_last          ;
  wire                                                 p1_o_ready         ;
  wire                 [                  95: 0]       p1_o_usr           ;

  wire                 [        AXIS_WIDTH-1: 0]       p2_o_data          ;
  wire                 [      AXIS_WIDTH/8-1: 0]       p2_o_keep          ;
  wire                                                 p2_o_valid         ;
  wire                                                 p2_o_last          ;
  wire                                                 p2_o_ready         ;
  wire                 [                  95: 0]       p2_o_usr           ;

  // ---------------- ARP 查询握手(ipv4_top <-> arp_engine_top) ----------------
  wire                 [                  31: 0]       q1_src_ip          ;
  wire                 [                  31: 0]       q1_dst_ip          ;
  wire                                                 q1_valid_pulse     ;
  wire                 [                  47: 0]       r1_dst_mac         ;
  wire                 [                  47: 0]       r1_src_mac         ;
  wire                                                 r1_miss            ;
  wire                                                 r1_valid           ;

  wire                 [                  31: 0]       q2_src_ip          ;
  wire                 [                  31: 0]       q2_dst_ip          ;
  wire                                                 q2_valid_pulse     ;
  wire                 [                  47: 0]       r2_dst_mac         ;
  wire                 [                  47: 0]       r2_src_mac         ;
  wire                                                 r2_miss            ;
  wire                                                 r2_valid           ;

  reg                                                  usr_rst            ;

  // ---------------- 状态观测(两口各自一套, mark_debug) ----------------
(* mark_debug = "true" *)   wire                                                 stat1_rx_error,  stat1_ack_ovf,stat1_pend_ovf,stat1_no_resp;
(* mark_debug = "true" *)   wire                                                 stat1_pend_clr,  stat1_cache_clr;
(* mark_debug = "true" *)   wire                 [                   1: 0]       stat1_arb_port     ;
(* mark_debug = "true" *)   wire                                                 stat1_arb_idle     ;
(* mark_debug = "true" *)   wire                                                 stat1_query_src_not_local  ;
(* mark_debug = "true" *)   wire                                                 stat2_rx_error,  stat2_ack_ovf,stat2_pend_ovf,stat2_no_resp;
(* mark_debug = "true" *)   wire                                                 stat2_pend_clr,  stat2_cache_clr;
(* mark_debug = "true" *)   wire                 [                   1: 0]       stat2_arb_port     ;
(* mark_debug = "true" *)   wire                                                 stat2_arb_idle     ;
(* mark_debug = "true" *)   wire                                                 stat2_query_src_not_local  ;
  // ============================================================================
  // 时钟与复位
  // ============================================================================
  assign  qsfp_gt_rst      = usr_tx_reset_a | usr_rx_reset_a | usr_tx_reset_b | usr_rx_reset_b;

(* ASYNC_REG = "true" *)   reg                  [                   1: 0]       rst_sync         =2'b11;
  always @(posedge clk_400m or posedge qsfp_gt_rst) begin
    if (qsfp_gt_rst) rst_sync <= 2'b11;
    else             rst_sync <= {rst_sync[0], 1'b0};
  end

  always @(posedge clk_400m) begin
    usr_rst       <= rst_sync[1];
  end

  clk_100_to_400m u_clk_100_to_400m (
    .clk_400m         (clk_400m         ),
    .locked           (clk_locked       ),
    .clk_100m         (sys_clk          ) 
  );

  // ============================================================================
  // 网口1 : eth_top(A 片 CMAC) + arp_engine_top#1 + ipv4_top#1
  // ============================================================================
  eth_top #(
    .PORT_SEL         (0                ),// 0 = cmac_a_if
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ) 
  ) u_eth_top_a (
    .init_clk         (sys_clk          ),
    .sys_reset        (~clk_locked      ),// 时钟未锁定期间复位 CMAC
    .gt_txusrclk      (gt_txusrclk_a    ),
    .gt_rxusrclk      (gt_rxusrclk_a    ),
    .usr_tx_reset     (usr_tx_reset_a   ),
    .usr_rx_reset     (usr_rx_reset_a   ),
    .gt_txp_out       (gt_txp_out_a     ),
    .gt_txn_out       (gt_txn_out_a     ),
    .gt_rxp_in        (gt_rxp_in_a      ),
    .gt_rxn_in        (gt_rxn_in_a      ),
    .gt_ref_clk_p     (gt_ref_clk_p_a   ),
    .gt_ref_clk_n     (gt_ref_clk_n_a   ),
    .qsfp_rstn_port   (qsfp_rstn_port_a ),
    .qsfp_lp_mode_port(qsfp_lp_mode_port_a),
    .qsfp_seln_port   (qsfp_seln_port_a ),
    .qsfp_prsn_port   (qsfp_prsn_port_a ),
    .qsfp_led_port    (qsfp_led_port_a  ),
    .clk              (clk_400m         ),
    .rst              (usr_rst          ),
    .fifo_tx_rst      (usr_rst          ),
    // RX 三类流输出
    .arp_axis_mdata   (a_arp_data       ),
    .arp_axis_mkeep   (a_arp_keep       ),
    .arp_axis_mlast   (a_arp_last       ),
    .arp_axis_mvalid  (a_arp_valid      ),
    .arp_axis_mready  (a_arp_ready      ),
    .other_axis_mdata (                 ),// 非 ARP/IPv4 直接丢弃
    .other_axis_mkeep (                 ),
    .other_axis_mlast (                 ),
    .other_axis_mvalid(                 ),
    .other_axis_mready(1'b1             ),
    .ipv4_axis_mdata  (a_ipv4_data      ),// 网口1 不收 IPv4 => 收下即丢弃
    .ipv4_axis_mkeep  (a_ipv4_keep      ),
    .ipv4_axis_mlast  (a_ipv4_last      ),
    .ipv4_axis_mvalid (a_ipv4_valid     ),
    .ipv4_axis_mready (a_ipv4_ready     ),
    // TX 三类流入口
    .arp_axis_sdata   (a_arp_tx_data    ),
    .arp_axis_skeep   (a_arp_tx_keep    ),
    .arp_axis_slast   (a_arp_tx_last    ),
    .arp_axis_svalid  (a_arp_tx_valid   ),
    .arp_axis_sready  (a_arp_tx_ready   ),
    .other_axis_sdata ({AXIS_WIDTH{1'b0}}),// 预留口, 当前无驱动
    .other_axis_skeep ({(AXIS_WIDTH/8){1'b0}}),
    .other_axis_slast (1'b0             ),
    .other_axis_svalid(1'b0             ),
    .other_axis_sready(                 ),
    .ipv4_axis_sdata  (p1_tx_data       ),
    .ipv4_axis_skeep  (p1_tx_keep       ),
    .ipv4_axis_slast  (p1_tx_last       ),
    .ipv4_axis_svalid (p1_tx_valid      ),
    .ipv4_axis_sready (p1_tx_ready      ),
    .stat_tx_active_port(stat1_arb_port   ),
    .stat_tx_idle     (stat1_arb_idle   ) 
  );

  assign  a_ipv4_ready     = 1'b1             ;// 网口1 不收 IPv4, 收下即丢弃

  arp_engine_top #(
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .LOCAL_IP_NUM     (LOCAL_IP_NUM     ) 
  ) u_arp_eng_a (
    .clk              (clk_400m         ),
    .rst              (usr_rst          ),
    .query_src_ip     (q1_src_ip        ),
    .query_dst_ip     (q1_dst_ip        ),
    .query_valid_pulse(q1_valid_pulse   ),
    .arp_dst_mac      (r1_dst_mac       ),
    .arp_src_mac      (r1_src_mac       ),
    .arp_miss         (r1_miss          ),
    .arp_valid        (r1_valid         ),
    .arp_axis_sdata   (a_arp_data       ),
    .arp_axis_skeep   (a_arp_keep       ),
    .arp_axis_svalid  (a_arp_valid      ),
    .arp_axis_slast   (a_arp_last       ),
    .arp_axis_sready  (a_arp_ready      ),
    .arp_axis_mdata   (a_arp_tx_data    ),
    .arp_axis_mkeep   (a_arp_tx_keep    ),
    .arp_axis_mvalid  (a_arp_tx_valid   ),
    .arp_axis_mlast   (a_arp_tx_last    ),
    .arp_axis_mready  (a_arp_tx_ready   ),
    .cfg_local_ip     (CFG_P1_IP_LE     ),
    .cfg_local_mac    (CFG_P1_MAC       ),
    .cfg_gateway_ip   (CFG_GATEWAY_IP_LE),
    .cfg_subnet_mask  (CFG_SUBNET_LE    ),
    .cfg_pending_time (CFG_PENDING_TIME ),
    .cfg_clear_cache  (1'b0             ),
    .cfg_clear_pending(1'b0             ),
    .stat_rx_error    (stat1_rx_error   ),
    .stat_ack_fifo_overflow_error(stat1_ack_ovf    ),
    .stat_pending_fifo_overflow_error(stat1_pend_ovf   ),
    .stat_lookup_no_resp_error(stat1_no_resp    ),
    .stat_pending_clear_finish(stat1_pend_clr   ),
    .stat_cache_clear_finish(stat1_cache_clr  ),
    .stat_query_src_not_local(stat1_query_src_not_local) 
  );

  ipv4_top #(
    .AXIS_WIDTH       (AXIS_WIDTH       ) 
  ) u_port1 (
    .clk              (clk_400m         ),
    .rst              (usr_rst          ),
    // RX : 网口1 **不收** IPv4(eth_top_a 的 ipv4 输出恒 ready 丢弃)
    .eth_ipv4_axis_sdata({AXIS_WIDTH{1'b0}}),
    .eth_ipv4_axis_skeep({(AXIS_WIDTH/8){1'b0}}),
    .eth_ipv4_axis_slast(1'b0             ),
    .eth_ipv4_axis_svalid(1'b0             ),
    .eth_ipv4_axis_sready(                 ),
    // RX 输出(纯 IPv4) -> 打流机(本实验恒空闲)
    .ipv4_udp_axis_mdata(p1_o_data        ),
    .ipv4_udp_axis_mkeep(p1_o_keep        ),
    .ipv4_udp_axis_mlast(p1_o_last        ),
    .ipv4_udp_axis_mvalid(p1_o_valid       ),
    .ipv4_udp_axis_musr(p1_o_usr         ),
    .ipv4_udp_axis_mready(p1_o_ready       ),
    .ipv4_icmp_axis_mdata(                 ),
    .ipv4_icmp_axis_mkeep(                 ),
    .ipv4_icmp_axis_mlast(                 ),
    .ipv4_icmp_axis_mvalid(                 ),
    .ipv4_icmp_axis_musr(                 ),
    .ipv4_icmp_axis_mready(1'd1             ),
    .ipv4_ospf_axis_mdata(                 ),
    .ipv4_ospf_axis_mkeep(                 ),
    .ipv4_ospf_axis_mlast(                 ),
    .ipv4_ospf_axis_mvalid(                 ),
    .ipv4_ospf_axis_musr(                 ),
    .ipv4_ospf_axis_mready(1'd1             ),
    .ipv4_other_axis_mdata(                 ),
    .ipv4_other_axis_mkeep(                 ),
    .ipv4_other_axis_mlast(                 ),
    .ipv4_other_axis_mvalid(                 ),
    .ipv4_other_axis_musr(                 ),
    .ipv4_other_axis_mready(1'd1             ),

    // TX : 打流机 -> ipv4_top#1
    .ipv4_other_axis_sdata('d0              ),
    .ipv4_other_axis_skeep('d0              ),
    .ipv4_other_axis_slast('d0              ),
    .ipv4_other_axis_svalid('d0              ),
    .ipv4_other_axis_sready(                 ),
    .ipv4_ospf_axis_sdata('d0              ),
    .ipv4_ospf_axis_skeep('d0              ),
    .ipv4_ospf_axis_slast('d0              ),
    .ipv4_ospf_axis_svalid('d0              ),
    .ipv4_ospf_axis_sready(                 ),
    .ipv4_icmp_axis_sdata('d0              ),
    .ipv4_icmp_axis_skeep('d0              ),
    .ipv4_icmp_axis_slast('d0              ),
    .ipv4_icmp_axis_svalid('d0              ),
    .ipv4_icmp_axis_sready(                 ),
    .ipv4_udp_axis_sdata(t1_mdata         ),
    .ipv4_udp_axis_skeep(t1_mkeep         ),
    .ipv4_udp_axis_slast(t1_mlast         ),
    .ipv4_udp_axis_svalid(t1_mvalid        ),
    .ipv4_udp_axis_sready(t1_mready        ),

    // TX 输出(完整以太帧) -> eth_top_a 的 ipv4 入口
    .eth_tx_axis_mdata(p1_tx_data       ),
    .eth_tx_axis_mkeep(p1_tx_keep       ),
    .eth_tx_axis_mlast(p1_tx_last       ),
    .eth_tx_axis_mvalid(p1_tx_valid      ),
    .eth_tx_axis_mready(p1_tx_ready      ),
    // ARP 查询握手 -> arp_engine_top#1
    .query_src_ip     (q1_src_ip        ),
    .query_dst_ip     (q1_dst_ip        ),
    .query_valid_pulse(q1_valid_pulse   ),
    .arp_dst_mac      (r1_dst_mac       ),
    .arp_src_mac      (r1_src_mac       ),
    .arp_miss         (r1_miss          ),
    .arp_valid        (r1_valid         ),
    .stat_active_port (                 ),
    .stat_idle        (                 ) 
  );

  // ============================================================================
  // 网口2 : eth_top(B 片 CMAC) + arp_engine_top#2 + ipv4_top#2
  // ============================================================================
  eth_top #(
    .PORT_SEL         (1                ),// 1 = cmac_b_if
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ) 
  ) u_eth_top_b (
    .init_clk         (sys_clk          ),
    .sys_reset        (~clk_locked      ),
    .gt_txusrclk      (gt_txusrclk_b    ),
    .gt_rxusrclk      (gt_rxusrclk_b    ),
    .usr_tx_reset     (usr_tx_reset_b   ),
    .usr_rx_reset     (usr_rx_reset_b   ),
    .gt_txp_out       (gt_txp_out_b     ),
    .gt_txn_out       (gt_txn_out_b     ),
    .gt_rxp_in        (gt_rxp_in_b      ),
    .gt_rxn_in        (gt_rxn_in_b      ),
    .gt_ref_clk_p     (gt_ref_clk_p_b   ),
    .gt_ref_clk_n     (gt_ref_clk_n_b   ),
    .qsfp_rstn_port   (qsfp_rstn_port_b ),
    .qsfp_lp_mode_port(qsfp_lp_mode_port_b),
    .qsfp_seln_port   (qsfp_seln_port_b ),
    .qsfp_prsn_port   (qsfp_prsn_port_b ),
    .qsfp_led_port    (qsfp_led_port_b  ),
    .clk              (clk_400m         ),
    .rst              (usr_rst          ),
    .fifo_tx_rst      (usr_rst          ),
    // RX 三类流输出
    .arp_axis_mdata   (b_arp_data       ),
    .arp_axis_mkeep   (b_arp_keep       ),
    .arp_axis_mlast   (b_arp_last       ),
    .arp_axis_mvalid  (b_arp_valid      ),
    .arp_axis_mready  (b_arp_ready      ),
    .other_axis_mdata (                 ),// 非 ARP/IPv4 直接丢弃
    .other_axis_mkeep (                 ),
    .other_axis_mlast (                 ),
    .other_axis_mvalid(                 ),
    .other_axis_mready(1'b1             ),
    .ipv4_axis_mdata  (b_ipv4_data      ),
    .ipv4_axis_mkeep  (b_ipv4_keep      ),
    .ipv4_axis_mlast  (b_ipv4_last      ),
    .ipv4_axis_mvalid (b_ipv4_valid     ),
    .ipv4_axis_mready (b_ipv4_ready     ),
    // TX 三类流入口
    .arp_axis_sdata   (b_arp_tx_data    ),
    .arp_axis_skeep   (b_arp_tx_keep    ),
    .arp_axis_slast   (b_arp_tx_last    ),
    .arp_axis_svalid  (b_arp_tx_valid   ),
    .arp_axis_sready  (b_arp_tx_ready   ),
    .other_axis_sdata ({AXIS_WIDTH{1'b0}}),// 预留口, 当前无驱动
    .other_axis_skeep ({(AXIS_WIDTH/8){1'b0}}),
    .other_axis_slast (1'b0             ),
    .other_axis_svalid(1'b0             ),
    .other_axis_sready(                 ),
    .ipv4_axis_sdata  (p2_tx_data       ),
    .ipv4_axis_skeep  (p2_tx_keep       ),
    .ipv4_axis_slast  (p2_tx_last       ),
    .ipv4_axis_svalid (p2_tx_valid      ),
    .ipv4_axis_sready (p2_tx_ready      ),
    .stat_tx_active_port(stat2_arb_port   ),
    .stat_tx_idle     (stat2_arb_idle   ) 
  );

  arp_engine_top #(
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .LOCAL_IP_NUM     (LOCAL_IP_NUM     ) 
  ) u_arp_eng_b (
    .clk              (clk_400m         ),
    .rst              (usr_rst          ),
    .query_src_ip     (q2_src_ip        ),
    .query_dst_ip     (q2_dst_ip        ),
    .query_valid_pulse(q2_valid_pulse   ),
    .arp_dst_mac      (r2_dst_mac       ),
    .arp_src_mac      (r2_src_mac       ),
    .arp_miss         (r2_miss          ),
    .arp_valid        (r2_valid         ),
    .arp_axis_sdata   (b_arp_data       ),
    .arp_axis_skeep   (b_arp_keep       ),
    .arp_axis_svalid  (b_arp_valid      ),
    .arp_axis_slast   (b_arp_last       ),
    .arp_axis_sready  (b_arp_ready      ),
    .arp_axis_mdata   (b_arp_tx_data    ),
    .arp_axis_mkeep   (b_arp_tx_keep    ),
    .arp_axis_mvalid  (b_arp_tx_valid   ),
    .arp_axis_mlast   (b_arp_tx_last    ),
    .arp_axis_mready  (b_arp_tx_ready   ),
    .cfg_local_ip     (CFG_P2_IP_LE     ),
    .cfg_local_mac    (CFG_P2_MAC       ),
    .cfg_gateway_ip   (CFG_GATEWAY_IP_LE),
    .cfg_subnet_mask  (CFG_SUBNET_LE    ),
    .cfg_pending_time (CFG_PENDING_TIME ),
    .cfg_clear_cache  (1'b0             ),
    .cfg_clear_pending(1'b0             ),
    .stat_rx_error    (stat2_rx_error   ),
    .stat_ack_fifo_overflow_error(stat2_ack_ovf    ),
    .stat_pending_fifo_overflow_error(stat2_pend_ovf   ),
    .stat_lookup_no_resp_error(stat2_no_resp    ),
    .stat_pending_clear_finish(stat2_pend_clr   ),
    .stat_cache_clear_finish(stat2_cache_clr  ),
    .stat_query_src_not_local(stat2_query_src_not_local) 
  );

  ipv4_top #(
    .AXIS_WIDTH       (AXIS_WIDTH       ) 
  ) u_port2 (
    .clk              (clk_400m         ),
    .rst              (usr_rst          ),
    // RX : eth_top_b 分出的 IPv4 以太帧 -> ipv4_eth_rx 剥头 -> 校验机
    .eth_ipv4_axis_sdata(b_ipv4_data      ),
    .eth_ipv4_axis_skeep(b_ipv4_keep      ),
    .eth_ipv4_axis_slast(b_ipv4_last      ),
    .eth_ipv4_axis_svalid(b_ipv4_valid     ),
    .eth_ipv4_axis_sready(b_ipv4_ready     ),
    // RX 输出(纯 IPv4) -> 校验机
    .ipv4_udp_axis_mdata(p2_o_data        ),
    .ipv4_udp_axis_mkeep(p2_o_keep        ),
    .ipv4_udp_axis_mlast(p2_o_last        ),
    .ipv4_udp_axis_mvalid(p2_o_valid       ),
    .ipv4_udp_axis_musr(p2_o_usr         ),
    .ipv4_udp_axis_mready(p2_o_ready       ),
    .ipv4_icmp_axis_mdata(                 ),
    .ipv4_icmp_axis_mkeep(                 ),
    .ipv4_icmp_axis_mlast(                 ),
    .ipv4_icmp_axis_mvalid(                 ),
    .ipv4_icmp_axis_musr(                 ),
    .ipv4_icmp_axis_mready(1'd1             ),
    .ipv4_ospf_axis_mdata(                 ),
    .ipv4_ospf_axis_mkeep(                 ),
    .ipv4_ospf_axis_mlast(                 ),
    .ipv4_ospf_axis_mvalid(                 ),
    .ipv4_ospf_axis_musr(                 ),
    .ipv4_ospf_axis_mready(1'd1             ),
    .ipv4_other_axis_mdata(                 ),
    .ipv4_other_axis_mkeep(                 ),
    .ipv4_other_axis_mlast(                 ),
    .ipv4_other_axis_mvalid(                 ),
    .ipv4_other_axis_musr(                 ),
    .ipv4_other_axis_mready(1'd1             ),

    // TX : 校验机(本实验不发流)
    .ipv4_other_axis_sdata('d0              ),
    .ipv4_other_axis_skeep('d0              ),
    .ipv4_other_axis_slast('d0              ),
    .ipv4_other_axis_svalid('d0              ),
    .ipv4_other_axis_sready(                 ),
    .ipv4_ospf_axis_sdata('d0              ),
    .ipv4_ospf_axis_skeep('d0              ),
    .ipv4_ospf_axis_slast('d0              ),
    .ipv4_ospf_axis_svalid('d0              ),
    .ipv4_ospf_axis_sready(                 ),
    .ipv4_icmp_axis_sdata('d0              ),
    .ipv4_icmp_axis_skeep('d0              ),
    .ipv4_icmp_axis_slast('d0              ),
    .ipv4_icmp_axis_svalid('d0              ),
    .ipv4_icmp_axis_sready(                 ),
    .ipv4_udp_axis_sdata(t2_mdata         ),
    .ipv4_udp_axis_skeep(t2_mkeep         ),
    .ipv4_udp_axis_slast(t2_mlast         ),
    .ipv4_udp_axis_svalid(t2_mvalid        ),
    .ipv4_udp_axis_sready(t2_mready        ),

    // TX 输出(完整以太帧) -> eth_top_b 的 ipv4 入口
    .eth_tx_axis_mdata(p2_tx_data       ),
    .eth_tx_axis_mkeep(p2_tx_keep       ),
    .eth_tx_axis_mlast(p2_tx_last       ),
    .eth_tx_axis_mvalid(p2_tx_valid      ),
    .eth_tx_axis_mready(p2_tx_ready      ),
    // ARP 查询握手 -> arp_engine_top#2
    .query_src_ip     (q2_src_ip        ),
    .query_dst_ip     (q2_dst_ip        ),
    .query_valid_pulse(q2_valid_pulse   ),
    .arp_dst_mac      (r2_dst_mac       ),
    .arp_src_mac      (r2_src_mac       ),
    .arp_miss         (r2_miss          ),
    .arp_valid        (r2_valid         ),
    .stat_active_port (                 ),
    .stat_idle        (                 ) 
  );

  // ============================================================================
  // 打流机(网口1) / 校验机(网口2)
  // ============================================================================
  ipv4_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .PKT_LEN_BEATS    (PKT_LEN_BEATS    ),
    .ONE_SEC_CYCLES   (ONE_SEC_CYCLES   ),
    .DST_IP_LE        (CFG_P2_IP_LE[31:0]),// 打流给网口2
    .SRC_IP_LE        (CFG_P1_IP_LE[31:0]) 
  ) u_tester1 (
    .clk              (clk_400m         ),
    .rst              (usr_rst          ),
    // TX : 纯 IPv4 包 -> ipv4_top#1
    .axis_mdata       (t1_mdata         ),
    .axis_mkeep       (t1_mkeep         ),
    .axis_mvalid      (t1_mvalid        ),
    .axis_mlast       (t1_mlast         ),
    .axis_muser       (t1_muser         ),
    .axis_mready      (t1_mready        ),
    // RX : ipv4_top#1 剥头输出(本实验恒空闲)
    .axis_sdata       (p1_o_data        ),
    .axis_skeep       (p1_o_keep        ),
    .axis_svalid      (p1_o_valid       ),
    .axis_slast       (p1_o_last        ),
    .axis_suser       (1'b0             ),
    .axis_sready      (p1_o_ready       ),
    .test_enable      (test_enable      ) // VIO 控制
  );

  ipv4_100g_tester #(
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .PKT_LEN_BEATS    (PKT_LEN_BEATS    ),
    .ONE_SEC_CYCLES   (ONE_SEC_CYCLES   ),
    .DST_IP_LE        (CFG_P2_IP_LE[31:0]),// 期望收到的包与打流机发出的包一致
    .SRC_IP_LE        (CFG_P1_IP_LE[31:0]) 
  ) u_tester2 (
    .clk              (clk_400m         ),
    .rst              (usr_rst          ),
    // TX : 不发流(test_enable = 0)
    .axis_mdata       (t2_mdata         ),
    .axis_mkeep       (t2_mkeep         ),
    .axis_mvalid      (t2_mvalid        ),
    .axis_mlast       (t2_mlast         ),
    .axis_muser       (t2_muser         ),
    .axis_mready      (t2_mready        ),
    // RX : ipv4_top#2 剥头输出 = 校验对象
    .axis_sdata       (p2_o_data        ),
    .axis_skeep       (p2_o_keep        ),
    .axis_svalid      (p2_o_valid       ),
    .axis_slast       (p2_o_last        ),
    .axis_suser       (1'b0             ),
    .axis_sready      (p2_o_ready       ),
    .test_enable      (1'b0             ) // 纯校验机
  );

  // ============================================================================
  // VIO : 启动/停止打流
  // ============================================================================
  vio_enable u_test_vio_enable (
    .clk              (clk_400m         ),// input wire clk
    .probe_out0       (test_enable      ) // output wire [0 : 0] probe_out0
  );


(* mark_debug = "true" *) wire b_ipv4_ready_dbg      = b_ipv4_ready;      // H3: 是否堵在 IPv4 RX
(* mark_debug = "true" *) wire b_arp_rx_hs_dbg       = b_arp_valid && b_arp_ready;  // ARP 帧是否真进来
(* mark_debug = "true" *) wire b_arp_tx_blk_dbg      = b_arp_tx_valid && !b_arp_tx_ready; // 应答是否卡在出口


endmodule
