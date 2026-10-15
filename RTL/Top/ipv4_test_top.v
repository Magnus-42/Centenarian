`timescale 1ns / 1ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv4_test_top.v
// Module Name : ipv4_test_top
// Author      : LiXintao
// Date        : 2026-10-12
// Version     : v5.1
// ----------------------------------------------------------------------------
// Description : IPv4 链路"网口1 打流 -> ARP -> 网口2 应答 -> 数据直达"板级实验
//               v5.0: 跟随 eth_top/ipv4_top flat 化重写接口(RX/TX 均按档位拼接)
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

  // ---------------- 网口1 / 网口2 配置(线序) ----------------
  localparam [   48*LOCAL_IP_NUM-1: 0]       CFG_P1_MAC= {48'h554433221100,48'h665544332200};
  localparam [   32*LOCAL_IP_NUM-1: 0]       CFG_P1_IP_LE= {32'hf101_A8C0,32'hf001_A8C0};
  localparam [   48*LOCAL_IP_NUM-1: 0]       CFG_P2_MAC= {48'h664433221100,48'h776644332200};
  localparam [   32*LOCAL_IP_NUM-1: 0]       CFG_P2_IP_LE= {32'hf201_A8C0,32'hf301_A8C0};

  localparam [   32*LOCAL_IP_NUM-1: 0]       CFG_GATEWAY_IP_LE= {32'h0101_A8C0,32'h0101_A8C0};
  localparam [   32*LOCAL_IP_NUM-1: 0]       CFG_SUBNET_LE= {32'h00FF_FFFF,32'h00FF_FFFF};
  localparam [                  56: 0]       CFG_PENDING_TIME= 57'd400_000_000;

  localparam PKT_LEN_BEATS= 16;
  localparam ONE_SEC_CYCLES= 32'd400_000_000;

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

  // ---------------- eth_top RX flat(两口各自一套) ----------------
  // 档位: ch0=arp / ch1=ipv4 / ch2=other(RX_TYPE_NUM=2, dict={0608,0008})
  wire                 [       512*3-1: 0]       a_rx_data         ;
  wire                 [        64*3-1: 0]       a_rx_keep         ;
  wire                 [           2: 0]       a_rx_last         ;
  wire                 [           2: 0]       a_rx_valid        ;
  wire                 [           2: 0]       a_rx_ready        ;
  wire                 [           2: 0]       a_rx_usr          ;

  wire                 [       512*3-1: 0]       b_rx_data         ;
  wire                 [        64*3-1: 0]       b_rx_keep         ;
  wire                 [           2: 0]       b_rx_last         ;
  wire                 [           2: 0]       b_rx_valid        ;
  wire                 [           2: 0]       b_rx_ready        ;
  wire                 [           2: 0]       b_rx_usr          ;

  // ---------------- eth_top TX flat(两口各自一套) ----------------
  // 口序: lane0=arp / lane1=88B5预留 / lane2=ipv4 / lane3=ipv6预留 (TX_TYPE_NUM=4)
  wire                 [       512*4-1: 0]       a_tx_data         ;
  wire                 [        64*4-1: 0]       a_tx_keep         ;
  wire                 [           3: 0]       a_tx_last         ;
  wire                 [           3: 0]       a_tx_valid        ;
  wire                 [           3: 0]       a_tx_ready        ;
  wire                 [   4*4-1: 0]             a_tx_usr          ;

  wire                 [       512*4-1: 0]       b_tx_data         ;
  wire                 [        64*4-1: 0]       b_tx_keep         ;
  wire                 [           3: 0]       b_tx_last         ;
  wire                 [           3: 0]       b_tx_valid        ;
  wire                 [           3: 0]       b_tx_ready        ;
  wire                 [   4*4-1: 0]             b_tx_usr          ;

  // ---------------- ARP 引擎 <-> eth_top 的 ARP 收发流 ----------------
  wire                 [                 511: 0]       a_arp_data         ;
  wire                 [                  63: 0]       a_arp_keep         ;
  wire                                                 a_arp_last         ;
  wire                                                 a_arp_valid        ;
  wire                                                 a_arp_ready        ;
  wire                 [                   3: 0]       a_arp_tx_usr       ;
  wire                 [                 511: 0]       a_arp_tx_data      ;
  wire                 [                  63: 0]       a_arp_tx_keep      ;
  wire                                                 a_arp_tx_last      ;
  wire                                                 a_arp_tx_valid     ;
  wire                                                 a_arp_tx_ready     ;

  wire                 [                 511: 0]       b_arp_data         ;
  wire                 [                  63: 0]       b_arp_keep         ;
  wire                                                 b_arp_last         ;
  wire                                                 b_arp_valid        ;
  wire                                                 b_arp_ready        ;
  wire                 [                   3: 0]       b_arp_tx_usr       ;
  wire                 [                 511: 0]       b_arp_tx_data      ;
  wire                 [                  63: 0]       b_arp_tx_keep      ;
  wire                                                 b_arp_tx_last      ;
  wire                                                 b_arp_tx_valid     ;
  wire                                                 b_arp_tx_ready     ;

  // ---------------- ipv4_top : eth 入口 / RX flat 出 / TX 单路 ----------------
  wire                 [                 511: 0]       p1_ipv4_data       ;
  wire                 [                  63: 0]       p1_ipv4_keep       ;
  wire                                                 p1_ipv4_last       ;
  wire                                                 p1_ipv4_valid      ;
  wire                                                 p1_ipv4_ready      ;

  wire                 [       512*2-1: 0]       p1_o_data          ;
  wire                 [        64*2-1: 0]       p1_o_keep          ;
  wire                 [           1: 0]       p1_o_valid         ;
  wire                 [           1: 0]       p1_o_last          ;
  wire                 [           1: 0]       p1_o_ready         ;
  wire                 [        97*2-1: 0]       p1_o_usr           ;

  wire                 [                 511: 0]       p1_tx_data         ;
  wire                 [                  63: 0]       p1_tx_keep         ;
  wire                                                 p1_tx_last         ;
  wire                                                 p1_tx_valid        ;
  wire                                                 p1_tx_ready        ;
  wire                 [           3: 0]       p1_tx_usr          ;

  wire                 [                 511: 0]       p2_ipv4_data       ;
  wire                 [                  63: 0]       p2_ipv4_keep       ;
  wire                                                 p2_ipv4_last       ;
  wire                                                 p2_ipv4_valid      ;
  wire                                                 p2_ipv4_ready      ;

  wire                 [       512*2-1: 0]       p2_o_data          ;
  wire                 [        64*2-1: 0]       p2_o_keep          ;
  wire                 [           1: 0]       p2_o_valid         ;
  wire                 [           1: 0]       p2_o_last          ;
  wire                 [           1: 0]       p2_o_ready         ;
  wire                 [        97*2-1: 0]       p2_o_usr           ;

  wire                 [                 511: 0]       p2_tx_data         ;
  wire                 [                  63: 0]       p2_tx_keep         ;
  wire                                                 p2_tx_last         ;
  wire                                                 p2_tx_valid        ;
  wire                                                 p2_tx_ready        ;
  wire                 [           3: 0]       p2_tx_usr          ;

  // ---------------- 打流机 / 校验机 ----------------
  wire                 [                 511: 0]       t1_mdata           ;
  wire                 [                  63: 0]       t1_mkeep           ;
  wire                                                 t1_mvalid          ;
  wire                                                 t1_mlast           ;
  wire                 [                   3: 0]       t1_musr            ;
  wire                                                 t1_mready          ;

  wire                 [                 511: 0]       t2_mdata           ;
  wire                 [                  63: 0]       t2_mkeep           ;
  wire                                                 t2_mvalid          ;
  wire                                                 t2_mlast           ;
  wire                 [                   3: 0]       t2_musr            ;
  wire                                                 t2_mready          ;

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
(* mark_debug = "true" *)   wire                                                 stat1_ipv4_port    ;
(* mark_debug = "true" *)   wire                                                 stat1_ipv4_idle    ;
(* mark_debug = "true" *)   wire                                                 stat1_query_src_not_local  ;
(* mark_debug = "true" *)   wire                                                 stat2_rx_error,  stat2_ack_ovf,stat2_pend_ovf,stat2_no_resp;
(* mark_debug = "true" *)   wire                                                 stat2_pend_clr,  stat2_cache_clr;
(* mark_debug = "true" *)   wire                 [                   1: 0]       stat2_arb_port     ;
(* mark_debug = "true" *)   wire                                                 stat2_arb_idle     ;
(* mark_debug = "true" *)   wire                                                 stat2_ipv4_port    ;
(* mark_debug = "true" *)   wire                                                 stat2_ipv4_idle    ;
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
    .PORT_SEL         (0                ),
    .RX_TYPE_NUM      (2                ),
    .RX_TYPE_DICT     ({16'h0608, 16'h0008}),
    .TX_TYPE_NUM      (4                )
  ) u_eth_top_a (
    .init_clk         (sys_clk          ),
    .sys_reset        (~clk_locked      ),
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
    .mac_axis_mdata   (a_rx_data        ),
    .mac_axis_mkeep   (a_rx_keep        ),
    .mac_axis_mlast   (a_rx_last        ),
    .mac_axis_mvalid  (a_rx_valid       ),
    .mac_axis_musr    (a_rx_usr         ),
    .mac_axis_mready  (a_rx_ready       ),
    .mac_axis_sdata   (a_tx_data        ),
    .mac_axis_skeep   (a_tx_keep        ),
    .mac_axis_slast   (a_tx_last        ),
    .mac_axis_svalid  (a_tx_valid       ),
    .mac_axis_susr    (a_tx_usr         ),
    .mac_axis_sready  (a_tx_ready       ),
    .stat_tx_active_port(stat1_arb_port   ),
    .stat_tx_idle     (stat1_arb_idle   )
  );

  assign  a_rx_ready[2] = 1'b1             ;// other 兜底档收下即丢弃

  arp_engine_top #(
    .AXIS_WIDTH       (512              ),
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
    .arp_axis_susr    (a_rx_usr[0]      ),
    .arp_axis_sready  (a_arp_ready      ),
    .arp_axis_mdata   (a_arp_tx_data    ),
    .arp_axis_mkeep   (a_arp_tx_keep    ),
    .arp_axis_mvalid  (a_arp_tx_valid   ),
    .arp_axis_mlast   (a_arp_tx_last    ),
    .arp_axis_musr    (a_arp_tx_usr     ),
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
    .RX_TYPE_NUM      (1                ),
    .RX_TYPE_DICT     ({8'h11}          ),
    .TX_TYPE_NUM      (1                ),
    .AXIS_USER_WIDTH  (4                )
  ) u_port1 (
    .clk              (clk_400m         ),
    .rst              (usr_rst          ),
    .eth_ipv4_axis_sdata(p1_ipv4_data      ),
    .eth_ipv4_axis_skeep(p1_ipv4_keep      ),
    .eth_ipv4_axis_slast(p1_ipv4_last      ),
    .eth_ipv4_axis_svalid(p1_ipv4_valid     ),
    .eth_ipv4_axis_susr(a_rx_usr[1]        ),
    .eth_ipv4_axis_sready(p1_ipv4_ready     ),
    .ipv4_axis_mdata  (p1_o_data        ),
    .ipv4_axis_mkeep  (p1_o_keep        ),
    .ipv4_axis_mlast  (p1_o_last        ),
    .ipv4_axis_mvalid (p1_o_valid       ),
    .ipv4_axis_musr   (p1_o_usr         ),
    .ipv4_axis_mready (p1_o_ready       ),
    .ipv4_axis_sdata  (t1_mdata         ),
    .ipv4_axis_skeep  (t1_mkeep         ),
    .ipv4_axis_slast  (t1_mlast         ),
    .ipv4_axis_svalid (t1_mvalid        ),
    .ipv4_axis_susr   (t1_musr          ),
    .ipv4_axis_sready (t1_mready        ),
    .eth_tx_axis_mdata(p1_tx_data       ),
    .eth_tx_axis_mkeep(p1_tx_keep       ),
    .eth_tx_axis_mlast(p1_tx_last       ),
    .eth_tx_axis_mvalid(p1_tx_valid      ),
    .eth_tx_axis_musr (p1_tx_usr        ),
    .eth_tx_axis_mready(p1_tx_ready      ),
    .query_src_ip     (q1_src_ip        ),
    .query_dst_ip     (q1_dst_ip        ),
    .query_valid_pulse(q1_valid_pulse   ),
    .arp_dst_mac      (r1_dst_mac       ),
    .arp_src_mac      (r1_src_mac       ),
    .arp_miss         (r1_miss          ),
    .arp_valid        (r1_valid         ),
    .stat_tx_active_port(stat1_ipv4_port   ),
    .stat_tx_idle     (stat1_ipv4_idle   )
  );

  assign  p1_o_ready[1] = 1'b1             ;// other 兜底档收下即丢弃

  // ============================================================================
  // 网口2 : eth_top(B 片 CMAC) + arp_engine_top#2 + ipv4_top#2
  // ============================================================================
  eth_top #(
    .PORT_SEL         (1                ),
    .RX_TYPE_NUM      (2                ),
    .RX_TYPE_DICT     ({16'h0608, 16'h0008}),
    .TX_TYPE_NUM      (4                )
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
    .mac_axis_mdata   (b_rx_data        ),
    .mac_axis_mkeep   (b_rx_keep        ),
    .mac_axis_mlast   (b_rx_last        ),
    .mac_axis_mvalid  (b_rx_valid       ),
    .mac_axis_musr    (b_rx_usr         ),
    .mac_axis_mready  (b_rx_ready       ),
    .mac_axis_sdata   (b_tx_data        ),
    .mac_axis_skeep   (b_tx_keep        ),
    .mac_axis_slast   (b_tx_last        ),
    .mac_axis_svalid  (b_tx_valid       ),
    .mac_axis_susr    (b_tx_usr         ),
    .mac_axis_sready  (b_tx_ready       ),
    .stat_tx_active_port(stat2_arb_port   ),
    .stat_tx_idle     (stat2_arb_idle   )
  );

  assign  b_rx_ready[2] = 1'b1             ;// other 兜底档收下即丢弃

  arp_engine_top #(
    .AXIS_WIDTH       (512              ),
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
    .arp_axis_susr    (b_rx_usr[0]      ),
    .arp_axis_sready  (b_arp_ready      ),
    .arp_axis_mdata   (b_arp_tx_data    ),
    .arp_axis_mkeep   (b_arp_tx_keep    ),
    .arp_axis_mvalid  (b_arp_tx_valid   ),
    .arp_axis_mlast   (b_arp_tx_last    ),
    .arp_axis_musr    (b_arp_tx_usr     ),
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
    .RX_TYPE_NUM      (1                ),
    .RX_TYPE_DICT     ({8'h11}          ),
    .TX_TYPE_NUM      (1                ),
    .AXIS_USER_WIDTH  (4                )
  ) u_port2 (
    .clk              (clk_400m         ),
    .rst              (usr_rst          ),
    .eth_ipv4_axis_sdata(p2_ipv4_data      ),
    .eth_ipv4_axis_skeep(p2_ipv4_keep      ),
    .eth_ipv4_axis_slast(p2_ipv4_last      ),
    .eth_ipv4_axis_svalid(p2_ipv4_valid     ),
    .eth_ipv4_axis_susr(b_rx_usr[1]        ),
    .eth_ipv4_axis_sready(p2_ipv4_ready     ),
    .ipv4_axis_mdata  (p2_o_data        ),
    .ipv4_axis_mkeep  (p2_o_keep        ),
    .ipv4_axis_mlast  (p2_o_last        ),
    .ipv4_axis_mvalid (p2_o_valid       ),
    .ipv4_axis_musr   (p2_o_usr         ),
    .ipv4_axis_mready (p2_o_ready       ),
    .ipv4_axis_sdata  (t2_mdata         ),
    .ipv4_axis_skeep  (t2_mkeep         ),
    .ipv4_axis_slast  (t2_mlast         ),
    .ipv4_axis_svalid (t2_mvalid        ),
    .ipv4_axis_susr   (t2_musr          ),
    .ipv4_axis_sready (t2_mready        ),
    .eth_tx_axis_mdata(p2_tx_data       ),
    .eth_tx_axis_mkeep(p2_tx_keep       ),
    .eth_tx_axis_mlast(p2_tx_last       ),
    .eth_tx_axis_mvalid(p2_tx_valid      ),
    .eth_tx_axis_musr (p2_tx_usr        ),
    .eth_tx_axis_mready(p2_tx_ready      ),
    .query_src_ip     (q2_src_ip        ),
    .query_dst_ip     (q2_dst_ip        ),
    .query_valid_pulse(q2_valid_pulse   ),
    .arp_dst_mac      (r2_dst_mac       ),
    .arp_src_mac      (r2_src_mac       ),
    .arp_miss         (r2_miss          ),
    .arp_valid        (r2_valid         ),
    .stat_tx_active_port(stat2_ipv4_port   ),
    .stat_tx_idle     (stat2_ipv4_idle   )
  );

  assign  p2_o_ready[1] = 1'b1             ;// other 兜底档收下即丢弃

  // ============================================================================
  // RX 档位拆分: eth_top flat -> arp 引擎(ch0) / ipv4_top(ch1)
  // ============================================================================
  assign  a_arp_data   = a_rx_data[0*512 +: 512];
  assign  a_arp_keep   = a_rx_keep[0*64  +: 64 ];
  assign  a_arp_last   = a_rx_last[0];
  assign  a_arp_valid  = a_rx_valid[0];
  assign  a_rx_ready[0]= a_arp_ready;

  assign  p1_ipv4_data = a_rx_data[1*512 +: 512];
  assign  p1_ipv4_keep = a_rx_keep[1*64  +: 64 ];
  assign  p1_ipv4_last = a_rx_last[1];
  assign  p1_ipv4_valid= a_rx_valid[1];
  assign  a_rx_ready[1]= p1_ipv4_ready;

  assign  b_arp_data   = b_rx_data[0*512 +: 512];
  assign  b_arp_keep   = b_rx_keep[0*64  +: 64 ];
  assign  b_arp_last   = b_rx_last[0];
  assign  b_arp_valid  = b_rx_valid[0];
  assign  b_rx_ready[0]= b_arp_ready;

  assign  p2_ipv4_data = b_rx_data[1*512 +: 512];
  assign  p2_ipv4_keep = b_rx_keep[1*64  +: 64 ];
  assign  p2_ipv4_last = b_rx_last[1];
  assign  p2_ipv4_valid= b_rx_valid[1];
  assign  b_rx_ready[1]= p2_ipv4_ready;

  // ============================================================================
  // TX 档位打包: arp 引擎 -> lane0(usr=ARP_PRIORITY) / ipv4_top -> lane2(usr=8)
  // ============================================================================
  assign  a_tx_data[0*512 +: 512] = a_arp_tx_data;
  assign  a_tx_keep[0*64  +: 64 ] = a_arp_tx_keep;
  assign  a_tx_last[0]            = a_arp_tx_last;
  assign  a_tx_valid[0]           = a_arp_tx_valid;
  assign  a_tx_usr[0*4 +: 4]      = a_arp_tx_usr;
  assign  a_arp_tx_ready          = a_tx_ready[0];

  assign  a_tx_data[1*512 +: 512] = 512'd0;
  assign  a_tx_keep[1*64  +: 64 ] = 64'd0;
  assign  a_tx_last[1]            = 1'b0;
  assign  a_tx_valid[1]           = 1'b0;
  assign  a_tx_usr[1*4 +: 4]      = 4'd0;

  assign  a_tx_data[2*512 +: 512] = p1_tx_data;
  assign  a_tx_keep[2*64  +: 64 ] = p1_tx_keep;
  assign  a_tx_last[2]            = p1_tx_last;
  assign  a_tx_valid[2]           = p1_tx_valid;
  assign  a_tx_usr[2*4 +: 4]      = p1_tx_usr;
  assign  p1_tx_ready             = a_tx_ready[2];

  assign  a_tx_data[3*512 +: 512] = 512'd0;
  assign  a_tx_keep[3*64  +: 64 ] = 64'd0;
  assign  a_tx_last[3]            = 1'b0;
  assign  a_tx_valid[3]           = 1'b0;
  assign  a_tx_usr[3*4 +: 4]      = 4'd0;

  assign  b_tx_data[0*512 +: 512] = b_arp_tx_data;
  assign  b_tx_keep[0*64  +: 64 ] = b_arp_tx_keep;
  assign  b_tx_last[0]            = b_arp_tx_last;
  assign  b_tx_valid[0]           = b_arp_tx_valid;
  assign  b_tx_usr[0*4 +: 4]      = b_arp_tx_usr;
  assign  b_arp_tx_ready          = b_tx_ready[0];

  assign  b_tx_data[1*512 +: 512] = 512'd0;
  assign  b_tx_keep[1*64  +: 64 ] = 64'd0;
  assign  b_tx_last[1]            = 1'b0;
  assign  b_tx_valid[1]           = 1'b0;
  assign  b_tx_usr[1*4 +: 4]      = 4'd0;

  assign  b_tx_data[2*512 +: 512] = p2_tx_data;
  assign  b_tx_keep[2*64  +: 64 ] = p2_tx_keep;
  assign  b_tx_last[2]            = p2_tx_last;
  assign  b_tx_valid[2]           = p2_tx_valid;
  assign  b_tx_usr[2*4 +: 4]      = p2_tx_usr;
  assign  p2_tx_ready             = b_tx_ready[2];

  assign  b_tx_data[3*512 +: 512] = 512'd0;
  assign  b_tx_keep[3*64  +: 64 ] = 64'd0;
  assign  b_tx_last[3]            = 1'b0;
  assign  b_tx_valid[3]           = 1'b0;
  assign  b_tx_usr[3*4 +: 4]      = 4'd0;

  // ============================================================================
  // 打流机(网口1) / 校验机(网口2)
  // ============================================================================
  ipv4_100g_tester #(
    .AXIS_WIDTH       (512              ),
    .AXIS_USER_WIDTH  (4                ),
    .PKT_LEN_BEATS    (PKT_LEN_BEATS    ),
    .ONE_SEC_CYCLES   (ONE_SEC_CYCLES   ),
    .AXIS_USER_VAL    (4'd8             ),
    .DST_IP_LE        (CFG_P2_IP_LE[31:0]),
    .SRC_IP_LE        (CFG_P1_IP_LE[31:0])
  ) u_tester1 (
    .clk              (clk_400m         ),
    .rst              (usr_rst          ),
    .axis_mdata       (t1_mdata         ),
    .axis_mkeep       (t1_mkeep         ),
    .axis_mvalid      (t1_mvalid        ),
    .axis_mlast       (t1_mlast         ),
    .axis_musr        (t1_musr          ),
    .axis_mready      (t1_mready        ),
    .axis_sdata       (p1_o_data[0*512 +: 512]),
    .axis_skeep       (p1_o_keep[0*64  +: 64 ]),
    .axis_svalid      (p1_o_valid[0]    ),
    .axis_slast       (p1_o_last[0]     ),
    .axis_susr        (4'd0             ),
    .axis_sready      (p1_o_ready[0]    ),
    .test_enable      (test_enable      )
  );

  ipv4_100g_tester #(
    .AXIS_WIDTH       (512              ),
    .AXIS_USER_WIDTH  (4                ),
    .PKT_LEN_BEATS    (PKT_LEN_BEATS    ),
    .ONE_SEC_CYCLES   (ONE_SEC_CYCLES   ),
    .AXIS_USER_VAL    (4'd8             ),
    .DST_IP_LE        (CFG_P2_IP_LE[31:0]),
    .SRC_IP_LE        (CFG_P1_IP_LE[31:0])
  ) u_tester2 (
    .clk              (clk_400m         ),
    .rst              (usr_rst          ),
    .axis_mdata       (t2_mdata         ),
    .axis_mkeep       (t2_mkeep         ),
    .axis_mvalid      (t2_mvalid        ),
    .axis_mlast       (t2_mlast         ),
    .axis_musr        (t2_musr          ),
    .axis_mready      (t2_mready        ),
    .axis_sdata       (p2_o_data[0*512 +: 512]),
    .axis_skeep       (p2_o_keep[0*64  +: 64 ]),
    .axis_svalid      (p2_o_valid[0]    ),
    .axis_slast       (p2_o_last[0]     ),
    .axis_susr        (4'd0             ),
    .axis_sready      (p2_o_ready[0]    ),
    .test_enable      (1'b0             )
  );

  // ============================================================================
  // VIO : 启动/停止打流
  // ============================================================================
  vio_enable u_test_vio_enable (
    .clk              (clk_400m         ),
    .probe_out0       (test_enable      )
  );

(* mark_debug = "true" *) wire b_ipv4_rx_hs_dbg      = b_rx_valid[1] && b_rx_ready[1];
(* mark_debug = "true" *) wire b_arp_rx_hs_dbg       = b_rx_valid[0] && b_rx_ready[0];

endmodule
