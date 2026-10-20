`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : eth_frame_pad60.v
// Module Name : eth_frame_pad60
// Author      : LiXintao
// Date        : 2026-09-18
// Version     : v1.1
// ----------------------------------------------------------------------------
// Description : 支持流水线设计，将以太帧补齐到最小帧长(默认 60 字节载荷)，
//               FCS(4B) 由 CMAC IP 自行插入，合计 64 字节满足 802.3 最小帧长
// ============================================================================

module eth_frame_pad60#(
  parameter MIN_FRAME_BYTES = 60   // 最小帧长(不含 FCS); 802.3 要求含 FCS 共 64B
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511: 0]       eth_axis_sdata ,
  input  wire          [                  63: 0]       eth_axis_skeep ,
  input  wire                                          eth_axis_slast ,
  input  wire                                          eth_axis_svalid,
  output wire                                          eth_axis_sready,

  output wire          [                 511: 0]       eth_axis_mdata ,
  output wire          [                  63: 0]       eth_axis_mkeep ,
  output wire                                          eth_axis_mlast ,
  output wire                                          eth_axis_mvalid,
  input  wire                                          eth_axis_mready
);

  localparam [                  63: 0]       MIN_KEEP_MASK =
              {{64-MIN_FRAME_BYTES{1'b0}}, {MIN_FRAME_BYTES{1'b1}}};

  reg                                                  is_first_beat      ;
  reg                  [                 511: 0]       eth_axis_mdata_reg  ;
  reg                  [                  63: 0]       eth_axis_mkeep_reg  ;
  reg                                                  eth_axis_mlast_reg  ;
  reg                                                  eth_axis_mvalid_reg  ;
  reg                  [                 511: 0]       eth_axis_mdata_skid  ;
  reg                  [                  63: 0]       eth_axis_mkeep_skid  ;
  reg                                                  eth_axis_mlast_skid  ;
  reg                                                  eth_axis_mvalid_skid  ;

  wire                                                 s_handshake      =eth_axis_svalid&&eth_axis_sready;
  assign  eth_axis_sready = !eth_axis_mvalid_skid;
  wire                                                 m_handshake      =eth_axis_mvalid&&eth_axis_mready;

  wire                                                 reg_can_take     =!eth_axis_mvalid_reg|| eth_axis_mready;
  wire                                                 skid_to_reg      =eth_axis_mvalid_skid&& reg_can_take;
  wire                                                 s_to_skid        =s_handshake&& !reg_can_take;
  wire                                                 s_to_reg         =s_handshake&& reg_can_take;

  wire                 [                 511: 0]       eth_axis_sdata_masked  ;
  genvar g_keep_i;
  generate
      for (g_keep_i = 0; g_keep_i < 64; g_keep_i = g_keep_i+1) begin : gen_byte_mask
  assign  eth_axis_sdata_masked[g_keep_i*8 +: 8]= eth_axis_skeep[g_keep_i] ? eth_axis_sdata[g_keep_i*8 +: 8] : 8'h00;
      end
  endgenerate
  wire                 [                 511: 0]       eth_axis_sdata_take=eth_axis_sdata_masked  ;
  wire                 [                  63: 0]       eth_axis_skeep_pad=eth_axis_skeep[MIN_FRAME_BYTES-1]==1'b0 ? MIN_KEEP_MASK : eth_axis_skeep;
  wire                 [                  63: 0]       eth_axis_skeep_take=is_first_beat?eth_axis_skeep_pad : eth_axis_skeep;

  // eth_axis_mvalid_reg
  always @(posedge clk) begin
    if (rst) begin
      eth_axis_mvalid_reg <= 'd0;
    end
    else begin
      if (s_to_reg || skid_to_reg) begin
        eth_axis_mvalid_reg <= 1'b1;
      end
      else if (m_handshake) begin
        eth_axis_mvalid_reg <= 1'b0;
      end
    end
  end

  // eth_axis_mvalid_skid
  always @(posedge clk) begin
    if (rst) begin
      eth_axis_mvalid_skid <= 'd0;
    end
    else begin
      if (s_to_skid) begin
        eth_axis_mvalid_skid <= 1'b1;
      end
      else if (skid_to_reg) begin
        eth_axis_mvalid_skid <= 1'b0;
      end
    end
  end

  // 输出寄存器: data / keep / last
  always @(posedge clk) begin
    if (skid_to_reg) begin
      eth_axis_mdata_reg <= eth_axis_mdata_skid;
      eth_axis_mkeep_reg <= eth_axis_mkeep_skid;
      eth_axis_mlast_reg <= eth_axis_mlast_skid;
    end
    else if (s_to_reg) begin
      eth_axis_mdata_reg <= eth_axis_sdata_take;
      eth_axis_mkeep_reg <= eth_axis_skeep_take;
      eth_axis_mlast_reg <= eth_axis_slast;
    end
  end

  // skid: data / keep / last
  always @(posedge clk) begin
    if (s_to_skid) begin
      eth_axis_mdata_skid <= eth_axis_sdata_take;
      eth_axis_mkeep_skid <= eth_axis_skeep_take;
      eth_axis_mlast_skid <= eth_axis_slast;
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

  assign  eth_axis_mdata  = eth_axis_mdata_reg;
  assign  eth_axis_mkeep  = eth_axis_mkeep_reg;
  assign  eth_axis_mlast  = eth_axis_mlast_reg;
  assign  eth_axis_mvalid = eth_axis_mvalid_reg;

endmodule
`resetall
