`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : eth_top.v
// Module Name : eth_top
// Author      : LiXintao
// Date        : 2026-09-24
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 一个 100G 网口的完整以太网层封装(L1 端口 + L2 成帧)
//
//   RX: cmac_x_if -> SLR 寄存slice -> RX CDC FIFO(usrclk->400M) -> skid
//        -> eth_type_demux -> 三类流输出 arp / other / ipv4
//   TX: 三类流入口 arp / other / ipv4
//        -> eth_tx_mux(优先级 other > arp > ipv4)
//        -> eth_frame_pad60(单实例, 统一补齐最小帧长)
//        -> TX CDC FIFO(400M->usrclk) -> SLR 寄存slice -> cmac_x_if
// ============================================================================

module eth_top #(
  parameter  PORT_SEL= 0 ,// 0 = cmac_a_if, 1 = cmac_b_if
  parameter  AXIS_WIDTH= 512,
  parameter  AXIS_USER_WIDTH= 1 ,
  parameter  TX_PKT_BUF_DEPTH= 512,// 吸收 CMAC 周期性反压, 不可随意缩小
  parameter  CDC_FIFO_DEPTH= 512
)(
  // ============================================================================
  // 板级时钟 / 复位
  // ============================================================================
  input  wire                                          init_clk        ,
  input  wire                                          sys_reset       ,
  output wire                                          gt_txusrclk     ,
  output wire                                          gt_rxusrclk     ,
  output wire                                          usr_tx_reset    ,
  output wire                                          usr_rx_reset    ,

  // ============================================================================
  // GT / QSFP
  // ============================================================================
  output wire          [                   3: 0]       gt_txp_out      ,
  output wire          [                   3: 0]       gt_txn_out      ,
  input  wire          [                   3: 0]       gt_rxp_in       ,
  input  wire          [                   3: 0]       gt_rxn_in       ,
  input  wire                                          gt_ref_clk_p    ,
  input  wire                                          gt_ref_clk_n    ,
  output wire                                          qsfp_rstn_port  ,
  output wire                                          qsfp_lp_mode_port,
  output wire                                          qsfp_seln_port  ,
  input  wire                                          qsfp_prsn_port  ,
  output wire                                          qsfp_led_port   ,

  // ============================================================================
  // 400M 用户域
  // ============================================================================
  input  wire                                          clk             ,// 400M
  input  wire                                          rst             ,// 400M 域逻辑复位
  input  wire                                          fifo_tx_rst     ,// 400M 域 TX CDC FIFO 复位

  // ============================================================================
  // RX 三类流输出(400M 域)
  // ============================================================================
  output wire          [        AXIS_WIDTH-1: 0]       arp_axis_mdata  ,
  output wire          [      AXIS_WIDTH/8-1: 0]       arp_axis_mkeep  ,
  output wire                                          arp_axis_mlast  ,
  output wire                                          arp_axis_mvalid ,
  input  wire                                          arp_axis_mready ,

  output wire          [        AXIS_WIDTH-1: 0]       other_axis_mdata,
  output wire          [      AXIS_WIDTH/8-1: 0]       other_axis_mkeep,
  output wire                                          other_axis_mlast,
  output wire                                          other_axis_mvalid,
  input  wire                                          other_axis_mready,

  output wire          [        AXIS_WIDTH-1: 0]       ipv4_axis_mdata ,
  output wire          [      AXIS_WIDTH/8-1: 0]       ipv4_axis_mkeep ,
  output wire                                          ipv4_axis_mlast ,
  output wire                                          ipv4_axis_mvalid,
  input  wire                                          ipv4_axis_mready,

  // ============================================================================
  // TX 三类流入口(400M 域)
  // ============================================================================
  input  wire          [        AXIS_WIDTH-1: 0]       arp_axis_sdata  ,
  input  wire          [      AXIS_WIDTH/8-1: 0]       arp_axis_skeep  ,
  input  wire                                          arp_axis_slast  ,
  input  wire                                          arp_axis_svalid ,
  output wire                                          arp_axis_sready ,

  input  wire          [        AXIS_WIDTH-1: 0]       other_axis_sdata,
  input  wire          [      AXIS_WIDTH/8-1: 0]       other_axis_skeep,
  input  wire                                          other_axis_slast,
  input  wire                                          other_axis_svalid,
  output wire                                          other_axis_sready,

  input  wire          [        AXIS_WIDTH-1: 0]       ipv4_axis_sdata ,
  input  wire          [      AXIS_WIDTH/8-1: 0]       ipv4_axis_skeep ,
  input  wire                                          ipv4_axis_slast ,
  input  wire                                          ipv4_axis_svalid,
  output wire                                          ipv4_axis_sready,

  // ============================================================================
  // 状态
  // ============================================================================
  output wire          [                   1: 0]       stat_tx_active_port,// 0=other 1=arp 2=ipv4
  output wire                                          stat_tx_idle     
);

  // ============================================================================
  // 内部连线 : CMAC <-> SLR slice
  // ============================================================================
  wire                 [        AXIS_WIDTH-1: 0]       cr_data            ;// cmac 收
  wire                 [      AXIS_WIDTH/8-1: 0]       cr_keep            ;
  wire                                                 cr_last            ;
  wire                                                 cr_valid           ;
  wire                 [   AXIS_USER_WIDTH-1: 0]       cr_user            ;

  wire                 [        AXIS_WIDTH-1: 0]       ct_data            ;// cmac 发
  wire                 [      AXIS_WIDTH/8-1: 0]       ct_keep            ;
  wire                                                 ct_last            ;
  wire                                                 ct_valid           ;
  wire                 [   AXIS_USER_WIDTH-1: 0]       ct_user            ;
  wire                                                 ct_ready           ;

  // ============================================================================
  // 内部连线 : SLR slice <-> CDC FIFO(usrclk 域)
  // ============================================================================
  wire                 [        AXIS_WIDTH-1: 0]       sk_rx_s_data     ,sk_tx_m_data ;
  wire                 [      AXIS_WIDTH/8-1: 0]       sk_rx_s_keep     ,sk_tx_m_keep ;
  wire                 [   AXIS_USER_WIDTH-1: 0]       sk_rx_s_user     ,sk_tx_m_user ;
  wire                                                 sk_rx_s_last     ,sk_tx_m_last ;
  wire                                                 sk_rx_s_valid    ,sk_tx_m_valid ;
  wire                                                 sk_rx_s_ready    ,sk_tx_m_ready ;

  // ============================================================================
  // 内部连线 : RX CDC FIFO <-> skid <-> demux(400M 域)
  // ============================================================================
  wire                 [        AXIS_WIDTH-1: 0]       sk_dem_s_data      ;
  wire                 [      AXIS_WIDTH/8-1: 0]       sk_dem_s_keep      ;
  wire                                                 sk_dem_s_last      ;
  wire                                                 sk_dem_s_valid     ;
  wire                                                 sk_dem_s_ready     ;

  wire                 [        AXIS_WIDTH-1: 0]       rx_data            ;
  wire                 [      AXIS_WIDTH/8-1: 0]       rx_keep            ;
  wire                                                 rx_last            ;
  wire                                                 rx_valid           ;
  wire                                                 rx_ready           ;

  // ============================================================================
  // 内部连线 : TX mux -> pad -> tx_pkt_buf -> TX CDC FIFO(400M 域)
  // ============================================================================
  wire                 [        AXIS_WIDTH-1: 0]       mux_data           ;
  wire                 [      AXIS_WIDTH/8-1: 0]       mux_keep           ;
  wire                                                 mux_last           ;
  wire                                                 mux_valid          ;
  wire                                                 mux_ready          ;
  wire                 [   AXIS_USER_WIDTH-1: 0]       mux_user           ;

  wire                 [        AXIS_WIDTH-1: 0]       pad_data           ;
  wire                 [      AXIS_WIDTH/8-1: 0]       pad_keep           ;
  wire                                                 pad_last           ;
  wire                                                 pad_valid          ;
  wire                                                 pad_ready          ;


  // ============================================================================
  // CMAC : 按 PORT_SEL 选择 A / B 两片 IP 的封装
  // ============================================================================
  generate
    if (PORT_SEL == 0) begin : gen_cmac_a
      cmac_a_if u_cmac_if (
    .init_clk         (init_clk         ),
    .sys_reset        (sys_reset        ),
    .gt_txp_out       (gt_txp_out       ),
    .gt_txn_out       (gt_txn_out       ),
    .gt_rxp_in        (gt_rxp_in        ),
    .gt_rxn_in        (gt_rxn_in        ),
    .gt_ref_clk_p     (gt_ref_clk_p     ),
    .gt_ref_clk_n     (gt_ref_clk_n     ),
    .gt_txusrclk      (gt_txusrclk      ),
    .gt_rxusrclk      (gt_rxusrclk      ),
    .axis_mvalid      (cr_valid         ),
    .axis_mdata       (cr_data          ),
    .axis_mlast       (cr_last          ),
    .axis_mkeep       (cr_keep          ),
    .axis_musr        (cr_user          ),
    .axis_svalid      (ct_valid         ),
    .axis_sdata       (ct_data          ),
    .axis_slast       (ct_last          ),
    .axis_skeep       (ct_keep          ),
    .axis_susr        (ct_user          ),
    .axis_sready      (ct_ready         ),
    .usr_tx_reset     (usr_tx_reset     ),
    .usr_rx_reset     (usr_rx_reset     ),
    .qsfp_rstn_port   (qsfp_rstn_port   ),
    .qsfp_lp_mode_port(qsfp_lp_mode_port),
    .qsfp_seln_port   (qsfp_seln_port   ),
    .qsfp_prsn_port   (qsfp_prsn_port   ),
    .qsfp_led_port    (qsfp_led_port    ) 
      );
    end else begin : gen_cmac_b
      cmac_b_if u_cmac_if (
    .init_clk         (init_clk         ),
    .sys_reset        (sys_reset        ),
    .gt_txp_out       (gt_txp_out       ),
    .gt_txn_out       (gt_txn_out       ),
    .gt_rxp_in        (gt_rxp_in        ),
    .gt_rxn_in        (gt_rxn_in        ),
    .gt_ref_clk_p     (gt_ref_clk_p     ),
    .gt_ref_clk_n     (gt_ref_clk_n     ),
    .gt_txusrclk      (gt_txusrclk      ),
    .gt_rxusrclk      (gt_rxusrclk      ),
    .axis_mvalid      (cr_valid         ),
    .axis_mdata       (cr_data          ),
    .axis_mlast       (cr_last          ),
    .axis_mkeep       (cr_keep          ),
    .axis_musr        (cr_user          ),
    .axis_svalid      (ct_valid         ),
    .axis_sdata       (ct_data          ),
    .axis_slast       (ct_last          ),
    .axis_skeep       (ct_keep          ),
    .axis_susr        (ct_user          ),
    .axis_sready      (ct_ready         ),
    .usr_tx_reset     (usr_tx_reset     ),
    .usr_rx_reset     (usr_rx_reset     ),
    .qsfp_rstn_port   (qsfp_rstn_port   ),
    .qsfp_lp_mode_port(qsfp_lp_mode_port),
    .qsfp_seln_port   (qsfp_seln_port   ),
    .qsfp_prsn_port   (qsfp_prsn_port   ),
    .qsfp_led_port    (qsfp_led_port    ) 
      );
    end
  endgenerate

  // ============================================================================
  // RX : CMAC 收 -> SLR 寄存slice(usrclk) -> RX CDC FIFO -> 400M
  // ============================================================================
  axis_slr_crossing u_slr_x_rx (
    .aclk             (gt_rxusrclk      ),
    .aresetn          (~usr_rx_reset    ),
    .s_axis_tvalid    (cr_valid         ),
    .s_axis_tready    (                 ),
    .s_axis_tdata     (cr_data          ),
    .s_axis_tkeep     (cr_keep          ),
    .s_axis_tlast     (cr_last          ),
    .s_axis_tuser     (cr_user          ),
    .m_axis_tvalid    (sk_rx_s_valid    ),
    .m_axis_tready    (sk_rx_s_ready    ),
    .m_axis_tdata     (sk_rx_s_data     ),
    .m_axis_tkeep     (sk_rx_s_keep     ),
    .m_axis_tlast     (sk_rx_s_last     ),
    .m_axis_tuser     (sk_rx_s_user     ) 
  );

  axis_fifo_async #(
    .FIFO_DEPTH       (CDC_FIFO_DEPTH   ),
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .AXIS_ID_WIDTH    (1                ),
    .AXIS_DEST_WIDTH  (1                ),
    .FIFO_MEMORY_TYPE ("auto"           ),
    .PACKET_FIFO      (0                ),
    .BRAM_DO_REG      (2                )
  ) u_fifo_rx (
    .srst             (usr_rx_reset     ),
    .sclk             (gt_rxusrclk      ),
    .mclk             (clk              ),
    .axis_sdata       (sk_rx_s_data     ),
    .axis_skeep       (sk_rx_s_keep     ),
    .axis_svalid      (sk_rx_s_valid    ),
    .axis_slast       (sk_rx_s_last     ),
    .axis_sready      (sk_rx_s_ready    ),
    .axis_suser       (sk_rx_s_user     ),
    .axis_sstrb       ('d0              ),
    .axis_sid         ('d0              ),
    .axis_sdest       ('d0              ),
    .axis_mdata       (sk_dem_s_data    ),
    .axis_mkeep       (sk_dem_s_keep    ),
    .axis_mvalid      (sk_dem_s_valid   ),
    .axis_mlast       (sk_dem_s_last    ),
    .axis_mready      (sk_dem_s_ready   ),
    .axis_muser       (                 ),
    .axis_mstrb       (                 ),
    .axis_mid         (                 ),
    .axis_mdest       (                 ),
    .prog_almost_empty(                 ),
    .prog_almost_full (                 ),
    .almost_empty     (                 ),
    .almost_full      (                 ),
    .wr_almost_remain_count(                 ),
    .rd_almost_remain_count(                 ) 
  );

  axis_skid_buffer #(
    .AXIS_DATA_WIDTH  (AXIS_WIDTH       ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .AXIS_ID_WIDTH    (1                ),
    .AXIS_DEST_WIDTH  (1                ) 
  ) u_skid_rx (
    .clk              (clk              ),
    .rst              (rst              ),
    .axis_sdata       (sk_dem_s_data    ),
    .axis_skeep       (sk_dem_s_keep    ),
    .axis_slast       (sk_dem_s_last    ),
    .axis_svalid      (sk_dem_s_valid   ),
    .axis_sready      (sk_dem_s_ready   ),
    .axis_suser       ('d0              ),
    .axis_sid         ('d0              ),
    .axis_sdest       ('d0              ),
    .axis_sstrb       ('d0              ),
    .axis_mdata       (rx_data          ),
    .axis_mkeep       (rx_keep          ),
    .axis_mlast       (rx_last          ),
    .axis_mvalid      (rx_valid         ),
    .axis_mready      (rx_ready         ),
    .axis_muser       (                 ),
    .axis_mid         (                 ),
    .axis_mdest       (                 ),
    .axis_mstrb       (                 ) 
  );

  eth_type_demux u_demux (
    .clk              (clk              ),
    .rst              (rst              ),
    .eth_axis_sdata   (rx_data          ),
    .eth_axis_skeep   (rx_keep          ),
    .eth_axis_slast   (rx_last          ),
    .eth_axis_svalid  (rx_valid         ),
    .eth_axis_sready  (rx_ready         ),
    .eth_ipv4_axis_mdata(ipv4_axis_mdata  ),
    .eth_ipv4_axis_mkeep(ipv4_axis_mkeep  ),
    .eth_ipv4_axis_mlast(ipv4_axis_mlast  ),
    .eth_ipv4_axis_mvalid(ipv4_axis_mvalid ),
    .eth_ipv4_axis_mready(ipv4_axis_mready ),
    .eth_arp_axis_mdata(arp_axis_mdata   ),
    .eth_arp_axis_mkeep(arp_axis_mkeep   ),
    .eth_arp_axis_mlast(arp_axis_mlast   ),
    .eth_arp_axis_mvalid(arp_axis_mvalid  ),
    .eth_arp_axis_mready(arp_axis_mready  ),
    .eth_other_axis_mdata(other_axis_mdata ),
    .eth_other_axis_mkeep(other_axis_mkeep ),
    .eth_other_axis_mlast(other_axis_mlast ),
    .eth_other_axis_mvalid(other_axis_mvalid),
    .eth_other_axis_mready(other_axis_mready) 
  );

  // ============================================================================
  // TX : 三类入口 -> mux(400M) -> pad -> tx_pkt_buf -> TX CDC FIFO -> usrclk
  // ============================================================================
  eth_tx_mux #(
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .AXIS_ID_WIDTH    (1                ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ) 
  ) u_tx_mux (
    .clk              (clk              ),
    .rst              (rst              ),
    .other_axis_sdata (other_axis_sdata ),
    .other_axis_skeep (other_axis_skeep ),
    .other_axis_slast (other_axis_slast ),
    .other_axis_svalid(other_axis_svalid),
    .other_axis_sready(other_axis_sready),
    .arp_axis_sdata   (arp_axis_sdata   ),
    .arp_axis_skeep   (arp_axis_skeep   ),
    .arp_axis_slast   (arp_axis_slast   ),
    .arp_axis_svalid  (arp_axis_svalid  ),
    .arp_axis_sready  (arp_axis_sready  ),
    .ipv4_axis_sdata  (ipv4_axis_sdata  ),
    .ipv4_axis_skeep  (ipv4_axis_skeep  ),
    .ipv4_axis_slast  (ipv4_axis_slast  ),
    .ipv4_axis_svalid (ipv4_axis_svalid ),
    .ipv4_axis_sready (ipv4_axis_sready ),
    .eth_axis_mdata   (mux_data         ),
    .eth_axis_mkeep   (mux_keep         ),
    .eth_axis_mlast   (mux_last         ),
    .eth_axis_mvalid  (mux_valid        ),
    .eth_axis_muser   (mux_user         ),
    .eth_axis_mready  (mux_ready        ),
    .stat_active_port (stat_tx_active_port),
    .stat_idle        (stat_tx_idle     ) 
  );

  eth_frame_pad60 #(
    .MIN_FRAME_BYTES  (60               ) 
  ) u_frame_pad (
    .clk              (clk              ),
    .rst              (rst              ),
    .eth_axis_sdata   (mux_data         ),
    .eth_axis_skeep   (mux_keep         ),
    .eth_axis_slast   (mux_last         ),
    .eth_axis_svalid  (mux_valid        ),
    .eth_axis_sready  (mux_ready        ),
    .eth_axis_mdata   (pad_data         ),
    .eth_axis_mkeep   (pad_keep         ),
    .eth_axis_mlast   (pad_last         ),
    .eth_axis_mvalid  (pad_valid        ),
    .eth_axis_mready  (pad_ready        ) 
  );

  axis_fifo_async #(
    .FIFO_DEPTH       (CDC_FIFO_DEPTH   ),
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .AXIS_ID_WIDTH    (1                ),
    .AXIS_DEST_WIDTH  (1                ),
    .FIFO_MEMORY_TYPE ("auto"           ),
    .PACKET_FIFO      (0                ),
    .BRAM_DO_REG      (2                )
  ) u_fifo_tx (
    .srst             (fifo_tx_rst      ),
    .sclk             (clk              ),
    .mclk             (gt_txusrclk      ),
    .axis_sdata       (pad_data         ),
    .axis_skeep       (pad_keep         ),
    .axis_svalid      (pad_valid        ),
    .axis_slast       (pad_last         ),
    .axis_sready      (pad_ready        ),
    .axis_suser       (1'b0             ),
    .axis_sstrb       ('d0              ),
    .axis_sid         ('d0              ),
    .axis_sdest       ('d0              ),
    .axis_mdata       (sk_tx_m_data     ),
    .axis_mkeep       (sk_tx_m_keep     ),
    .axis_mvalid      (sk_tx_m_valid    ),
    .axis_mlast       (sk_tx_m_last     ),
    .axis_mready      (sk_tx_m_ready    ),
    .axis_muser       (sk_tx_m_user     ),
    .axis_mstrb       (                 ),
    .axis_mid         (                 ),
    .axis_mdest       (                 ),
    .prog_almost_empty(                 ),
    .prog_almost_full (                 ),
    .almost_empty     (                 ),
    .almost_full      (                 ),
    .wr_almost_remain_count(                 ),
    .rd_almost_remain_count(                 ) 
  );

  axis_slr_crossing u_slr_x_tx (
    .aclk             (gt_txusrclk      ),
    .aresetn          (~usr_tx_reset    ),
    .s_axis_tvalid    (sk_tx_m_valid    ),
    .s_axis_tready    (sk_tx_m_ready    ),
    .s_axis_tdata     (sk_tx_m_data     ),
    .s_axis_tkeep     (sk_tx_m_keep     ),
    .s_axis_tlast     (sk_tx_m_last     ),
    .s_axis_tuser     (sk_tx_m_user     ),
    .m_axis_tvalid    (ct_valid         ),
    .m_axis_tready    (ct_ready         ),
    .m_axis_tdata     (ct_data          ),
    .m_axis_tkeep     (ct_keep          ),
    .m_axis_tlast     (ct_last          ),
    .m_axis_tuser     (ct_user          ) 
  );

endmodule
`resetall
