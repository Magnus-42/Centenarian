`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv4_mac_add.v
// Module Name : ipv4_mac_add
// Author      : LiXintao
// Date        : 2026-09-18
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计，添加头部信息
//              1. 仅支持标准以太网最小帧长，故第一拍能直接插入完成
// 
// ============================================================================

module ipv4_mac_add#(
  parameter  AXIS_USER_WIDTH= 4 
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511:0]        ipv4_axis_sdata ,
  input  wire          [                  63:0]        ipv4_axis_skeep ,
  input  wire                                          ipv4_axis_slast ,
  input  wire                                          ipv4_axis_svalid,
  input  wire          [   AXIS_USER_WIDTH-1:0]        ipv4_axis_susr  ,
  output wire                                          ipv4_axis_sready,

  input  wire          [                  47:0]        dst_mac         ,
  input  wire          [                  47:0]        src_mac         ,

  output wire          [                 511:0]        eth_axis_mdata  ,
  output wire          [                  63:0]        eth_axis_mkeep  ,
  output wire                                          eth_axis_mlast  ,
  output wire                                          eth_axis_mvalid ,
  output wire          [   AXIS_USER_WIDTH-1:0]        eth_axis_musr   ,
  input  wire                                          eth_axis_mready  
);

  localparam ETH_HDR_BITS= 112;
  
  reg                  [                 511:0]        ipv4_axis_sdata_d0;
  reg                  [                  63:0]        ipv4_axis_skeep_d0;
  reg                                                  ipv4_axis_slast_d0;
  reg                                                  ipv4_axis_svalid_d0;
  reg                  [   AXIS_USER_WIDTH-1:0]        ipv4_axis_susr_d0;

  reg                  [                  47:0]        dst_mac_d0       ;
  reg                  [                  47:0]        src_mac_d0       ;

  reg                                                  is_first_beat    ;


  reg                  [      ETH_HDR_BITS-1:0]        data_remain_reg  ;
  reg                  [    ETH_HDR_BITS/8-1:0]        keep_remain_reg  ;
  reg                  [   AXIS_USER_WIDTH-1:0]        usr_remain_reg   ;



  reg                  [                 511:0]        eth_axis_mdata_reg;
  reg                  [                  63:0]        eth_axis_mkeep_reg;
  reg                                                  eth_axis_mlast_reg;
  reg                                                  eth_axis_mvalid_reg;
  reg                  [   AXIS_USER_WIDTH-1:0]        eth_axis_musr_reg;

  reg                                                  is_insert_beat   , is_insert_beat_d0;// 末拍高 14 字节含有效数据 ⇒ 还需补发一个插入拍

  
  wire                                                 out_reg_free      = !eth_axis_mvalid_reg || eth_axis_mready                        ;
  wire                                                 insert_en         = is_insert_beat_d0 && out_reg_free                              ;
  wire                                                 ipv4_axis_sready_d0 = (!eth_axis_mvalid_reg || eth_axis_mready) && !is_insert_beat_d0;
  wire                                                 m_handshake       = eth_axis_mvalid_reg && eth_axis_mready                         ;
  wire                                                 s_handshake       = ipv4_axis_sready && ipv4_axis_svalid                           ;
  wire                                                 d0_handshake      = ipv4_axis_sready_d0 && ipv4_axis_svalid_d0                     ;
  assign  ipv4_axis_sready = (!ipv4_axis_svalid_d0 || ipv4_axis_sready_d0) && !is_insert_beat;

  always @(posedge clk) begin
    if (s_handshake) begin
      ipv4_axis_sdata_d0 <= ipv4_axis_sdata;
      ipv4_axis_skeep_d0 <= ipv4_axis_skeep;
      ipv4_axis_slast_d0 <= ipv4_axis_slast;
      ipv4_axis_susr_d0 <= ipv4_axis_susr;
      dst_mac_d0 <= dst_mac;
      src_mac_d0 <= src_mac;
    end
  end
    
  always @(posedge clk) begin
    if (rst)               ipv4_axis_svalid_d0 <= 1'b0;
    else if (s_handshake)  ipv4_axis_svalid_d0 <= 1'b1;
    else if (d0_handshake) ipv4_axis_svalid_d0 <= 1'b0;
  end


  // is_insert_beat
  always @(posedge clk) begin
    if (rst) begin
      is_insert_beat <= 'd0;
    end
    else begin
      if (s_handshake) begin
        is_insert_beat <= ipv4_axis_slast ? ipv4_axis_skeep[63-:ETH_HDR_BITS/8] != 'd0 : 'd0;
      end
      else if (d0_handshake) begin
        is_insert_beat <= 'd0;
      end
    end
  end

  // is_insert_beat_d0
  always @(posedge clk) begin
    if (rst) begin
      is_insert_beat_d0 <= 'd0;
    end
    else begin
      if (d0_handshake) begin
        is_insert_beat_d0 <= is_insert_beat;
      end
      else if (insert_en) begin
        is_insert_beat_d0 <= 'd0;
      end
    end
  end

  // is_first_beat
  always @(posedge clk) begin
    if (rst) begin
      is_first_beat <= 1'b1;                                        // 复位后第一拍视为首拍
    end
    else begin
      if (d0_handshake) begin
        is_first_beat <= ipv4_axis_slast_d0;                        // 本拍收的是本包最后一拍 -> 下一拍即新包首拍
      end
    end
  end

  // data_remain_reg
  always @(posedge clk) begin
    if (d0_handshake) begin
      data_remain_reg <= ipv4_axis_sdata_d0[511-:ETH_HDR_BITS];
    end
  end

  // keep_remain_reg
  always @(posedge clk) begin
    if (d0_handshake) begin
      keep_remain_reg <= ipv4_axis_skeep_d0[63-:ETH_HDR_BITS/8];
    end
  end

  // usr_remain_reg (帧内保持值; insert 拍沿用)
  always @(posedge clk) begin
    if (d0_handshake) begin
      usr_remain_reg <= ipv4_axis_susr_d0;
    end
  end

  // eth_axis_mdata_reg
  always @(posedge clk) begin
    if (insert_en) begin
      eth_axis_mdata_reg <= {{(512-ETH_HDR_BITS){1'b0}},data_remain_reg};
    end
    else if (d0_handshake && is_first_beat) begin
      eth_axis_mdata_reg <= {ipv4_axis_sdata_d0[511-ETH_HDR_BITS:0],16'h0008,src_mac_d0,dst_mac_d0};
    end
    else if (d0_handshake) begin
      eth_axis_mdata_reg <= {ipv4_axis_sdata_d0[511-ETH_HDR_BITS:0],data_remain_reg};
    end
  end

  // eth_axis_musr_reg
  always @(posedge clk) begin
    if (insert_en) begin
      eth_axis_musr_reg <= usr_remain_reg;
    end
    else if (d0_handshake) begin
      eth_axis_musr_reg <= ipv4_axis_susr_d0;
    end
  end

  // eth_axis_mkeep_reg
  always @(posedge clk) begin
    if (insert_en) begin
      eth_axis_mkeep_reg <= {{(64-ETH_HDR_BITS/8){1'b0}},keep_remain_reg};
    end
    else if (d0_handshake && is_first_beat) begin
      eth_axis_mkeep_reg <= {ipv4_axis_skeep_d0[63-ETH_HDR_BITS/8:0],14'b1111_1111_1111_11};
    end
    else if (d0_handshake) begin
      eth_axis_mkeep_reg <= {ipv4_axis_skeep_d0[63-ETH_HDR_BITS/8:0],keep_remain_reg};
    end
  end

  // eth_axis_mlast_reg
  always @(posedge clk) begin
    if (rst) begin
      eth_axis_mlast_reg <= 'd0;
    end
    else begin
      if (insert_en) begin
        eth_axis_mlast_reg <= 1'b1;
      end
      else if (d0_handshake && !is_insert_beat && ipv4_axis_slast_d0) begin
        eth_axis_mlast_reg <= 1'b1;
      end
      else if(m_handshake) begin
        eth_axis_mlast_reg <= 1'b0;
      end
    end
  end

  // eth_axis_mvalid_reg
  always @(posedge clk) begin
    if (rst) begin
      eth_axis_mvalid_reg <= 'd0;
    end
    else begin
      if (d0_handshake || is_insert_beat_d0) begin
        eth_axis_mvalid_reg <= 1'b1;
      end
      else if (m_handshake) begin
        eth_axis_mvalid_reg <= 1'b0;
      end
    end
  end

  assign  eth_axis_mdata   = eth_axis_mdata_reg;
  assign  eth_axis_mkeep   = eth_axis_mkeep_reg;
  assign  eth_axis_mlast   = eth_axis_mlast_reg;
  assign  eth_axis_mvalid  = eth_axis_mvalid_reg;
  assign  eth_axis_musr    = eth_axis_musr_reg;

endmodule
`resetall
