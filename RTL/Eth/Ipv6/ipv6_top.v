`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv6_top.v
// Module Name : ipv6_top
// Author      : LiXintao
// Date        : 2026-10-11
// Version     : v7.0
// ----------------------------------------------------------------------------
// Description : IPv6 链路顶层
//
//   收: 以太帧(0x86DD) -> ipv6_eth_rx 剥以太头 -> ipv6_type_demux(Next-Header 字典匹配) -> flat 输出
//   发: IPv6 载荷(usr=优先级) -> ipv6_eth_tx(查表+插头, 未命中丢包) -> 完整以太帧(带usr)
// Note        : 1. flat 位段约定: 第 k 档 = [k*512 +: 512] (k=0..RX_TYPE_NUM-1; 末档 = other 兜底)
// ============================================================================

module ipv6_top #(
  parameter  RX_TYPE_NUM= 3 , // 用户侧档数(>=1; 不含 other 兜底档 —— 由 demux 内部自动补出)
  parameter  [     RX_TYPE_NUM*8-1:0]        RX_TYPE_DICT= {8'h59,8'h3A,8'h11}, // ospf/icmpv6/udp
  parameter  DEST_MAC_ENTRY_NUM= 8 ,
  parameter  SRC_MAC_ENTRY_NUM= 8 ,
  parameter  TX_TYPE_NUM= 3 ,
  parameter  TX_IDX_W= (TX_TYPE_NUM <= 1) ? 1 : $clog2(TX_TYPE_NUM),
  parameter  AXIS_TX_USER_WIDTH= 4 
) (
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // ============================================================================
  // RX 输入 : eth_top 分出的 IPv6 以太帧(0x86DD, 带 14B 以太头)
  // ============================================================================
  input  wire          [                 511:0]        eth_ipv6_axis_sdata,
  input  wire          [                  63:0]        eth_ipv6_axis_skeep,
  input  wire                                          eth_ipv6_axis_slast,
  input  wire                                          eth_ipv6_axis_svalid,
  input  wire                                          eth_ipv6_axis_susr,
  output wire                                          eth_ipv6_axis_sready,

  // ============================================================================
  // RX 输出 : 剥掉以太头后的纯 IPv6 包 (flat: RX_TYPE_NUM 路, 末路=other 兜底)
  // ============================================================================
  output wire          [512*(RX_TYPE_NUM+1)-1:0]       ipv6_axis_mdata ,
  output wire          [64*(RX_TYPE_NUM+1)-1:0]        ipv6_axis_mkeep ,
  output wire          [         RX_TYPE_NUM:0]        ipv6_axis_mlast ,
  output wire          [         RX_TYPE_NUM:0]        ipv6_axis_mvalid,
  output wire          [97*(RX_TYPE_NUM+1)-1:0]        ipv6_axis_musr  ,
  input  wire          [         RX_TYPE_NUM:0]        ipv6_axis_mready,

  // ============================================================================
  // TX : IPv6 载荷, 带 usr 优先级
  // ============================================================================
  input  wire          [   512*TX_TYPE_NUM-1:0]        ipv6_axis_sdata ,
  input  wire          [    64*TX_TYPE_NUM-1:0]        ipv6_axis_skeep ,
  input  wire          [       TX_TYPE_NUM-1:0]        ipv6_axis_slast ,
  input  wire          [       TX_TYPE_NUM-1:0]        ipv6_axis_svalid,
  input  wire          [AXIS_TX_USER_WIDTH*TX_TYPE_NUM-1:0]ipv6_axis_susr  ,
  output wire          [       TX_TYPE_NUM-1:0]        ipv6_axis_sready,

  // ============================================================================
  // TX 输出 : 完整以太帧(已插 14B 以太头, 未补齐/未缓冲, 带 usr) -> MAC 层仲裁器
  // ============================================================================
  output wire          [                 511:0]        eth_tx_axis_mdata,
  output wire          [                  63:0]        eth_tx_axis_mkeep,
  output wire                                          eth_tx_axis_mlast,
  output wire                                          eth_tx_axis_mvalid,
  output wire          [AXIS_TX_USER_WIDTH-1:0]        eth_tx_axis_musr,
  input  wire                                          eth_tx_axis_mready,

  // ============================================================================
  // IP->MAC 映射表(上游统一配置, "多 IP 配 MAC"; 查不到对应 MAC 的包直接丢弃)
  //   dest 表(对端): 目的IP -> 对端MAC;  src 表(本机): 本机IP -> 本机MAC
  //   第 i 项: IP  = cfg_dest_match_ipv6[i*128 +: 128] / cfg_src_match_ipv6[i*128 +: 128]
  //            MAC = cfg_dest_match_mac [i*48  +: 48 ] / cfg_src_match_mac [i*48  +: 48 ]
  // ============================================================================
  input  wire          [128*DEST_MAC_ENTRY_NUM-1:0]    cfg_dest_match_ipv6,
  input  wire          [48*DEST_MAC_ENTRY_NUM-1:0]     cfg_dest_match_mac,
  input  wire          [128*SRC_MAC_ENTRY_NUM-1:0]     cfg_src_match_ipv6,
  input  wire          [48*SRC_MAC_ENTRY_NUM-1:0]      cfg_src_match_mac,

  output wire                                          stat_tx_drop_pulse,
  output wire          [          TX_IDX_W-1:0]        stat_tx_active_port,
  output wire                                          stat_tx_idle     
);


  wire                 [                 511:0]        ipv6_rx_axis_mdata;
  wire                 [                  63:0]        ipv6_rx_axis_mkeep;
  wire                                                 ipv6_rx_axis_mlast;
  wire                                                 ipv6_rx_axis_mvalid;
  wire                 [                  96:0]        ipv6_rx_axis_musr;
  wire                                                 ipv6_rx_axis_mready;

  wire                 [                  47:0]        dest_mac         ;
  wire                 [                  47:0]        src_mac          ;

ipv6_type_demux #(
    .TYPE_NUM         (RX_TYPE_NUM      ),
    .TYPE_DICT        (RX_TYPE_DICT     ) 
) u_ipv6_type_demux(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .ipv6_axis_sdata  (ipv6_rx_axis_mdata),// (input)
    .ipv6_axis_skeep  (ipv6_rx_axis_mkeep),// (input)
    .ipv6_axis_slast  (ipv6_rx_axis_mlast),// (input)
    .ipv6_axis_svalid (ipv6_rx_axis_mvalid),// (input)
    .ipv6_axis_susr   (ipv6_rx_axis_musr),// (input)
    .ipv6_axis_sready (ipv6_rx_axis_mready),// (output)
    .ipv6_axis_mdata  (ipv6_axis_mdata  ),// (output)
    .ipv6_axis_mkeep  (ipv6_axis_mkeep  ),// (output)
    .ipv6_axis_mlast  (ipv6_axis_mlast  ),// (output)
    .ipv6_axis_mvalid (ipv6_axis_mvalid ),// (output)
    .ipv6_axis_musr   (ipv6_axis_musr   ),// (output)
    .ipv6_axis_mready (ipv6_axis_mready ) // (input)
);

  ipv6_eth_rx u_ipv6_eth_rx (
    .clk              (clk              ),
    .rst              (rst              ),
    .eth_ipv6_axis_sdata(eth_ipv6_axis_sdata),
    .eth_ipv6_axis_skeep(eth_ipv6_axis_skeep),
    .eth_ipv6_axis_slast(eth_ipv6_axis_slast),
    .eth_ipv6_axis_svalid(eth_ipv6_axis_svalid),
    .eth_ipv6_axis_susr(eth_ipv6_axis_susr),
    .eth_ipv6_axis_sready(eth_ipv6_axis_sready),
    .ipv6_axis_mdata  (ipv6_rx_axis_mdata),
    .ipv6_axis_mkeep  (ipv6_rx_axis_mkeep),
    .ipv6_axis_mlast  (ipv6_rx_axis_mlast),
    .ipv6_axis_mvalid (ipv6_rx_axis_mvalid),
    .ipv6_axis_mready (ipv6_rx_axis_mready),
    .ipv6_axis_musr   (ipv6_rx_axis_musr[0]),
    .dest_mac         (dest_mac         ),
    .src_mac          (src_mac          ) 
  );
  assign  ipv6_rx_axis_musr[96:1]= {src_mac,dest_mac};

  // ============================================================================
  // TX
  // ============================================================================

  wire                 [                 511:0]        mux_mdata        ;
  wire                 [                  63:0]        mux_mkeep        ;
  wire                                                 mux_mlast        ;
  wire                                                 mux_mvalid       ;
  wire                 [AXIS_TX_USER_WIDTH-1:0]        mux_musr         ;
  wire                                                 mux_mready       ;


  ipv6_tx_mux#(
    .TYPE_NUM         (TX_TYPE_NUM      ),
    .AXIS_USER_WIDTH  (AXIS_TX_USER_WIDTH) 
  )
  u_ipv6_tx_mux(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    // ---- 入口 ----
    .ipv6_axis_sdata  (ipv6_axis_sdata  ),// (input)
    .ipv6_axis_skeep  (ipv6_axis_skeep  ),// (input)
    .ipv6_axis_slast  (ipv6_axis_slast  ),// (input)
    .ipv6_axis_svalid (ipv6_axis_svalid ),// (input)
    .ipv6_axis_susr   (ipv6_axis_susr   ),// (input)
    .ipv6_axis_sready (ipv6_axis_sready ),// (output)
    // ---- 出口 ----
    .ipv6_axis_mdata  (mux_mdata        ),// (output)
    .ipv6_axis_mkeep  (mux_mkeep        ),// (output)
    .ipv6_axis_mlast  (mux_mlast        ),// (output)
    .ipv6_axis_mvalid (mux_mvalid       ),// (output)
    .ipv6_axis_musr   (mux_musr         ),// (output)
    .ipv6_axis_mready (mux_mready       ),// (input)
    // ---- 状态 ----
    .stat_active_port (stat_tx_active_port),// (output)// 0=other 1=ospf 2=icmp 3=udp
    .stat_idle        (stat_tx_idle     ) // (output)
  );

  ipv6_eth_tx #(
    .DEST_MAC_ENTRY_NUM(DEST_MAC_ENTRY_NUM),
    .SRC_MAC_ENTRY_NUM(SRC_MAC_ENTRY_NUM) 
  ) u_ipv6_eth_tx (
    .clk              (clk              ),
    .rst              (rst              ),
    .ipv6_axis_sdata  (mux_mdata        ),
    .ipv6_axis_skeep  (mux_mkeep        ),
    .ipv6_axis_slast  (mux_mlast        ),
    .ipv6_axis_svalid (mux_mvalid       ),
    .ipv6_axis_susr   (mux_musr         ),
    .ipv6_axis_sready (mux_mready       ),
    .cfg_dest_match_ipv6(cfg_dest_match_ipv6),
    .cfg_dest_match_mac(cfg_dest_match_mac),
    .cfg_src_match_ipv6(cfg_src_match_ipv6),
    .cfg_src_match_mac(cfg_src_match_mac),
    .eth_axis_mdata   (eth_tx_axis_mdata),
    .eth_axis_mkeep   (eth_tx_axis_mkeep),
    .eth_axis_mlast   (eth_tx_axis_mlast),
    .eth_axis_mvalid  (eth_tx_axis_mvalid),
    .eth_axis_musr    (eth_tx_axis_musr ),
    .eth_axis_mready  (eth_tx_axis_mready),
    .stat_drop_pulse  (stat_tx_drop_pulse) 
  );

endmodule
`resetall
