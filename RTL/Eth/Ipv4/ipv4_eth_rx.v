`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv4_eth_rx.v
// Module Name : ipv4_eth_rx
// Author      : LiXintao
// Date        : 2026-09-19
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计，剥离mac头部
// 
// ============================================================================

module ipv4_eth_rx(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511: 0]       eth_ipv4_axis_sdata,
  input  wire          [                  63: 0]       eth_ipv4_axis_skeep,
  input  wire                                          eth_ipv4_axis_slast,
  input  wire                                          eth_ipv4_axis_svalid,
  output wire                                          eth_ipv4_axis_sready,

  output wire          [                 511: 0]       ipv4_axis_mdata ,
  output wire          [                  63: 0]       ipv4_axis_mkeep ,
  output wire                                          ipv4_axis_mlast ,
  output wire                                          ipv4_axis_mvalid,
  input  wire                                          ipv4_axis_mready,

  output wire [47:0] dest_mac,
  output wire [47:0] src_mac
);
  reg          [                 511: 0]       eth_ipv4_axis_sdata_s1;
  reg          [                  63: 0]       eth_ipv4_axis_skeep_s1;
  reg                                          eth_ipv4_axis_slast_s1;
  reg                                          eth_ipv4_axis_svalid_s1;

  reg         [                 511: 0]       ipv4_axis_mdata_reg;
  reg         [                  63: 0]       ipv4_axis_mkeep_reg;
  reg                                         ipv4_axis_mlast_reg;
  reg                                         ipv4_axis_mvalid_reg;
  reg [47:0] dest_mac_reg;
  reg [47:0] src_mac_reg;
  
  reg                                                  is_first_beat, is_first_beat_s1      ;

  wire reg_ready = !ipv4_axis_mvalid_reg || ipv4_axis_mready;
  wire s1_ready = !ipv4_axis_mvalid_reg || reg_ready;
  assign eth_ipv4_axis_sready = !eth_ipv4_axis_svalid_s1 || s1_ready;
  
  wire tail_has_data = eth_ipv4_axis_slast_s1 && (eth_ipv4_axis_skeep_s1[14] != 1'b0);
  wire tail_no_data  = eth_ipv4_axis_slast_s1 && (eth_ipv4_axis_skeep_s1[14] == 1'b0);
  wire s1_handshake = s1_ready && eth_ipv4_axis_svalid_s1 && (tail_has_data || eth_ipv4_axis_svalid);
  wire s_handshake      =eth_ipv4_axis_sready&&eth_ipv4_axis_svalid;
  wire m_handshake = ipv4_axis_mvalid_reg && ipv4_axis_mready;  

  // s1: data keep last
  always @(posedge clk) begin
    if (s_handshake) begin
      eth_ipv4_axis_sdata_s1 <= eth_ipv4_axis_sdata;
      eth_ipv4_axis_skeep_s1 <= eth_ipv4_axis_skeep;
      eth_ipv4_axis_slast_s1 <= eth_ipv4_axis_slast;
    end
  end

  // s1: valid
  always @(posedge clk) begin
    if (rst) begin
      eth_ipv4_axis_svalid_s1 <= 1'b0;
    end
    else begin
      if (s_handshake) begin
        eth_ipv4_axis_svalid_s1 <= 1'b1;
      end
      else if (s1_handshake) begin
        eth_ipv4_axis_svalid_s1 <= 1'b0;
      end
    end
  end

  // reg: data keep last
  always @(posedge clk) begin
    if (s1_handshake) begin
      if (eth_ipv4_axis_svalid && eth_ipv4_axis_slast && eth_ipv4_axis_skeep[14] == 0) begin // 提前最后一拍
        ipv4_axis_mdata_reg <= {eth_ipv4_axis_sdata[111:0],eth_ipv4_axis_sdata_s1[511:112]};
        ipv4_axis_mkeep_reg <= {eth_ipv4_axis_skeep[13:0],eth_ipv4_axis_skeep_s1[63:14]};
        ipv4_axis_mlast_reg <= 1'b1;
      end
      else if(tail_has_data) begin // 最后一拍
        ipv4_axis_mdata_reg <= {112'd0,eth_ipv4_axis_sdata_s1[511:112]};
        ipv4_axis_mkeep_reg <= {14'd0,eth_ipv4_axis_skeep_s1[63:14]};
        ipv4_axis_mlast_reg <= 1'b1;
      end
      else begin
        ipv4_axis_mdata_reg <= {eth_ipv4_axis_sdata[111:0],eth_ipv4_axis_sdata_s1[511:112]};
        ipv4_axis_mkeep_reg <= {eth_ipv4_axis_skeep[13:0],eth_ipv4_axis_skeep_s1[63:14]};
        ipv4_axis_mlast_reg <= 1'b0;
      end
    end
  end

  // reg: valid
  always @(posedge clk) begin
    if (rst) begin
      ipv4_axis_mvalid_reg <= 1'b0;
    end
    else begin
      if (s1_handshake) begin
        if (tail_no_data) begin
          ipv4_axis_mvalid_reg <= 1'b0; // 末拍无载荷 => 本拍不产生输出
        end
        else begin
          ipv4_axis_mvalid_reg <= 1'b1;
        end
      end
      else if (m_handshake) begin
        ipv4_axis_mvalid_reg <= 1'b0;
      end
    end
  end

  // dest_mac_reg src_mac_reg
  always @(posedge clk) begin
    if (s1_handshake) begin
      if (is_first_beat_s1) begin // 提前最后一拍
        dest_mac_reg <= eth_ipv4_axis_sdata_s1[47:0];
        src_mac_reg <= eth_ipv4_axis_sdata_s1[95:48];
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
        is_first_beat <= eth_ipv4_axis_slast;                            // 本拍收的是本包最后一拍 -> 下一拍即新包首拍
      end
    end
  end

  // is_first_beat_s1
  always @(posedge clk) begin
    if (s_handshake) begin
      is_first_beat_s1 <= is_first_beat;
    end
  end

  assign dest_mac = dest_mac_reg;
  assign src_mac = src_mac_reg;
  assign ipv4_axis_mdata  = ipv4_axis_mdata_reg;
  assign ipv4_axis_mkeep  = ipv4_axis_mkeep_reg;
  assign ipv4_axis_mlast  = ipv4_axis_mlast_reg;
  assign ipv4_axis_mvalid = ipv4_axis_mvalid_reg;

endmodule
`resetall
