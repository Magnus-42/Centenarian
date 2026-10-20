`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : udp_ipv4_tx.v
// Module Name : udp_ipv4_tx
// Author      : LiXintao
// Date        : 2026-10-18
// Version     : v2.1
// ----------------------------------------------------------------------------
// Description : UDP 发送链容器(支持流水线设计
// 
// ============================================================================

module udp_ipv4_tx#(
  parameter  AXIS_USER_WIDTH    = 108,
  parameter  ARBITER_VAL_WIDTH= 4
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511:0]        udp_axis_sdata  ,
  input  wire          [                  63:0]        udp_axis_skeep  ,
  input  wire                                          udp_axis_slast  ,
  input  wire                                          udp_axis_svalid ,
  input  wire          [AXIS_USER_WIDTH-1:0]           udp_axis_susr   ,
  output wire                                          udp_axis_sready ,

  output wire          [                 511:0]        ipv4_axis_mdata ,
  output wire          [                  63:0]        ipv4_axis_mkeep ,
  output wire                                          ipv4_axis_mlast ,
  output wire                                          ipv4_axis_mvalid,
  output wire          [ARBITER_VAL_WIDTH-1:0]       ipv4_axis_musr  ,
  input  wire                                          ipv4_axis_mready
);

  // --------------------------------------------------------------------------
  // 1) 长度 / 校验和
  // --------------------------------------------------------------------------
  wire                 [                 511:0]        lc_m_data        ;
  wire                 [                  63:0]        lc_m_keep        ;
  wire                                                 lc_m_last        ;
  wire                                                 lc_m_valid       ;
  wire                 [AXIS_USER_WIDTH-1:0]           lc_m_usr         ;
  wire                                                 lc_m_ready       ;
  wire                 [                  15:0]        pkt_udp_len      ;
  wire                 [                  15:0]        pkt_udp_cksum    ;

  udp_ipv4_len_checksum#(
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  )
  ) u_udp_ipv4_len_checksum(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .udp_axis_sdata   (udp_axis_sdata   ),// (input)
    .udp_axis_skeep   (udp_axis_skeep   ),// (input)
    .udp_axis_slast   (udp_axis_slast   ),// (input)
    .udp_axis_svalid  (udp_axis_svalid  ),// (input)
    .udp_axis_susr    (udp_axis_susr    ),// (input)
    .udp_axis_sready  (udp_axis_sready  ),// (output)
    .udp_axis_mdata   (lc_m_data        ),// (output)
    .udp_axis_mkeep   (lc_m_keep        ),// (output)
    .udp_axis_mlast   (lc_m_last        ),// (output)
    .udp_axis_mvalid  (lc_m_valid       ),// (output)
    .udp_axis_musr    (lc_m_usr         ),// (output)
    .udp_axis_mready  (lc_m_ready       ),// (input)
    .total_len        (pkt_udp_len      ),// (output)
    .head_checksum    (pkt_udp_cksum    ) // (output)
  );

  // --------------------------------------------------------------------------
  // 2) 插 8B UDP 头  ->  直连 IPv4 头模块
  // --------------------------------------------------------------------------
  wire                 [                 511:0]        uh_m_data        ;
  wire                 [                  63:0]        uh_m_keep        ;
  wire                                                 uh_m_last        ;
  wire                                                 uh_m_valid       ;
  wire                 [AXIS_USER_WIDTH-1:0]           uh_m_usr         ;
  wire                                                 uh_m_ready       ;

  udp_header_add#(
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  )
  ) u_udp_header_add(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .udp_axis_sdata   (lc_m_data        ),// (input)
    .udp_axis_skeep   (lc_m_keep        ),// (input)
    .udp_axis_slast   (lc_m_last        ),// (input)
    .udp_axis_svalid  (lc_m_valid       ),// (input)
    .udp_axis_susr    (lc_m_usr         ),// (input)
    .udp_axis_sready  (lc_m_ready       ),// (output)
    .pkt_total_len    (pkt_udp_len      ),// (input)
    .pkt_head_checksum(pkt_udp_cksum    ),// (input)
    .udp_axis_mdata   (uh_m_data        ),// (output)
    .udp_axis_mkeep   (uh_m_keep        ),// (output)
    .udp_axis_mlast   (uh_m_last        ),// (output)
    .udp_axis_mvalid  (uh_m_valid       ),// (output)
    .udp_axis_musr    (uh_m_usr         ),// (output)
    .udp_axis_mready  (uh_m_ready       ) // (input)
  );

  // --------------------------------------------------------------------------
  // 3) 插 20B IPv4 头  ->  直连输出端口
  // --------------------------------------------------------------------------
  wire                 [                 511:0]        ih_m_data        ;
  wire                 [                  63:0]        ih_m_keep        ;
  wire                                                 ih_m_last        ;
  wire                                                 ih_m_valid       ;
  wire                 [AXIS_USER_WIDTH-1:0]           ih_m_usr         ;
  wire                                                 ih_m_ready       ;

  udp_ipv4_header_add#(
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH  )
  ) u_udp_ipv4_header_add(
    .clk              (clk              ),// (input)
    .rst              (rst              ),// (input)
    .udp_axis_sdata   (uh_m_data        ),// (input)
    .udp_axis_skeep   (uh_m_keep        ),// (input)
    .udp_axis_slast   (uh_m_last        ),// (input)
    .udp_axis_svalid  (uh_m_valid       ),// (input)
    .udp_axis_susr    (uh_m_usr         ),// (input)
    .udp_axis_sready  (uh_m_ready       ),// (output)
    .ipv4_axis_mdata  (ih_m_data        ),// (output)
    .ipv4_axis_mkeep  (ih_m_keep        ),// (output)
    .ipv4_axis_mlast  (ih_m_last        ),// (output)
    .ipv4_axis_mvalid (ih_m_valid       ),// (output)
    .ipv4_axis_musr   (ih_m_usr         ),// (output)
    .ipv4_axis_mready (ih_m_ready       ) // (input)
  );

  // --------------------------------------------------------------------------
  // 4) 输出直连: 无 skid, 仅做 usr 收窄(IPv4 头已建好, 只保留优先级)
  // --------------------------------------------------------------------------
  assign ipv4_axis_mdata  = ih_m_data;
  assign ipv4_axis_mkeep  = ih_m_keep;
  assign ipv4_axis_mlast  = ih_m_last;
  assign ipv4_axis_mvalid = ih_m_valid;
  assign ipv4_axis_musr   = ih_m_usr[ARBITER_VAL_WIDTH-1:0];

  assign ih_m_ready       = ipv4_axis_mready;

endmodule
`resetall
