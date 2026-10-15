`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : eth_top.v
// Module Name : eth_top
// Author      : LiXintao
// Date        : 2026-10-11
// Version     : v4.0
// ----------------------------------------------------------------------------
// Description : 一个 100G 网口的完整以太网层封装(L1 端口 + L2 成帧)
//
//   RX: cmac_x_if -> SLR 寄存slice -> RX CDC FIFO(usrclk->用户时钟域) -> skid
//        -> eth_type_demux(RX_TYPE_DICT 字典匹配) -> RX flat 输出(RX_TYPE_NUM 路, other 由 demux 内部自动补出)
//   TX:  -> eth_tx_mux 数选器
//        -> eth_frame_pad60(单实例, 统一补齐最小帧长)
//        -> TX CDC FIFO(用户时钟域->usrclk) -> SLR 寄存slice -> cmac_x_if
// ============================================================================

module eth_top #(
  parameter  PORT_SEL= 0 ,// 0 = cmac_a_if, 1 = cmac_b_if
  parameter  RX_TYPE_NUM= 4 ,
  parameter  [    RX_TYPE_NUM*16-1:0]        RX_TYPE_DICT= {16'hB588, 16'hDD86, 16'h0608, 16'h0008}, // 88B5/ipv6/arp/ipv4
  parameter  TX_TYPE_NUM= 4 ,
  parameter  TX_IDX_W= (TX_TYPE_NUM <= 1) ? 1 : $clog2(TX_TYPE_NUM),
  parameter  AXIS_TX_USER_WIDTH= 4 ,
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
  output wire          [                   3:0]        gt_txp_out      ,
  output wire          [                   3:0]        gt_txn_out      ,
  input  wire          [                   3:0]        gt_rxp_in       ,
  input  wire          [                   3:0]        gt_rxn_in       ,
  input  wire                                          gt_ref_clk_p    ,
  input  wire                                          gt_ref_clk_n    ,
  output wire                                          qsfp_rstn_port  ,
  output wire                                          qsfp_lp_mode_port,
  output wire                                          qsfp_seln_port  ,
  input  wire                                          qsfp_prsn_port  ,
  output wire                                          qsfp_led_port   ,

  // ============================================================================
  // 用户时钟域 用户域
  // ============================================================================
  input  wire                                          clk             ,// 用户时钟域
  input  wire                                          rst             ,// 用户时钟域 域逻辑复位
  input  wire                                          fifo_tx_rst     ,// 用户时钟域 域 TX CDC FIFO 复位

  // ============================================================================
  // RX flat 流输出 : RX_TYPE_NUM 路, 第 k 档 = [k*512 +: 512]
  //   RX_TYPE_NUM 路全部为用户侧档; RX_TYPE_DICT 未命中的帧由 demux 内部 other 兜底档吸收
  // ============================================================================
  output wire          [512*(RX_TYPE_NUM+1)-1:0]       mac_axis_mdata  ,
  output wire          [64*(RX_TYPE_NUM+1)-1:0]        mac_axis_mkeep  ,
  output wire          [         RX_TYPE_NUM:0]        mac_axis_mlast  ,
  output wire          [         RX_TYPE_NUM:0]        mac_axis_mvalid ,
  output wire          [         RX_TYPE_NUM:0]        mac_axis_musr   ,
  input  wire          [         RX_TYPE_NUM:0]        mac_axis_mready ,

  // ============================================================================
  // TX 
  // ============================================================================
  input  wire          [   512*TX_TYPE_NUM-1:0]        mac_axis_sdata  ,
  input  wire          [    64*TX_TYPE_NUM-1:0]        mac_axis_skeep  ,
  input  wire          [       TX_TYPE_NUM-1:0]        mac_axis_slast  ,
  input  wire          [       TX_TYPE_NUM-1:0]        mac_axis_svalid ,
  input  wire          [AXIS_TX_USER_WIDTH*TX_TYPE_NUM-1:0]mac_axis_susr   ,
  output wire          [       TX_TYPE_NUM-1:0]        mac_axis_sready ,

  output wire          [          TX_IDX_W-1:0]        stat_tx_active_port,
  output wire                                          stat_tx_idle     
);

  // ============================================================================
  // 内部连线 : CMAC <-> SLR slice
  // ============================================================================
  wire                 [                 511:0]        cr_data          ;// cmac 收
  wire                 [                  63:0]        cr_keep          ;
  wire                                                 cr_last          ;
  wire                                                 cr_valid         ;
  wire                                                 cr_usr           ;

  wire                 [                 511:0]        ct_data          ;// cmac 发
  wire                 [                  63:0]        ct_keep          ;
  wire                                                 ct_last          ;
  wire                                                 ct_valid         ;
  wire                                                 ct_usr           ;
  wire                                                 ct_ready         ;

  // ============================================================================
  // 内部连线 : SLR slice <-> CDC FIFO(usrclk 域)
  // ============================================================================
  wire                 [                 511:0]        sk_rx_s_data     ,sk_tx_m_data;
  wire                 [                  63:0]        sk_rx_s_keep     ,sk_tx_m_keep;
  wire                                                 sk_rx_s_usr      ,sk_tx_m_usr;
  wire                                                 sk_rx_s_last     ,sk_tx_m_last;
  wire                                                 sk_rx_s_valid    ,sk_tx_m_valid;
  wire                                                 sk_rx_s_ready    ,sk_tx_m_ready;

  // ============================================================================
  // 内部连线 : RX CDC FIFO <-> skid <-> demux
  // ============================================================================
  wire                 [                 511:0]        sk_dem_s_data    ;
  wire                 [                  63:0]        sk_dem_s_keep    ;
  wire                                                 sk_dem_s_last    ;
  wire                                                 sk_dem_s_valid   ;
  wire                                                 sk_dem_s_usr     ;
  wire                                                 sk_dem_s_ready   ;

  wire                 [                 511:0]        rx_data          ;
  wire                 [                  63:0]        rx_keep          ;
  wire                                                 rx_last          ;
  wire                                                 rx_valid         ;
  wire                                                 rx_usr           ;
  wire                                                 rx_ready         ;

  // ============================================================================
  // 内部连线 : TX 单路 -> pad -> tx_pkt_buf -> TX CDC FIFO
  // ============================================================================
  wire                 [                 511:0]        pad_data         ;
  wire                 [                  63:0]        pad_keep         ;
  wire                                                 pad_last         ;
  wire                                                 pad_valid        ;
  wire                                                 pad_ready        ;

  wire                 [                 511:0]        mux_mdata        ;
  wire                 [                  63:0]        mux_mkeep        ;
  wire                                                 mux_mlast        ;
  wire                                                 mux_mvalid       ;
  wire                                                 mux_mready       ;

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
    .axis_musr        (cr_usr           ),
    .axis_svalid      (ct_valid         ),
    .axis_sdata       (ct_data          ),
    .axis_slast       (ct_last          ),
    .axis_skeep       (ct_keep          ),
    .axis_susr        (ct_usr           ),
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
    .axis_musr        (cr_usr           ),
    .axis_svalid      (ct_valid         ),
    .axis_sdata       (ct_data          ),
    .axis_slast       (ct_last          ),
    .axis_skeep       (ct_keep          ),
    .axis_susr        (ct_usr           ),
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
  // RX : CMAC 收 -> SLR 寄存slice(usrclk) -> RX CDC FIFO -> 用户时钟域
  // ============================================================================
  axis_slr_crossing u_slr_x_rx (
    .aclk             (gt_rxusrclk      ),
    .aresetn          (~usr_rx_reset    ),
    .s_axis_tvalid    (cr_valid         ),
    .s_axis_tready    (                 ),
    .s_axis_tdata     (cr_data          ),
    .s_axis_tkeep     (cr_keep          ),
    .s_axis_tlast     (cr_last          ),
    .s_axis_tuser     (cr_usr           ),
    .m_axis_tvalid    (sk_rx_s_valid    ),
    .m_axis_tready    (sk_rx_s_ready    ),
    .m_axis_tdata     (sk_rx_s_data     ),
    .m_axis_tkeep     (sk_rx_s_keep     ),
    .m_axis_tlast     (sk_rx_s_last     ),
    .m_axis_tuser     (sk_rx_s_usr      ) 
  );

  axis_fifo_async #(
    .FIFO_DEPTH       (CDC_FIFO_DEPTH   ),
    .AXIS_WIDTH       (512              ),
    .AXIS_USER_WIDTH  (1                ),
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
    .axis_susr        (sk_rx_s_usr      ),
    .axis_sstrb       ('d0              ),
    .axis_sid         ('d0              ),
    .axis_sdest       ('d0              ),
    .axis_mdata       (sk_dem_s_data    ),
    .axis_mkeep       (sk_dem_s_keep    ),
    .axis_mvalid      (sk_dem_s_valid   ),
    .axis_mlast       (sk_dem_s_last    ),
    .axis_mready      (sk_dem_s_ready   ),
    .axis_musr        (sk_dem_s_usr     ),
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
    .AXIS_DATA_WIDTH  (512              ),
    .AXIS_USER_WIDTH  (1                ),
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
    .axis_susr        (sk_dem_s_usr     ),
    .axis_sid         ('d0              ),
    .axis_sdest       ('d0              ),
    .axis_sstrb       ('d0              ),
    .axis_mdata       (rx_data          ),
    .axis_mkeep       (rx_keep          ),
    .axis_mlast       (rx_last          ),
    .axis_mvalid      (rx_valid         ),
    .axis_mready      (rx_ready         ),
    .axis_musr        (rx_usr           ),
    .axis_mid         (                 ),
    .axis_mdest       (                 ),
    .axis_mstrb       (                 ) 
  );

  // ============================================================================
  // RX demux : TYPE_DICT 字典匹配 -> RX flat(参数由上层配置)
  // ============================================================================
  eth_type_demux #(
    .TYPE_NUM         (RX_TYPE_NUM      ),
    .TYPE_DICT        (RX_TYPE_DICT     ) 
  ) u_demux (
    .clk              (clk              ),
    .rst              (rst              ),
    .eth_axis_sdata   (rx_data          ),
    .eth_axis_skeep   (rx_keep          ),
    .eth_axis_slast   (rx_last          ),
    .eth_axis_svalid  (rx_valid         ),
    .eth_axis_susr    (rx_usr           ),
    .eth_axis_sready  (rx_ready         ),
    .eth_axis_mdata   (mac_axis_mdata   ),
    .eth_axis_mkeep   (mac_axis_mkeep   ),
    .eth_axis_mlast   (mac_axis_mlast   ),
    .eth_axis_mvalid  (mac_axis_mvalid  ),
    .eth_axis_musr    (mac_axis_musr    ),
    .eth_axis_mready  (mac_axis_mready  ) 
  );

  // ============================================================================
  // TX : 单路入口 -> pad -> tx_pkt_buf -> TX CDC FIFO -> usrclk
  // ============================================================================
  eth_tx_mux#(
    .TYPE_NUM         (TX_TYPE_NUM      ),
    .AXIS_USER_WIDTH  (AXIS_TX_USER_WIDTH) 
  )
  u_eth_tx_mux(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    // ---- 入口 ----
    .eth_axis_sdata   (mac_axis_sdata   ),// (input)
    .eth_axis_skeep   (mac_axis_skeep   ),// (input)
    .eth_axis_slast   (mac_axis_slast   ),// (input)
    .eth_axis_svalid  (mac_axis_svalid  ),// (input)
    .eth_axis_susr    (mac_axis_susr    ),// (input)
    .eth_axis_sready  (mac_axis_sready  ),// (output)
    // ---- 出口 ----
    .eth_axis_mdata   (mux_mdata        ),// (output)
    .eth_axis_mkeep   (mux_mkeep        ),// (output)
    .eth_axis_mlast   (mux_mlast        ),// (output)
    .eth_axis_mvalid  (mux_mvalid       ),// (output)
    .eth_axis_musr    (                 ),// (output)
    .eth_axis_mready  (mux_mready       ),// (input)
    // ---- 状态 ----
    .stat_active_port (stat_tx_active_port),// (output)
    .stat_idle        (stat_tx_idle     ) // (output)
  );


  eth_frame_pad60 #(
    .MIN_FRAME_BYTES  (60               ) 
  ) u_frame_pad (
    .clk              (clk              ),
    .rst              (rst              ),
    .eth_axis_sdata   (mux_mdata        ),
    .eth_axis_skeep   (mux_mkeep        ),
    .eth_axis_slast   (mux_mlast        ),
    .eth_axis_svalid  (mux_mvalid       ),
    .eth_axis_sready  (mux_mready       ),
    .eth_axis_mdata   (pad_data         ),
    .eth_axis_mkeep   (pad_keep         ),
    .eth_axis_mlast   (pad_last         ),
    .eth_axis_mvalid  (pad_valid        ),
    .eth_axis_mready  (pad_ready        ) 
  );

  axis_fifo_async #(
    .FIFO_DEPTH       (CDC_FIFO_DEPTH   ),
    .AXIS_WIDTH       (512              ),
    .AXIS_USER_WIDTH  (1                ),
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
    .axis_susr        ('d0              ),
    .axis_sstrb       ('d0              ),
    .axis_sid         ('d0              ),
    .axis_sdest       ('d0              ),
    .axis_mdata       (sk_tx_m_data     ),
    .axis_mkeep       (sk_tx_m_keep     ),
    .axis_mvalid      (sk_tx_m_valid    ),
    .axis_mlast       (sk_tx_m_last     ),
    .axis_mready      (sk_tx_m_ready    ),
    .axis_musr        (sk_tx_m_usr      ),
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
    .s_axis_tuser     (1'b0             ),
    .m_axis_tvalid    (ct_valid         ),
    .m_axis_tready    (ct_ready         ),
    .m_axis_tdata     (ct_data          ),
    .m_axis_tkeep     (ct_keep          ),
    .m_axis_tlast     (ct_last          ),
    .m_axis_tuser     (ct_usr           ) 
  );

endmodule
`resetall
