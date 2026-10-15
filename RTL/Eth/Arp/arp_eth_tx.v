`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : arp_eth_tx.v
// Module Name : arp_eth_tx
// Author      : LiXintao
// Date        : 2026-09-14
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 
// 
// ============================================================================

module arp_eth_tx#(
  parameter  AXIS_WIDTH= 512
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  // arp frame input
  input  wire                                          arp_frame_valid ,
  output wire                                          arp_frame_ready ,
  input  wire          [                  47: 0]       eth_dest_mac    ,
  input  wire          [                  47: 0]       eth_src_mac     ,
  input  wire          [                  15: 0]       eth_type        ,
  input  wire          [                  15: 0]       arp_htype       ,
  input  wire          [                  15: 0]       arp_ptype       ,
  input  wire          [                   7: 0]       arp_hlen        ,
  input  wire          [                   7: 0]       arp_plen        ,
  input  wire          [                  15: 0]       arp_oper        ,
  input  wire          [                  47: 0]       arp_sha         ,// sender hardware address
  input  wire          [                  31: 0]       arp_spa         ,// sender protocol address
  input  wire          [                  47: 0]       arp_tha         ,// target hardware address
  input  wire          [                  31: 0]       arp_tpa         ,// target protocol address

  // eth_arp axis out
  output wire          [        AXIS_WIDTH-1: 0]       arp_axis_mdata  ,
  output wire          [      AXIS_WIDTH/8-1: 0]       arp_axis_mkeep  ,
  output wire                                          arp_axis_mvalid ,
  output wire                                          arp_axis_mlast  ,
  input  wire                                          arp_axis_mready  
);

// +0--------------7--------------15----------------23----------------31
// |                Ethernet Address of Destination(0-47)              |
// +                                  +--------------------------------|
// |                                  |                                |
// +----------------------------------+                                |
// |                Ethernet Address of Sender(0-47)                   |
// +----------------------------------|--------------------------------|
// |             Frame Type           |           Hardware Type        |
// +----------------------------------|----------------|---------------|
// |           Protocol Type          | Hardware Length|Protocol Length|
// +----------------------------------|--------------------------------|
// |              OP                  |                                |
// +----------------------------------+                                |
// |                Ethernet Address of Sender(0-47)                   |
// +-------------------------------------------------------------------|
// |                         IP Address of Sender                      |
// +-------------------------------------------------------------------|
// |                Ethernet Address of Destination(0-47)              |
// +                                  +--------------------------------|
// |                                  | IP Address of Destination(0-15)|
// +----------------------------------|--------------------------------|
// | IP Address of Destination(16-31) |
// +----------------------------------|

// ┌─────────────────────────────────┬────────┬──────────────────────────────────────────────────────────────────┐
// │ Ethernet Address of Destination │ 48比特 │ 目的MAC地址。发送ARP请求时，为广播的MAC地址，0xFFFF-FFFF-FFFF。      │
// ├─────────────────────────────────┼────────┼──────────────────────────────────────────────────────────────────┤
// │ Ethernet Address of Sender      │ 48比特 │ 源MAC地址。                                                       │
// │ Frame Type                      │ 16比特 │ 表示后面数据的类型。对于ARP请求或应答来说，该字段的值为0x0806。       │
// │ Hardware Type                   │ 16比特 │ 表示硬件地址的类型。对于以太网，该类型的值为“1”。                     │
// │ Protocol Type                   │ 16比特 │ 表示发送方要映射的协议地址类型。对于IP地址，该值为0x0800。            │
// │ Hardware Length                 │ 8比特  │ 表示硬件地址的长度，单位是字节。对于ARP请求或应答来说，该值为6。       │
// │ Protocol Length                 │ 8比特  │ 表示协议地址的长度，单位是字节。对于ARP请求或应答来说，该值为4。       │
// │ OP                              │ 16比特 │ 操作类型:                                                         │
// │ 1 ARP请求                       │        │                                                                  │
// │ 2 ARP应答                       │        │                                                                  │
// │ 3 RARP请求                      │        │                                                                  │
// │ 4 RARP应答                      │        │                                                                  │
// │ Ethernet Address of Sender      │ 48比特 │ 发送方以太网地址。这个字段和ARP报文首部的源以太网地址字段是重复信息。  │
// │ IP Address of Sender            │ 32比特 │ 发送方的IP地址。                                                  │
// │ Ethernet Address of Destination │ 48比特 │ 接收方的以太网地址。发送ARP请求时，该处填充值为0x00.00.00.00.00.00。 │
// │ IP Address of Destination       │ 32比特 │ 接收方的IP地址。                                                  │
// └─────────────────────────────────┴────────┴──────────────────────────────────────────────────────────────────┘

  reg                  [        AXIS_WIDTH-1: 0]       arp_axis_mdata_reg  ;
  reg                  [      AXIS_WIDTH/8-1: 0]       arp_axis_mkeep_reg  ;
  reg                                                  arp_axis_mvalid_reg  ;
  reg                                                  arp_axis_mlast_reg  ;

  wire                                                 arp_frame_handshake  ;
  wire                                                 m_handshake        ;

  assign  arp_frame_handshake= arp_frame_valid & arp_frame_ready;
  assign  m_handshake      = arp_axis_mready & arp_axis_mvalid;
  assign  arp_frame_ready  = !arp_axis_mvalid_reg || arp_axis_mready;

always @(posedge clk) begin
  if (rst) begin
    arp_axis_mvalid_reg <= 'd0;
    arp_axis_mlast_reg <= 'd0;
  end
  else begin
    if (arp_frame_handshake) begin
      arp_axis_mdata_reg <= {176'd0,arp_tpa,arp_tha,arp_spa,arp_sha,arp_oper,arp_plen,arp_hlen,arp_ptype,arp_htype,eth_type,eth_src_mac,eth_dest_mac};
      arp_axis_mkeep_reg <= 64'h 0fff_ffff_ffff_ffff;
      arp_axis_mvalid_reg <= 1'b1;
      arp_axis_mlast_reg <= 1'b1;
    end
    else if (m_handshake) begin
      arp_axis_mvalid_reg <= 1'b0;
      arp_axis_mlast_reg <= 1'b0;
    end
  end
end

  assign  arp_axis_mdata   = arp_axis_mdata_reg;
  assign  arp_axis_mkeep   = arp_axis_mkeep_reg;
  assign  arp_axis_mvalid  = arp_axis_mvalid_reg;
  assign  arp_axis_mlast   = arp_axis_mlast_reg;

endmodule
`resetall
