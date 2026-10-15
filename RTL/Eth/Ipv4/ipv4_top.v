`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv4_top.v
// Module Name : ipv4_top
// Author      : LiXintao
// Date        : 2026-10-11
// Version     : v4.0
// ----------------------------------------------------------------------------
// Description : IPv4 链路顶层
//
//   收: 以太帧(0x0800) -> ipv4_eth_rx 剥头 -> ipv4_type_demux -> flat 输出
//   发: IPv4 载荷(usr=优先级) -> ipv4_eth_tx(查 ARP + 插 MAC 头) -> 完整以太帧
// Note        : 1. flat 位段约定: 第 k 档 = [k*512 +: 512] (k=0..RX_TYPE_NUM-1; 末档 = other 兜底)
// ============================================================================

module ipv4_top #(
  parameter  RX_TYPE_NUM= 4 , // 用户侧档数(>=1; 不含 other 兜底档 —— 由 demux 内部自动补出)
  parameter  [     RX_TYPE_NUM*8-1:0]        RX_TYPE_DICT= {8'h59,8'h01,8'h11}, // ospf/icmp/udp
  parameter  TX_TYPE_NUM= 3 ,
  parameter  TX_IDX_W= (TX_TYPE_NUM <= 1) ? 1 : $clog2(TX_TYPE_NUM),
  parameter  AXIS_USER_WIDTH= 4 
) (
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // ============================================================================
  // RX 输入 : eth_top 分出的 IPv4 以太帧(0x0800, 带 14B 以太头)
  // ============================================================================
  input  wire          [                 511:0]        eth_ipv4_axis_sdata,
  input  wire          [                  63:0]        eth_ipv4_axis_skeep,
  input  wire                                          eth_ipv4_axis_slast,
  input  wire                                          eth_ipv4_axis_svalid,
  input  wire                                          eth_ipv4_axis_susr,
  output wire                                          eth_ipv4_axis_sready,

  // ============================================================================
  // RX 输出 : 剥掉以太头后的纯 IPv4 包 (flat: RX_TYPE_NUM 路, 末路=other 兜底)
  // ============================================================================
  output wire          [512*(RX_TYPE_NUM+1)-1:0]       ipv4_axis_mdata ,
  output wire          [64*(RX_TYPE_NUM+1)-1:0]        ipv4_axis_mkeep ,
  output wire          [         RX_TYPE_NUM:0]        ipv4_axis_mlast ,
  output wire          [         RX_TYPE_NUM:0]        ipv4_axis_mvalid,
  output wire          [97*(RX_TYPE_NUM+1)-1:0]        ipv4_axis_musr  ,
  input  wire          [         RX_TYPE_NUM:0]        ipv4_axis_mready,

  // ============================================================================
  // TX : IPv4 载荷，带 usr 优先级
  // ============================================================================
  input  wire          [   512*TX_TYPE_NUM-1:0]        ipv4_axis_sdata ,
  input  wire          [    64*TX_TYPE_NUM-1:0]        ipv4_axis_skeep ,
  input  wire          [       TX_TYPE_NUM-1:0]        ipv4_axis_slast ,
  input  wire          [       TX_TYPE_NUM-1:0]        ipv4_axis_svalid,
  input  wire          [AXIS_USER_WIDTH*TX_TYPE_NUM-1:0]ipv4_axis_susr  ,
  output wire          [       TX_TYPE_NUM-1:0]        ipv4_axis_sready,

  // ============================================================================
  // TX 输出 : 完整以太帧(已插 14B 以太头, 未补齐/未缓冲, 带 usr) -> MAC 层仲裁器
  // ============================================================================
  output wire          [                 511:0]        eth_tx_axis_mdata,
  output wire          [                  63:0]        eth_tx_axis_mkeep,
  output wire                                          eth_tx_axis_mlast,
  output wire                                          eth_tx_axis_mvalid,
  output wire          [   AXIS_USER_WIDTH-1:0]        eth_tx_axis_musr,
  input  wire                                          eth_tx_axis_mready,

  // ============================================================================
  // ARP 查询握手接口 : 由上层接到 arp_engine_top
  // ============================================================================
  output wire          [                  31:0]        query_src_ip    ,
  output wire          [                  31:0]        query_dst_ip    ,
  output wire                                          query_valid_pulse,
  input  wire          [                  47:0]        arp_dst_mac     ,
  input  wire          [                  47:0]        arp_src_mac     ,
  input  wire                                          arp_miss        ,
  input  wire                                          arp_valid       ,

  output wire          [          TX_IDX_W-1:0]        stat_tx_active_port,
  output wire                                          stat_tx_idle     
);


  wire                 [                 511:0]        ipv4_rx_axis_mdata;
  wire                 [                  63:0]        ipv4_rx_axis_mkeep;
  wire                                                 ipv4_rx_axis_mlast;
  wire                                                 ipv4_rx_axis_mvalid;
  wire                 [                  96:0]        ipv4_rx_axis_musr;
  wire                                                 ipv4_rx_axis_mready;

  wire                 [                  47:0]        dest_mac         ;
  wire                 [                  47:0]        src_mac          ;

ipv4_type_demux #(
    .TYPE_NUM         (RX_TYPE_NUM      ),
    .TYPE_DICT        (RX_TYPE_DICT     ) 
) u_ipv4_type_demux(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .ipv4_axis_sdata  (ipv4_rx_axis_mdata),// (input)
    .ipv4_axis_skeep  (ipv4_rx_axis_mkeep),// (input)
    .ipv4_axis_slast  (ipv4_rx_axis_mlast),// (input)
    .ipv4_axis_svalid (ipv4_rx_axis_mvalid),// (input)
    .ipv4_axis_susr   (ipv4_rx_axis_musr),// (input)
    .ipv4_axis_sready (ipv4_rx_axis_mready),// (output)
    .ipv4_axis_mdata  (ipv4_axis_mdata  ),// (output)
    .ipv4_axis_mkeep  (ipv4_axis_mkeep  ),// (output)
    .ipv4_axis_mlast  (ipv4_axis_mlast  ),// (output)
    .ipv4_axis_mvalid (ipv4_axis_mvalid ),// (output)
    .ipv4_axis_musr   (ipv4_axis_musr   ),// (output)
    .ipv4_axis_mready (ipv4_axis_mready ) // (input)
);

  ipv4_eth_rx u_ipv4_eth_rx (
    .clk              (clk              ),
    .rst              (rst              ),
    .eth_ipv4_axis_sdata(eth_ipv4_axis_sdata),
    .eth_ipv4_axis_skeep(eth_ipv4_axis_skeep),
    .eth_ipv4_axis_slast(eth_ipv4_axis_slast),
    .eth_ipv4_axis_svalid(eth_ipv4_axis_svalid),
    .eth_ipv4_axis_susr(eth_ipv4_axis_susr),
    .eth_ipv4_axis_sready(eth_ipv4_axis_sready),
    .ipv4_axis_mdata  (ipv4_rx_axis_mdata),
    .ipv4_axis_mkeep  (ipv4_rx_axis_mkeep),
    .ipv4_axis_mlast  (ipv4_rx_axis_mlast),
    .ipv4_axis_mvalid (ipv4_rx_axis_mvalid),
    .ipv4_axis_musr   (ipv4_rx_axis_musr[0]),
    .ipv4_axis_mready (ipv4_rx_axis_mready),
    .dest_mac         (dest_mac         ),
    .src_mac          (src_mac          ) 
  );
  assign  ipv4_rx_axis_musr[96:1]= {src_mac,dest_mac};

  wire                 [                 511:0]        ipv4_tx_mdata    ;
  wire                 [                  63:0]        ipv4_tx_mkeep    ;
  wire                                                 ipv4_tx_mlast    ;
  wire                                                 ipv4_tx_mvalid   ;
  wire                 [   AXIS_USER_WIDTH-1:0]        ipv4_tx_musr     ;
  wire                                                 ipv4_tx_mready   ;
  
  ipv4_tx_mux#(
    .TYPE_NUM         (TX_TYPE_NUM      ),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ) 
  )
  u_ipv4_tx_mux(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
  // ---- 入口 ----
    .ipv4_axis_sdata  (ipv4_axis_sdata  ),// (input)
    .ipv4_axis_skeep  (ipv4_axis_skeep  ),// (input)
    .ipv4_axis_slast  (ipv4_axis_slast  ),// (input)
    .ipv4_axis_svalid (ipv4_axis_svalid ),// (input)
    .ipv4_axis_susr   (ipv4_axis_susr   ),// (input)
    .ipv4_axis_sready (ipv4_axis_sready ),// (output)
  // ---- 出口 ----
    .ipv4_axis_mdata  (ipv4_tx_mdata    ),// (output)
    .ipv4_axis_mkeep  (ipv4_tx_mkeep    ),// (output)
    .ipv4_axis_mlast  (ipv4_tx_mlast    ),// (output)
    .ipv4_axis_mvalid (ipv4_tx_mvalid   ),// (output)
    .ipv4_axis_musr   (ipv4_tx_musr     ),// (input)
    .ipv4_axis_mready (ipv4_tx_mready   ),// (input)
  // ---- 状态 ----
    .stat_active_port (stat_tx_active_port),// (output)// 0=other 1=ospf 2=icmp 3=udp
    .stat_idle        (stat_tx_idle     ) // (output)
  );


  ipv4_eth_tx #(
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  ) 
  )
  u_ipv4_eth_tx(
    .clk              (clk              ),
    .rst              (rst              ),
    .ipv4_axis_sdata  (ipv4_tx_mdata    ),
    .ipv4_axis_skeep  (ipv4_tx_mkeep    ),
    .ipv4_axis_slast  (ipv4_tx_mlast    ),
    .ipv4_axis_svalid (ipv4_tx_mvalid   ),
    .ipv4_axis_susr   (ipv4_tx_musr     ),
    .ipv4_axis_sready (ipv4_tx_mready   ),
    .query_src_ip     (query_src_ip     ),
    .query_dst_ip     (query_dst_ip     ),
    .query_valid_pulse(query_valid_pulse),
    .arp_dst_mac      (arp_dst_mac      ),
    .arp_src_mac      (arp_src_mac      ),
    .arp_miss         (arp_miss         ),
    .arp_valid        (arp_valid        ),
    .eth_axis_mdata   (eth_tx_axis_mdata),
    .eth_axis_mkeep   (eth_tx_axis_mkeep),
    .eth_axis_mlast   (eth_tx_axis_mlast),
    .eth_axis_mvalid  (eth_tx_axis_mvalid),
    .eth_axis_musr    (eth_tx_axis_musr ),
    .eth_axis_mready  (eth_tx_axis_mready) 
  );

endmodule
`resetall
