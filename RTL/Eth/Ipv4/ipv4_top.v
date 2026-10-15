`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv4_top.v
// Module Name : ipv4_top
// Author      : LiXintao
// Date        : 2026-09-19
// Version     : v2.0
// ----------------------------------------------------------------------------
// Description : IPv4 链路顶层
//
//   收: 以太帧(0x0800) -> ipv4_eth_rx 剥头 -> 纯 IPv4 包
//   发: 纯 IPv4 包 -> ipv4_eth_tx(查下一跳 MAC + 插以太头) -> 完整以太帧
// ============================================================================

module ipv4_top #(
  parameter  AXIS_WIDTH= 512
) (
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // ============================================================================
  // RX 输入 : eth_top 分出的 IPv4 以太帧(0x0800, 带 14B 以太头)
  // ============================================================================
  input  wire          [        AXIS_WIDTH-1: 0]       eth_ipv4_axis_sdata,
  input  wire          [      AXIS_WIDTH/8-1: 0]       eth_ipv4_axis_skeep,
  input  wire                                          eth_ipv4_axis_slast,
  input  wire                                          eth_ipv4_axis_svalid,
  output wire                                          eth_ipv4_axis_sready,

  // ============================================================================
  // RX 输出 : 剥掉以太头后的纯 IPv4 包 (给上层/DMA)
  // ============================================================================
  output wire          [                 511: 0]       ipv4_udp_axis_mdata,
  output wire          [                  63: 0]       ipv4_udp_axis_mkeep,
  output wire                                          ipv4_udp_axis_mlast,
  output wire                                          ipv4_udp_axis_mvalid,
  output wire          [                  95: 0]       ipv4_udp_axis_musr,
  input  wire                                          ipv4_udp_axis_mready,
  output wire          [                 511: 0]       ipv4_icmp_axis_mdata,
  output wire          [                  63: 0]       ipv4_icmp_axis_mkeep,
  output wire                                          ipv4_icmp_axis_mlast,
  output wire                                          ipv4_icmp_axis_mvalid,
  output wire          [                  95: 0]       ipv4_icmp_axis_musr,
  input  wire                                          ipv4_icmp_axis_mready,
  output wire          [                 511: 0]       ipv4_ospf_axis_mdata,
  output wire          [                  63: 0]       ipv4_ospf_axis_mkeep,
  output wire                                          ipv4_ospf_axis_mlast,
  output wire                                          ipv4_ospf_axis_mvalid,
  output wire          [                  95: 0]       ipv4_ospf_axis_musr,
  input  wire                                          ipv4_ospf_axis_mready,
  output wire          [                 511: 0]       ipv4_other_axis_mdata,
  output wire          [                  63: 0]       ipv4_other_axis_mkeep,
  output wire                                          ipv4_other_axis_mlast,
  output wire                                          ipv4_other_axis_mvalid,
  output wire          [                  95: 0]       ipv4_other_axis_musr,
  input  wire                                          ipv4_other_axis_mready,

  // ============================================================================
  // TX : 待发送的纯 IPv4 包 (来自上层/DMA)
  // ============================================================================
  input  wire          [                 511: 0]       ipv4_other_axis_sdata,
  input  wire          [                  63: 0]       ipv4_other_axis_skeep,
  input  wire                                          ipv4_other_axis_slast,
  input  wire                                          ipv4_other_axis_svalid,
  output wire                                          ipv4_other_axis_sready,
  input  wire          [                 511: 0]       ipv4_ospf_axis_sdata,
  input  wire          [                  63: 0]       ipv4_ospf_axis_skeep,
  input  wire                                          ipv4_ospf_axis_slast,
  input  wire                                          ipv4_ospf_axis_svalid,
  output wire                                          ipv4_ospf_axis_sready,
  input  wire          [                 511: 0]       ipv4_icmp_axis_sdata,
  input  wire          [                  63: 0]       ipv4_icmp_axis_skeep,
  input  wire                                          ipv4_icmp_axis_slast,
  input  wire                                          ipv4_icmp_axis_svalid,
  output wire                                          ipv4_icmp_axis_sready,
  input  wire          [                 511: 0]       ipv4_udp_axis_sdata,
  input  wire          [                  63: 0]       ipv4_udp_axis_skeep,
  input  wire                                          ipv4_udp_axis_slast,
  input  wire                                          ipv4_udp_axis_svalid,
  output wire                                          ipv4_udp_axis_sready,


  // ============================================================================
  // TX 输出 : 完整以太帧(已插 14B 以太头, 未补齐/未缓冲) -> eth_top
  // ============================================================================
  output wire          [        AXIS_WIDTH-1: 0]       eth_tx_axis_mdata,
  output wire          [      AXIS_WIDTH/8-1: 0]       eth_tx_axis_mkeep,
  output wire                                          eth_tx_axis_mlast,
  output wire                                          eth_tx_axis_mvalid,
  input  wire                                          eth_tx_axis_mready,

  // ============================================================================
  // ARP 查询握手接口 : 由上层接到 arp_engine_top
  // ============================================================================
  output wire          [                  31: 0]       query_src_ip    ,
  output wire          [                  31: 0]       query_dst_ip    ,
  output wire                                          query_valid_pulse,
  input  wire          [                  47: 0]       arp_dst_mac     ,
  input  wire          [                  47: 0]       arp_src_mac     ,
  input  wire                                          arp_miss        ,
  input  wire                                          arp_valid       ,

  output wire          [                   1: 0]       stat_active_port,
  output wire                                          stat_idle        
);


  wire                 [                 511: 0]       ipv4_rx_axis_mdata  ;
  wire                 [                  63: 0]       ipv4_rx_axis_mkeep  ;
  wire                                                 ipv4_rx_axis_mlast  ;
  wire                                                 ipv4_rx_axis_mvalid  ;
  wire                 [                  95: 0]       ipv4_rx_axis_musr  ;
  wire                                                 ipv4_rx_axis_mready  ;

  wire                 [                  47: 0]       dest_mac           ;
  wire                 [                  47: 0]       src_mac            ;

ipv4_type_demux u_ipv4_type_demux(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .ipv4_axis_sdata  (ipv4_rx_axis_mdata),// (input)
    .ipv4_axis_skeep  (ipv4_rx_axis_mkeep),// (input)
    .ipv4_axis_slast  (ipv4_rx_axis_mlast),// (input)
    .ipv4_axis_svalid (ipv4_rx_axis_mvalid),// (input)
    .ipv4_axis_susr   (ipv4_rx_axis_musr),// (input)
    .ipv4_axis_sready (ipv4_rx_axis_mready),// (output)
    .ipv4_udp_axis_mdata(ipv4_udp_axis_mdata),// (output)
    .ipv4_udp_axis_mkeep(ipv4_udp_axis_mkeep),// (output)
    .ipv4_udp_axis_mlast(ipv4_udp_axis_mlast),// (output)
    .ipv4_udp_axis_mvalid(ipv4_udp_axis_mvalid),// (output)
    .ipv4_udp_axis_musr(ipv4_udp_axis_musr),// (output)
    .ipv4_udp_axis_mready(ipv4_udp_axis_mready),// (input)
    .ipv4_icmp_axis_mdata(ipv4_icmp_axis_mdata),// (output)
    .ipv4_icmp_axis_mkeep(ipv4_icmp_axis_mkeep),// (output)
    .ipv4_icmp_axis_mlast(ipv4_icmp_axis_mlast),// (output)
    .ipv4_icmp_axis_mvalid(ipv4_icmp_axis_mvalid),// (output)
    .ipv4_icmp_axis_musr(ipv4_icmp_axis_musr),// (output)
    .ipv4_icmp_axis_mready(ipv4_icmp_axis_mready),// (input)
    .ipv4_ospf_axis_mdata(ipv4_ospf_axis_mdata),// (output)
    .ipv4_ospf_axis_mkeep(ipv4_ospf_axis_mkeep),// (output)
    .ipv4_ospf_axis_mlast(ipv4_ospf_axis_mlast),// (output)
    .ipv4_ospf_axis_mvalid(ipv4_ospf_axis_mvalid),// (output)
    .ipv4_ospf_axis_musr(ipv4_ospf_axis_musr),// (output)
    .ipv4_ospf_axis_mready(ipv4_ospf_axis_mready),// (input)
    .ipv4_other_axis_mdata(ipv4_other_axis_mdata),// (output)
    .ipv4_other_axis_mkeep(ipv4_other_axis_mkeep),// (output)
    .ipv4_other_axis_mlast(ipv4_other_axis_mlast),// (output)
    .ipv4_other_axis_mvalid(ipv4_other_axis_mvalid),// (output)
    .ipv4_other_axis_musr(ipv4_other_axis_musr),// (output)
    .ipv4_other_axis_mready(ipv4_other_axis_mready) // (input)
);

  ipv4_eth_rx u_ipv4_eth_rx (
    .clk              (clk              ),
    .rst              (rst              ),
    .eth_ipv4_axis_sdata(eth_ipv4_axis_sdata),
    .eth_ipv4_axis_skeep(eth_ipv4_axis_skeep),
    .eth_ipv4_axis_slast(eth_ipv4_axis_slast),
    .eth_ipv4_axis_svalid(eth_ipv4_axis_svalid),
    .eth_ipv4_axis_sready(eth_ipv4_axis_sready),
    .ipv4_axis_mdata  (ipv4_rx_axis_mdata),
    .ipv4_axis_mkeep  (ipv4_rx_axis_mkeep),
    .ipv4_axis_mlast  (ipv4_rx_axis_mlast),
    .ipv4_axis_mvalid (ipv4_rx_axis_mvalid),
    .ipv4_axis_mready (ipv4_rx_axis_mready),
    .dest_mac         (dest_mac         ),
    .src_mac          (src_mac          ) 
  );
  assign  ipv4_rx_axis_musr= {src_mac,dest_mac};

  wire                 [                 511: 0]       ipv4_tx_axis_mdata  ;
  wire                 [                  63: 0]       ipv4_tx_axis_mkeep  ;
  wire                                                 ipv4_tx_axis_mlast  ;
  wire                                                 ipv4_tx_axis_mvalid  ;
  wire                                                 ipv4_tx_axis_mready  ;

  ipv4_tx_mux u_ipv4_tx_mux(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    // ---- 入口 0: other(优先级最高) ----
    .ipv4_other_axis_sdata(ipv4_other_axis_sdata),// (input)
    .ipv4_other_axis_skeep(ipv4_other_axis_skeep),// (input)
    .ipv4_other_axis_slast(ipv4_other_axis_slast),// (input)
    .ipv4_other_axis_svalid(ipv4_other_axis_svalid),// (input)
    .ipv4_other_axis_sready(ipv4_other_axis_sready),// (output)
    // ---- 入口 1: ospf ----
    .ipv4_ospf_axis_sdata(ipv4_ospf_axis_sdata),// (input)
    .ipv4_ospf_axis_skeep(ipv4_ospf_axis_skeep),// (input)
    .ipv4_ospf_axis_slast(ipv4_ospf_axis_slast),// (input)
    .ipv4_ospf_axis_svalid(ipv4_ospf_axis_svalid),// (input)
    .ipv4_ospf_axis_sready(ipv4_ospf_axis_sready),// (output)
    // ---- 入口 2: icmp ----
    .ipv4_icmp_axis_sdata(ipv4_icmp_axis_sdata),// (input)
    .ipv4_icmp_axis_skeep(ipv4_icmp_axis_skeep),// (input)
    .ipv4_icmp_axis_slast(ipv4_icmp_axis_slast),// (input)
    .ipv4_icmp_axis_svalid(ipv4_icmp_axis_svalid),// (input)
    .ipv4_icmp_axis_sready(ipv4_icmp_axis_sready),// (output)
    // ---- 入口 3: udp(优先级最低) ----
    .ipv4_udp_axis_sdata(ipv4_udp_axis_sdata),// (input)
    .ipv4_udp_axis_skeep(ipv4_udp_axis_skeep),// (input)
    .ipv4_udp_axis_slast(ipv4_udp_axis_slast),// (input)
    .ipv4_udp_axis_svalid(ipv4_udp_axis_svalid),// (input)
    .ipv4_udp_axis_sready(ipv4_udp_axis_sready),// (output)
    // ---- 出口 ----
    .ipv4_axis_mdata  (ipv4_tx_axis_mdata),// (output)
    .ipv4_axis_mkeep  (ipv4_tx_axis_mkeep),// (output)
    .ipv4_axis_mlast  (ipv4_tx_axis_mlast),// (output)
    .ipv4_axis_mvalid (ipv4_tx_axis_mvalid),// (output)
    .ipv4_axis_mready (ipv4_tx_axis_mready),// (input)
    // ---- 状态 ----
    .stat_active_port (stat_active_port ),// (output)// 0=other 1=arp 2=ospf 3=icmp 4=udp
    .stat_idle        (stat_idle        ) // (output)
  );


  ipv4_eth_tx u_ipv4_eth_tx (
    .clk              (clk              ),
    .rst              (rst              ),
    .ipv4_axis_sdata  (ipv4_tx_axis_mdata),
    .ipv4_axis_skeep  (ipv4_tx_axis_mkeep),
    .ipv4_axis_slast  (ipv4_tx_axis_mlast),
    .ipv4_axis_svalid (ipv4_tx_axis_mvalid),
    .ipv4_axis_sready (ipv4_tx_axis_mready),
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
    .eth_axis_mready  (eth_tx_axis_mready) 
  );

endmodule
`resetall
