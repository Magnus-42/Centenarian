`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : udp_ipv4_top.v
// Module Name : udp_ipv4_top
// Author      : LiXintao
// Date        : 2026-10-8
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : udp 链路顶层
//
// ============================================================================

module udp_ipv4_top#(
  parameter  RX_PORT_NUM= 3 ,
  parameter  TX_PORT_NUM= 4 ,
  localparam TX_IDX_WIDTH= (TX_PORT_NUM <= 1) ? 1 : $clog2(TX_PORT_NUM),
  parameter  AXIS_TX_USER_WIDTH= 108, // 每包元数据: prio/ttl/port/ip
  parameter  ARBITER_VAL_WIDTH= 4 ,  // 出口只保留优先级
  parameter  AXIS_RX_USER_WIDTH= 241,// RX 侧 usr 每通道位宽(本层 UDP)
  parameter  IPV4_RX_USR_WIDTH= 97,  // 上游 IPv4 层 usr 每通道位宽
  localparam IPV4_HEAD_USR_WIDTH= 96// IPV4头部解析usr占用的位宽
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [    RX_PORT_NUM*32-1:0]        dst_port_range  ,

  // rx
  input  wire          [                 511:0]        ipv4_udp_axis_sdata,
  input  wire          [                  63:0]        ipv4_udp_axis_skeep,
  input  wire                                          ipv4_udp_axis_slast,
  input  wire                                          ipv4_udp_axis_svalid,
  input  wire          [ IPV4_RX_USR_WIDTH-1:0]        ipv4_udp_axis_susr,
  output wire                                          ipv4_udp_axis_sready,

  output wire          [512*(RX_PORT_NUM+1)-1:0]       udp_axis_mdata  ,
  output wire          [64*(RX_PORT_NUM+1)-1:0]        udp_axis_mkeep  ,
  output wire          [         RX_PORT_NUM:0]        udp_axis_mlast  ,
  output wire          [         RX_PORT_NUM:0]        udp_axis_mvalid ,
  output wire          [AXIS_RX_USER_WIDTH*(RX_PORT_NUM+1)-1:0]udp_axis_musr   ,
  input  wire          [         RX_PORT_NUM:0]        udp_axis_mready ,

  // tx
  input  wire          [   512*TX_PORT_NUM-1:0]        udp_axis_sdata  ,
  input  wire          [    64*TX_PORT_NUM-1:0]        udp_axis_skeep  ,
  input  wire          [       TX_PORT_NUM-1:0]        udp_axis_slast  ,
  input  wire          [       TX_PORT_NUM-1:0]        udp_axis_svalid ,
  input  wire          [AXIS_TX_USER_WIDTH*TX_PORT_NUM-1:0]udp_axis_susr   ,
  output wire          [       TX_PORT_NUM-1:0]        udp_axis_sready ,

  output wire          [                 511:0]        ipv4_axis_mdata ,
  output wire          [                  63:0]        ipv4_axis_mkeep ,
  output wire                                          ipv4_axis_mlast ,
  output wire                                          ipv4_axis_mvalid,
  output wire          [ ARBITER_VAL_WIDTH-1:0]        ipv4_axis_musr  ,
  input  wire                                          ipv4_axis_mready,

  output wire                                          stat_is_df      ,
  
  output wire          [      TX_IDX_WIDTH-1:0]        stat_tx_active_port,
  output wire                                          stat_tx_idle     

);

  wire                 [                 511:0]        udp_pkt_axis_mdata;// rx -> strip: 纯净 UDP 报文
  wire                 [                  63:0]        udp_pkt_axis_mkeep;
  wire                                                 udp_pkt_axis_mlast;
  wire                                                 udp_pkt_axis_mvalid;
  wire                                                 udp_pkt_axis_mready;
  wire                 [IPV4_RX_USR_WIDTH+IPV4_HEAD_USR_WIDTH-1:0]udp_pkt_axis_musr;// 拼上 IP 首部字段(193)

  wire                 [                 511:0]        udp_str_axis_mdata;// strip -> demux: 纯净载荷
  wire                 [                  63:0]        udp_str_axis_mkeep;
  wire                                                 udp_str_axis_mlast;
  wire                                                 udp_str_axis_mvalid;
  wire                 [AXIS_RX_USER_WIDTH-1:0]        udp_str_axis_musr;// 追加 UDP 首部字段(241)
  wire                                                 udp_str_axis_mready;

  wire                 [                   7:0]        protocol         ;
  wire                 [                  15:0]        total_len        ;
  wire                 [                   7:0]        ttl              ;
  wire                 [                  31:0]        src_ip           ;
  wire                 [                  31:0]        dest_ip          ;

  wire                 [                  15:0]        dst_port         ;
  wire                 [                  15:0]        src_port         ;
  wire                 [                  15:0]        udp_len          ;

  udp_ipv4_rx#(
    .AXIS_USER_WIDTH  (IPV4_RX_USR_WIDTH) 
  ) u_udp_ipv4_rx(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .ipv4_axis_sdata  (ipv4_udp_axis_sdata),// (input)
    .ipv4_axis_skeep  (ipv4_udp_axis_skeep),// (input)
    .ipv4_axis_slast  (ipv4_udp_axis_slast),// (input)
    .ipv4_axis_svalid (ipv4_udp_axis_svalid),// (input)
    .ipv4_axis_susr   (ipv4_udp_axis_susr),// (input)
    .ipv4_axis_sready (ipv4_udp_axis_sready),// (output)
    .udp_axis_mdata   (udp_pkt_axis_mdata),// (output)
    .udp_axis_mkeep   (udp_pkt_axis_mkeep),// (output)
    .udp_axis_mlast   (udp_pkt_axis_mlast),// (output)
    .udp_axis_mvalid  (udp_pkt_axis_mvalid),// (output)
    .udp_axis_musr    (udp_pkt_axis_musr[IPV4_RX_USR_WIDTH-1:0]),// (output)
    .udp_axis_mready  (udp_pkt_axis_mready),// (input)
    .protocol         (protocol         ),// (output)
    .total_len        (total_len        ),// (output)
    .ttl              (ttl              ),// (output)
    .src_ip           (src_ip           ),// (output)
    .dest_ip          (dest_ip          ),// (output)
    .stat_is_df       (stat_is_df       ) // (output)// 禁止分片
  );

  assign  udp_pkt_axis_musr[IPV4_RX_USR_WIDTH+:IPV4_HEAD_USR_WIDTH]= {dest_ip,src_ip,ttl,total_len,protocol};

  // --------------------------------------------------------------------------
  // UDP 层解封装: 剥 8B UDP 首部, 首部字段(dst_port/src_port/udp_len)追加到 usr 高位
  // --------------------------------------------------------------------------
  udp_header_strip#(
    .AXIS_USER_WIDTH  (IPV4_RX_USR_WIDTH+IPV4_HEAD_USR_WIDTH) 
  ) u_udp_header_strip(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .udp_axis_sdata   (udp_pkt_axis_mdata),// (input)
    .udp_axis_skeep   (udp_pkt_axis_mkeep),// (input)
    .udp_axis_slast   (udp_pkt_axis_mlast),// (input)
    .udp_axis_svalid  (udp_pkt_axis_mvalid),// (input)
    .udp_axis_susr    (udp_pkt_axis_musr),// (input)
    .udp_axis_sready  (udp_pkt_axis_mready),// (output)
    .udp_axis_mdata   (udp_str_axis_mdata),// (output)
    .udp_axis_mkeep   (udp_str_axis_mkeep),// (output)
    .udp_axis_mlast   (udp_str_axis_mlast),// (output)
    .udp_axis_mvalid  (udp_str_axis_mvalid),// (output)
    .udp_axis_musr    (udp_str_axis_musr[IPV4_RX_USR_WIDTH+IPV4_HEAD_USR_WIDTH-1:0]),// (output)
    .udp_axis_mready  (udp_str_axis_mready),// (input)
    .dst_port         (dst_port         ),
    .src_port         (src_port         ),
    .udp_len          (udp_len          ) 
  );

  assign  udp_str_axis_musr[AXIS_RX_USER_WIDTH-1:IPV4_RX_USR_WIDTH+IPV4_HEAD_USR_WIDTH]= {udp_len,src_port,dst_port};


  udp_ipv4_port_demux#(
    .PORT_NUM         (RX_PORT_NUM      ),
    .AXIS_USER_WIDTH  (AXIS_RX_USER_WIDTH),
    .USR_DPORT_LSB    (AXIS_RX_USER_WIDTH - 48)
  )
  u_udp_ipv4_type_demux(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .dst_port_range   (dst_port_range   ),// (input)
    .udp_axis_sdata   (udp_str_axis_mdata),// (input)
    .udp_axis_skeep   (udp_str_axis_mkeep),// (input)
    .udp_axis_slast   (udp_str_axis_mlast),// (input)
    .udp_axis_svalid  (udp_str_axis_mvalid),// (input)
    .udp_axis_susr    (udp_str_axis_musr),// (input)
    .udp_axis_sready  (udp_str_axis_mready),// (output)
    .udp_axis_mdata   (udp_axis_mdata   ),// (output)
    .udp_axis_mkeep   (udp_axis_mkeep   ),// (output)
    .udp_axis_mlast   (udp_axis_mlast   ),// (output)
    .udp_axis_mvalid  (udp_axis_mvalid  ),// (output)
    .udp_axis_musr    (udp_axis_musr    ),// (output)
    .udp_axis_mready  (udp_axis_mready  ) // (input)
  );


  wire                 [                 511:0]        mux_mdata        ;
  wire                 [                  63:0]        mux_mkeep        ;
  wire                                                 mux_mlast        ;
  wire                                                 mux_mvalid       ;
  wire                 [AXIS_TX_USER_WIDTH-1:0]        mux_musr         ;
  wire                                                 mux_mready       ;

  udp_ipv4_tx_mux#(
    .PORT_NUM         (TX_PORT_NUM      ),
    .AXIS_USER_WIDTH  (AXIS_TX_USER_WIDTH),
    .ARBITER_VAL_WIDTH(ARBITER_VAL_WIDTH) 
  )
  u_udp_ipv4_tx_mux(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    // ---- 入口 ----
    .udp_axis_sdata   (udp_axis_sdata   ),// (input)
    .udp_axis_skeep   (udp_axis_skeep   ),// (input)
    .udp_axis_slast   (udp_axis_slast   ),// (input)
    .udp_axis_svalid  (udp_axis_svalid  ),// (input)
    .udp_axis_susr    (udp_axis_susr    ),// (input)
    .udp_axis_sready  (udp_axis_sready  ),// (output)
    // ---- 出口 ----
    .udp_axis_mdata   (mux_mdata        ),// (output)
    .udp_axis_mkeep   (mux_mkeep        ),// (output)
    .udp_axis_mlast   (mux_mlast        ),// (output)
    .udp_axis_mvalid  (mux_mvalid       ),// (output)
    .udp_axis_musr    (mux_musr         ),// (output)
    .udp_axis_mready  (mux_mready       ),// (input)
    // ---- 状态 ----
    .stat_active_port (stat_tx_active_port),// (output)
    .stat_idle        (stat_tx_idle     ) // (output)
  );

  udp_ipv4_tx#(
    .AXIS_USER_WIDTH  (AXIS_TX_USER_WIDTH),
    .ARBITER_VAL_WIDTH(ARBITER_VAL_WIDTH) 
  ) u_udp_ipv4_tx(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .udp_axis_sdata   (mux_mdata        ),// (input)
    .udp_axis_skeep   (mux_mkeep        ),// (input)
    .udp_axis_slast   (mux_mlast        ),// (input)
    .udp_axis_svalid  (mux_mvalid       ),// (input)
    .udp_axis_susr    (mux_musr         ),// (input)
    .udp_axis_sready  (mux_mready       ),// (output)
    .ipv4_axis_mdata  (ipv4_axis_mdata  ),// (output)
    .ipv4_axis_mkeep  (ipv4_axis_mkeep  ),// (output)
    .ipv4_axis_mlast  (ipv4_axis_mlast  ),// (output)
    .ipv4_axis_mvalid (ipv4_axis_mvalid ),// (output)
    .ipv4_axis_musr   (ipv4_axis_musr   ),// (output)
    .ipv4_axis_mready (ipv4_axis_mready ) // (input)
  );

endmodule
`resetall
