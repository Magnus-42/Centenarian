`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : eth_type_demux.v
// Module Name : eth_type_demux
// Author      : LiXintao
// Date        : 2026-09-19
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计，将数据分为eth_ipv4,eth_arp和其他数据
// 
// ============================================================================

module eth_type_demux(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511: 0]       eth_axis_sdata  ,
  input  wire          [                  63: 0]       eth_axis_skeep  ,
  input  wire                                          eth_axis_slast  ,
  input  wire                                          eth_axis_svalid ,
  output wire                                          eth_axis_sready ,

  output wire          [                 511: 0]       eth_ipv4_axis_mdata ,
  output wire          [                  63: 0]       eth_ipv4_axis_mkeep ,
  output wire                                          eth_ipv4_axis_mlast ,
  output wire                                          eth_ipv4_axis_mvalid,
  input  wire                                          eth_ipv4_axis_mready,

  output wire          [                 511: 0]       eth_arp_axis_mdata  ,
  output wire          [                  63: 0]       eth_arp_axis_mkeep  ,
  output wire                                          eth_arp_axis_mlast  ,
  output wire                                          eth_arp_axis_mvalid ,
  input  wire                                          eth_arp_axis_mready ,

  output wire          [                 511: 0]       eth_other_axis_mdata  ,
  output wire          [                  63: 0]       eth_other_axis_mkeep  ,
  output wire                                          eth_other_axis_mlast  ,
  output wire                                          eth_other_axis_mvalid ,
  input  wire                                          eth_other_axis_mready 
);

  reg                                                  is_first_beat      ;

  // 第一期，计算这一拍的类型
  reg          [                 511: 0]       eth_axis_sdata_s1;
  reg          [                  63: 0]       eth_axis_skeep_s1;
  reg                                          eth_axis_slast_s1;
  reg                                          eth_axis_svalid_s1;

  reg          [                 511: 0]       eth_ipv4_axis_mdata_reg;
  reg          [                  63: 0]       eth_ipv4_axis_mkeep_reg;
  reg                                          eth_ipv4_axis_mlast_reg;
  reg                                          eth_ipv4_axis_mvalid_reg;

  reg          [                 511: 0]       eth_arp_axis_mdata_reg;
  reg          [                  63: 0]       eth_arp_axis_mkeep_reg;
  reg                                          eth_arp_axis_mlast_reg;
  reg                                          eth_arp_axis_mvalid_reg;

  reg          [                 511: 0]       eth_other_axis_mdata_reg;
  reg          [                  63: 0]       eth_other_axis_mkeep_reg;
  reg                                          eth_other_axis_mlast_reg;
  reg                                          eth_other_axis_mvalid_reg;

  reg [2:0] sel_type_one_hot_s1; // 0:eth_ipv4 1:eth_arp 2:eth_other

  wire                                                 s_handshake      =eth_axis_svalid&&eth_axis_sready;
  wire s1_ready = (sel_type_one_hot_s1[0] && (!eth_ipv4_axis_mvalid_reg || eth_ipv4_axis_mready)) ||
                  (sel_type_one_hot_s1[1] && (!eth_arp_axis_mvalid_reg || eth_arp_axis_mready)) ||
                  (sel_type_one_hot_s1[2] && (!eth_other_axis_mvalid_reg || eth_other_axis_mready));
  wire s1_handshake = s1_ready && eth_axis_svalid_s1;
  assign eth_axis_sready = !eth_axis_svalid_s1 || s1_ready;
  wire eth_ipv4_m_handshake = eth_ipv4_axis_mvalid_reg && eth_ipv4_axis_mready;
  wire eth_arp_m_handshake = eth_arp_axis_mvalid_reg && eth_arp_axis_mready;
  wire eth_other_m_handshake = eth_other_axis_mvalid_reg && eth_other_axis_mready;
  
  // reg: data keep last
  always @(posedge clk) begin
    if (s1_handshake) begin
      if (sel_type_one_hot_s1[0]) begin
        eth_ipv4_axis_mdata_reg <= eth_axis_sdata_s1;
        eth_ipv4_axis_mkeep_reg <= eth_axis_skeep_s1;
        eth_ipv4_axis_mlast_reg <= eth_axis_slast_s1;
      end
      else if (sel_type_one_hot_s1[1]) begin
        eth_arp_axis_mdata_reg <= eth_axis_sdata_s1;
        eth_arp_axis_mkeep_reg <= eth_axis_skeep_s1;
        eth_arp_axis_mlast_reg <= eth_axis_slast_s1;
      end
      else if (sel_type_one_hot_s1[2]) begin
        eth_other_axis_mdata_reg <= eth_axis_sdata_s1;
        eth_other_axis_mkeep_reg <= eth_axis_skeep_s1;
        eth_other_axis_mlast_reg <= eth_axis_slast_s1;
      end
    end
  end

  // reg: valid
  always @(posedge clk) begin
    if (rst) begin
      eth_ipv4_axis_mvalid_reg <= 1'd0;
      eth_arp_axis_mvalid_reg <= 1'd0;
      eth_other_axis_mvalid_reg <= 1'd0;
    end
    else begin
      if (s1_handshake && sel_type_one_hot_s1[0]) begin
        eth_ipv4_axis_mvalid_reg <= 1'b1;
      end
      else if (eth_ipv4_m_handshake) begin
        eth_ipv4_axis_mvalid_reg <= 1'b0;
      end

      if (s1_handshake && sel_type_one_hot_s1[1]) begin
        eth_arp_axis_mvalid_reg <= 1'b1;
      end
      else if (eth_arp_m_handshake) begin
        eth_arp_axis_mvalid_reg <= 1'b0;
      end

      if (s1_handshake && sel_type_one_hot_s1[2]) begin
        eth_other_axis_mvalid_reg <= 1'b1;
      end
      else if (eth_other_m_handshake) begin
        eth_other_axis_mvalid_reg <= 1'b0;
      end
    end
  end

  // s1: data keep last
  always @(posedge clk) begin
    if (s_handshake) begin
      eth_axis_sdata_s1 <= eth_axis_sdata;
      eth_axis_skeep_s1 <= eth_axis_skeep;
      eth_axis_slast_s1 <= eth_axis_slast;
    end
  end

  // s1: valid
  always @(posedge clk) begin
    if (rst) begin
      eth_axis_svalid_s1 <= 1'd0;
    end
    else begin
      if (s_handshake) begin
        eth_axis_svalid_s1 <= 1'b1;
      end
      else if (s1_handshake) begin
        eth_axis_svalid_s1 <= 1'b0;
      end
    end
  end

  // sel_type_one_hot_s1
  always @(posedge clk) begin
    if (rst) begin
      sel_type_one_hot_s1 <= 3'd0;
    end
    else begin
      if (s_handshake && is_first_beat) begin
        if (eth_axis_sdata[96 +: 16] == 16'h0008) begin
          sel_type_one_hot_s1 <= 3'b001;
        end
        else if (eth_axis_sdata[96 +: 16] == 16'h0608) begin
          sel_type_one_hot_s1 <= 3'b010;
        end
        else begin
          sel_type_one_hot_s1 <= 3'b100;
        end
      end
    end
  end

  // is_first_beat
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;                                        // 复位后第一拍视为首拍
    end
    else begin
      if (s_handshake) begin
        is_first_beat <= eth_axis_slast;                           // 本拍收的是本包最后一拍 -> 下一拍即新包首拍
      end
    end
  end

  assign  eth_ipv4_axis_mdata  = eth_ipv4_axis_mdata_reg ;
  assign  eth_ipv4_axis_mkeep  = eth_ipv4_axis_mkeep_reg ;
  assign  eth_ipv4_axis_mlast  = eth_ipv4_axis_mlast_reg ;
  assign  eth_ipv4_axis_mvalid = eth_ipv4_axis_mvalid_reg;
  assign  eth_arp_axis_mdata   = eth_arp_axis_mdata_reg  ;
  assign  eth_arp_axis_mkeep   = eth_arp_axis_mkeep_reg  ;
  assign  eth_arp_axis_mlast   = eth_arp_axis_mlast_reg  ;
  assign  eth_arp_axis_mvalid  = eth_arp_axis_mvalid_reg ;
  assign  eth_other_axis_mdata  = eth_other_axis_mdata_reg ;
  assign  eth_other_axis_mkeep  = eth_other_axis_mkeep_reg ;
  assign  eth_other_axis_mlast  = eth_other_axis_mlast_reg ;
  assign  eth_other_axis_mvalid = eth_other_axis_mvalid_reg;

endmodule
`resetall
