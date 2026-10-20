`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : udp_header_strip.v
// Module Name : udp_header_strip
// Author      : LiXintao
// Date        : 2026-10-19
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : UDP 层接收解封装 —— 剥离 8 字节 UDP 首部, 输出纯净载荷
// 
// ============================================================================
module udp_header_strip#(
  parameter  AXIS_USER_WIDTH= 193
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511:0]        udp_axis_sdata  ,
  input  wire          [                  63:0]        udp_axis_skeep  ,
  input  wire                                          udp_axis_slast  ,
  input  wire                                          udp_axis_svalid ,
  input  wire          [   AXIS_USER_WIDTH-1:0]        udp_axis_susr   ,
  output wire                                          udp_axis_sready ,

  output wire          [                 511:0]        udp_axis_mdata  ,
  output wire          [                  63:0]        udp_axis_mkeep  ,
  output wire                                          udp_axis_mlast  ,
  output wire                                          udp_axis_mvalid ,
  output wire          [   AXIS_USER_WIDTH-1:0]        udp_axis_musr   ,
  input  wire                                          udp_axis_mready ,

  output wire          [                  15:0]        dst_port        ,
  output wire          [                  15:0]        src_port        ,
  output wire          [                  15:0]        udp_len          
);

  reg                  [                 511:0]        udp_axis_sdata_s1;
  reg                  [                  63:0]        udp_axis_skeep_s1;
  reg                                                  udp_axis_slast_s1;
  reg                                                  udp_axis_svalid_s1;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_susr_s1 ;

  reg                  [                 511:0]        udp_axis_mdata_reg;
  reg                  [                  63:0]        udp_axis_mkeep_reg;
  reg                                                  udp_axis_mlast_reg;
  reg                                                  udp_axis_mvalid_reg;
  reg                  [   AXIS_USER_WIDTH-1:0]        udp_axis_musr_reg;

  reg                                                  is_first_beat_s1 ;

  wire                                                 reg_ready         = !udp_axis_mvalid_reg||udp_axis_mready                               ;
  wire                                                 s1_ready          = !udp_axis_mvalid_reg||reg_ready                                     ;
  assign  udp_axis_sready  = !udp_axis_svalid_s1 || s1_ready;

  wire                                                 tail_has_data     = udp_axis_slast_s1 && udp_axis_skeep_s1[8]                           ;
  wire                                                 tail_no_data      = udp_axis_slast_s1 && !udp_axis_skeep_s1[8]                          ;
  wire                                                 s_handshake       = udp_axis_svalid && udp_axis_sready                                  ;
  wire                                                 s1_handshake      = s1_ready && udp_axis_svalid_s1 && (tail_has_data || udp_axis_svalid);
  wire                                                 m_handshake       = udp_axis_mready && udp_axis_mvalid_reg                              ;

  reg                  [                  15:0]        dst_port_reg     ;
  reg                  [                  15:0]        src_port_reg     ;
  reg                  [                  15:0]        udp_len_reg      ;

  // is_first_beat_s1
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat_s1 <= 1'b1;                                     // 复位后第一拍视为首拍
    end
    else begin
      if (s1_handshake) begin
        is_first_beat_s1 <= udp_axis_slast_s1;                      // 本拍是末拍 -> 下一拍即新包首拍
      end
    end
  end

  // dst_port_reg src_port_reg udp_len_reg
  always @(posedge clk) begin
    if (s1_handshake) begin
      if (is_first_beat_s1) begin
        dst_port_reg <= udp_axis_sdata_s1[31:16];
        src_port_reg <= udp_axis_sdata_s1[15:0];
        udp_len_reg <= udp_axis_sdata_s1[47:32];
      end
    end
  end

  // s1 valid
  always @(posedge clk) begin
    if (rst) begin
      udp_axis_svalid_s1 <= 1'b0;
    end
    else begin
      if (s_handshake) begin
        udp_axis_svalid_s1 <= 1'b1;
      end
      else if (s1_handshake) begin
        udp_axis_svalid_s1 <= 1'b0;
      end
    end
  end

  // s1: data keep last usr
  always @(posedge clk) begin
    if (s_handshake) begin
      udp_axis_sdata_s1 <= udp_axis_sdata;
      udp_axis_skeep_s1 <= udp_axis_skeep;
      udp_axis_slast_s1 <= udp_axis_slast;
      udp_axis_susr_s1  <= udp_axis_susr ;
    end
  end

  // reg
  always @(posedge clk) begin
    if (s1_handshake) begin
      if (udp_axis_svalid && udp_axis_slast && !udp_axis_skeep[8]) begin
        udp_axis_mdata_reg <= {udp_axis_sdata[63:0], udp_axis_sdata_s1[511:64]};
        udp_axis_mkeep_reg <= {udp_axis_skeep[7:0],  udp_axis_skeep_s1[63:8] };
        udp_axis_mlast_reg <= 1'b1;
        udp_axis_musr_reg  <= udp_axis_susr_s1;
      end
      else if (tail_has_data) begin
        udp_axis_mdata_reg <= {64'd0, udp_axis_sdata_s1[511:64]};
        udp_axis_mkeep_reg <= {8'd0,  udp_axis_skeep_s1[63:8] };
        udp_axis_mlast_reg <= 1'b1;
        udp_axis_musr_reg  <= udp_axis_susr_s1;
      end
      else begin
        udp_axis_mdata_reg <= {udp_axis_sdata[63:0], udp_axis_sdata_s1[511:64]};
        udp_axis_mkeep_reg <= {udp_axis_skeep[7:0],  udp_axis_skeep_s1[63:8] };
        udp_axis_mlast_reg <= 1'b0;
        udp_axis_musr_reg  <= udp_axis_susr_s1;
      end
    end
  end

  // m valid
  always @(posedge clk) begin
    if (rst) begin
      udp_axis_mvalid_reg <= 1'b0;
    end
    else begin
      if (s1_handshake) begin
        if (tail_no_data) begin
          udp_axis_mvalid_reg <= 1'b0;                              // 末拍无载荷 => 本拍不产生输出
        end
        else begin
          udp_axis_mvalid_reg <= 1'b1;
        end
      end
      else if (m_handshake) begin
        udp_axis_mvalid_reg <= 1'b0;
      end
    end
  end

  assign  udp_axis_mdata   = udp_axis_mdata_reg;
  assign  udp_axis_mkeep   = udp_axis_mkeep_reg;
  assign  udp_axis_mlast   = udp_axis_mlast_reg;
  assign  udp_axis_mvalid  = udp_axis_mvalid_reg;
  assign  udp_axis_musr    = udp_axis_musr_reg;

  assign  dst_port         = dst_port_reg     ;
  assign  src_port         = src_port_reg     ;
  assign  udp_len          = udp_len_reg      ;

endmodule
`resetall
