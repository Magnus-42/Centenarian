`timescale 1ns / 1ps

// Language: Verilog 2001
// ============================================================================
// File Name   : cmac_test_top.v
// Module Name : cmac_test_top
// Author      : LiXintao
// Date        : 2026-10-12
// Version     : v2.1
// ----------------------------------------------------------------------------
// Description : 测试CMAC核是否正常工作
//              测试内容：A口对B口打流，B口接收并校验
// ============================================================================

module cmac_test_top(
  input                                                sys_clk         ,
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
  localparam AXIS_WIDTH= 512;
  localparam AXIS_USER_WIDTH= 1 ;

  wire                                                 clk_200m           ;
  wire                                                 clk_locked         ;
  wire                                                 usr_tx_reset_a,  usr_rx_reset_a,usr_tx_reset_b,usr_rx_reset_b;
  wire                                                 usr_rst            ;
  wire                                                 qsfp_usr_rst       ;
  wire                                                 test_enable        ;

  wire                                                 gt_txusrclk_a      ;
  wire                                                 gt_rxusrclk_b      ;


  // ----------------------------------------------------------------------------
  // AXIS 连线 : mac_rx_top -> fifo_axis_rx
  // ----------------------------------------------------------------------------
  wire                 [        AXIS_WIDTH-1: 0]       test_axis_sdata    ;
  wire                 [      AXIS_WIDTH/8-1: 0]       test_axis_skeep    ;
  wire                                                 test_axis_svalid   ;
  wire                                                 test_axis_slast    ;
  wire                 [   AXIS_USER_WIDTH-1: 0]       test_axis_susr     ;
  wire                                                 test_axis_sready   ;

  // ----------------------------------------------------------------------------
  // AXIS 连线 : fifo_axis_rx -> eth_10g_tester (校验机)
  // ----------------------------------------------------------------------------
  wire                 [        AXIS_WIDTH-1: 0]       asyn_test_axis_sdata  ;
  wire                 [      AXIS_WIDTH/8-1: 0]       asyn_test_axis_skeep  ;
  wire                                                 asyn_test_axis_svalid  ;
  wire                                                 asyn_test_axis_slast  ;
  wire                 [   AXIS_USER_WIDTH-1: 0]       asyn_test_axis_susr   ;
  wire                                                 asyn_test_axis_sready  ;

  // ----------------------------------------------------------------------------
  // AXIS 连线 : eth_10g_tester (发包机) -> fifo_axis_tx
  // ----------------------------------------------------------------------------
  wire                 [        AXIS_WIDTH-1: 0]       test_axis_mdata    ;
  wire                 [      AXIS_WIDTH/8-1: 0]       test_axis_mkeep    ;
  wire                                                 test_axis_mvalid   ;
  wire                                                 test_axis_mlast    ;
  wire                 [   AXIS_USER_WIDTH-1: 0]       test_axis_musr     ;
  wire                                                 test_axis_mready   ;

  // ----------------------------------------------------------------------------
  // AXIS 连线 : fifo_axis_tx -> mac_tx_top
  // ----------------------------------------------------------------------------
  wire                 [        AXIS_WIDTH-1: 0]       asyn_test_axis_mdata  ;
  wire                 [      AXIS_WIDTH/8-1: 0]       asyn_test_axis_mkeep  ;
  wire                                                 asyn_test_axis_mvalid  ;
  wire                                                 asyn_test_axis_mlast  ;
  wire                 [   AXIS_USER_WIDTH-1: 0]       asyn_test_axis_musr   ;
  wire                                                 asyn_test_axis_mready  ;

  assign  qsfp_usr_rst     = usr_tx_reset_a | usr_rx_reset_a | usr_tx_reset_b | usr_rx_reset_b;

  xpm_cdc_sync_rst #(
    .DEST_SYNC_FF     (2                ),// 同步链深度，2级
    .INIT             (1                ) // dest_rst初始值，上电保持复位
  ) u_usr_rst_sync (
    .src_rst          (qsfp_usr_rst     ),
    .dest_clk         (clk_200m         ),
    .dest_rst         (usr_rst          ) 
  );

  clk_100_to_200m u_clk_100_to_200m (
    .clk_200m         (clk_200m         ),
    .locked           (clk_locked       ),
    .clk_100m         (sys_clk          ) 
  );
    
  cmac_a_if u_cmac_a_if(
    .init_clk         (sys_clk          ),// (input)
    .sys_reset        (~clk_locked      ),// (input) 时钟未锁定期间复位CMAC
    .gt_txp_out       (gt_txp_out_a     ),// (output)
    .gt_txn_out       (gt_txn_out_a     ),// (output)
    .gt_rxp_in        (gt_rxp_in_a      ),// (input)
    .gt_rxn_in        (gt_rxn_in_a      ),// (input)
    .gt_ref_clk_p     (gt_ref_clk_p_a   ),// (input)
    .gt_ref_clk_n     (gt_ref_clk_n_a   ),// (input)
    .gt_txusrclk      (gt_txusrclk_a    ),// (output)
    .gt_rxusrclk      (                 ),// (output)
    .axis_mvalid      (                 ),// (output)
    .axis_mdata       (                 ),// (output)
    .axis_mlast       (                 ),// (output)
    .axis_mkeep       (                 ),// (output)
    .axis_musr        (                 ),// (output)
    .axis_svalid      (asyn_test_axis_mvalid),// (input)
    .axis_sdata       (asyn_test_axis_mdata),// (input)
    .axis_slast       (asyn_test_axis_mlast),// (input)
    .axis_skeep       (asyn_test_axis_mkeep),// (input)
    .axis_susr        (asyn_test_axis_musr),// (input)
    .axis_sready      (asyn_test_axis_mready),// (output)
    .usr_tx_reset     (usr_tx_reset_a   ),// (output)
    .usr_rx_reset     (usr_rx_reset_a   ),// (output)

    .qsfp_rstn_port   (qsfp_rstn_port_a ),// (output)
    .qsfp_lp_mode_port(qsfp_lp_mode_port_a),// (output)
    .qsfp_seln_port   (qsfp_seln_port_a ),// (output)
    .qsfp_prsn_port   (qsfp_prsn_port_a ),// (input)
    .qsfp_led_port    (qsfp_led_port_a  ) // (output)
  );

  cmac_b_if u_cmac_b_if(
    .init_clk         (sys_clk          ),// (input)
    .sys_reset        (~clk_locked      ),// (input) 时钟未锁定期间复位CMAC
    .gt_txp_out       (gt_txp_out_b     ),// (output)
    .gt_txn_out       (gt_txn_out_b     ),// (output)
    .gt_rxp_in        (gt_rxp_in_b      ),// (input)
    .gt_rxn_in        (gt_rxn_in_b      ),// (input)
    .gt_ref_clk_p     (gt_ref_clk_p_b   ),// (input)
    .gt_ref_clk_n     (gt_ref_clk_n_b   ),// (input)
    .gt_txusrclk      (                 ),// (output)
    .gt_rxusrclk      (gt_rxusrclk_b    ),// (output)
    .axis_mvalid      (test_axis_svalid ),// (output)
    .axis_mdata       (test_axis_sdata  ),// (output)
    .axis_mlast       (test_axis_slast  ),// (output)
    .axis_mkeep       (test_axis_skeep  ),// (output)
    .axis_musr        (test_axis_susr  ),// (output)
    .axis_svalid      ('d0              ),// (input)
    .axis_sdata       ('d0              ),// (input)
    .axis_slast       ('d0              ),// (input)
    .axis_skeep       ('d0              ),// (input)
    .axis_susr        ('d0              ),// (input)
    .axis_sready      (                 ),// (output)
    .usr_tx_reset     (usr_tx_reset_b   ),// (output)
    .usr_rx_reset     (usr_rx_reset_b   ),// (output)
    .qsfp_rstn_port   (qsfp_rstn_port_b ),// (output)
    .qsfp_lp_mode_port(qsfp_lp_mode_port_b),// (output)
    .qsfp_seln_port   (qsfp_seln_port_b ),// (output)
    .qsfp_prsn_port   (qsfp_prsn_port_b ),// (input)
    .qsfp_led_port    (qsfp_led_port_b  ) // (output)
  );


  axis_fifo_async#(
    .FIFO_DEPTH       (512              ),
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .AXIS_ID_WIDTH    (1                ),
    .AXIS_DEST_WIDTH  (1                ),
    .PACKET_FIFO      (0                ),
    .FIFO_MEMORY_TYPE ("auto"           ),
    .BRAM_DO_REG      (2                ) 
  )
  axis_fifo_async_rx(
    .srst             (usr_rx_reset_b   ),// (input)
    .sclk             (gt_rxusrclk_b    ),// (input)
    .mclk             (clk_200m         ),// (input)
  // ============================================================================
  // AXI-Stream 从机接口 (上游写)
  // ============================================================================
    .axis_sdata       (test_axis_sdata  ),// (input)// 数据
    .axis_skeep       (test_axis_skeep  ),// (input)// 字节有效标志
    .axis_svalid      (test_axis_svalid ),// (input)// 数据有效
    .axis_slast       (test_axis_slast  ),// (input)// 包结束标志
    .axis_sready      (                 ),// (output)// 反压: 还能写入
    .axis_susr        (test_axis_susr   ),// (input)// 用户自定义信息
    .axis_sstrb       ('d0              ),// (input)// 字节选通
    .axis_sid         ('d0              ),// (input)// 流标识
    .axis_sdest       ('d0              ),// (input)// 路由信息
  // ============================================================================
  // AXI-Stream 主机接口 (下游读)
  // ============================================================================
    .axis_mdata       (asyn_test_axis_sdata),// (output)// 数据
    .axis_mkeep       (asyn_test_axis_skeep),// (output)// 字节有效标志
    .axis_mvalid      (asyn_test_axis_svalid),// (output)// 有数据可读
    .axis_mlast       (asyn_test_axis_slast),// (output)// 包结束标志
    .axis_mready      (asyn_test_axis_sready),// (input)// 下游能接收
    .axis_musr        (asyn_test_axis_susr),// (output)// 用户自定义信息
    .axis_mstrb       (                 ),// (output)// 字节选通
    .axis_mid         (                 ),// (output)// 流标识
    .axis_mdest       (                 ),// (output)// 路由信息
  // ============================================================================
  // 状态端口
  // ============================================================================
    .prog_almost_empty(                 ),// (output)// 剩余深度 <= PROG_EMPTY_THRESH
    .prog_almost_full (                 ),// (output)// 剩余深度 >= PROG_FULL_THRESH
    .almost_empty     (                 ),// (output)// FIFO 空
    .almost_full      (                 ),// (output)// FIFO 满
    .wr_almost_remain_count(                 ),// (output)
    .rd_almost_remain_count(                 ) // (output)
  );

    


  eth_100g_tester#(
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .PKT_LEN_BEATS    (16               ),
    .ONE_SEC_CYCLES   (32'd200_000_000  ),
    .AXIS_USER_VAL    (1'b0             ) // 本路径直连 CMAC(tx tuser), 须 0(非 0=注入 CRC 错帧)
  )
  u_eth_100g_tester(
  // --- TX 域 (发包机) ---
    .clk              (clk_200m         ),// (input)
    .rst              (usr_rst          ),// (input)
    .axis_mdata       (test_axis_mdata  ),// (output)
    .axis_mkeep       (test_axis_mkeep  ),// (output)
    .axis_mvalid      (test_axis_mvalid ),// (output)
    .axis_mlast       (test_axis_mlast  ),// (output)
    .axis_musr        (test_axis_musr  ),// (output)
    .axis_mready      (test_axis_mready ),// (input)
  // --- RX 域 (校验机) ---
    .axis_sdata       (asyn_test_axis_sdata),// (input)
    .axis_skeep       (asyn_test_axis_skeep),// (input)
    .axis_svalid      (asyn_test_axis_svalid),// (input)
    .axis_slast       (asyn_test_axis_slast),// (input)
    .axis_susr        (asyn_test_axis_susr),// (input)
    .axis_sready      (asyn_test_axis_sready),// (output)
  // --- 控制与状态 ---
    .test_enable      (test_enable      ) // (input)// 高电平启动打流
  );

  axis_fifo_async#(
    .FIFO_DEPTH       (512              ),
    .AXIS_WIDTH       (AXIS_WIDTH       ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ),
    .AXIS_ID_WIDTH    (1                ),
    .AXIS_DEST_WIDTH  (1                ),
    .PACKET_FIFO      (0                ),
    .FIFO_MEMORY_TYPE ("auto"           ),
    .BRAM_DO_REG      (2                ) 
  )
  axis_fifo_async_tx(
    .srst             (usr_rst          ),// (input)
    .sclk             (clk_200m         ),// (input)
    .mclk             (gt_txusrclk_a    ),// (input)
  // ============================================================================
  // AXI-Stream 从机接口 (上游写)
  // ============================================================================
    .axis_sdata       (test_axis_mdata  ),// (input)// 数据
    .axis_skeep       (test_axis_mkeep  ),// (input)// 字节有效标志
    .axis_svalid      (test_axis_mvalid ),// (input)// 数据有效
    .axis_slast       (test_axis_mlast  ),// (input)// 包结束标志
    .axis_sready      (test_axis_mready ),// (output)// 反压: 还能写入
    .axis_susr        (test_axis_musr   ),// (input)// 用户自定义信息
    .axis_sstrb       ('d0              ),// (input)// 字节选通
    .axis_sid         ('d0              ),// (input)// 流标识
    .axis_sdest       ('d0              ),// (input)// 路由信息
  // ============================================================================
  // AXI-Stream 主机接口 (下游读)
  // ============================================================================
    .axis_mdata       (asyn_test_axis_mdata),// (output)// 数据
    .axis_mkeep       (asyn_test_axis_mkeep),// (output)// 字节有效标志
    .axis_mvalid      (asyn_test_axis_mvalid),// (output)// 有数据可读
    .axis_mlast       (asyn_test_axis_mlast),// (output)// 包结束标志
    .axis_mready      (asyn_test_axis_mready),// (input)// 下游能接收
    .axis_musr        (asyn_test_axis_musr),// (output)// 用户自定义信息
    .axis_mstrb       (                 ),// (output)// 字节选通
    .axis_mid         (                 ),// (output)// 流标识
    .axis_mdest       (                 ),// (output)// 路由信息
  // ============================================================================
  // 状态端口
  // ============================================================================
    .prog_almost_empty(                 ),// (output)// 剩余深度 <= PROG_EMPTY_THRESH
    .prog_almost_full (                 ),// (output)// 剩余深度 >= PROG_FULL_THRESH
    .almost_empty     (                 ),// (output)// FIFO 空
    .almost_full      (                 ),// (output)// FIFO 满
    .wr_almost_remain_count(                 ),// (output)
    .rd_almost_remain_count(                 ) // (output)
  );



  vio_enable u_test_vio_enable (
    .clk              (clk_200m         ),// input wire clk
    .probe_out0       (test_enable      ) // output wire [0 : 0] probe_out0
    );

endmodule