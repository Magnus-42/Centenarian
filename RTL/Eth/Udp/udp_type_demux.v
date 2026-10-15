`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : udp_type_demux.v
// Module Name : udp_type_demux
// Author      : LiXintao
// Date        : 2026-09-29
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计，根据端口将数据分流
// NOTE        : 1. 端口 i(i<PORT_NUM)的匹配区间 = DST_PORT_RANGE 第 i 个 word：
//                 [15:0]下界、[31:16]上界；重叠取索引小者，空洞落末路
//              2. PORT_NUM ≥ 1
// 
// ============================================================================

module udp_type_demux#(
  parameter  PORT_NUM= 3 , // 最小配置为1
  localparam PORT_NUM_EFF = (PORT_NUM > 0) ? PORT_NUM : 1,  // 字典占位项数(>=1；PORT_NUM=0 时为 1 项占位，内容不被读取)
  parameter  [PORT_NUM_EFF*32-1:0]        DST_PORT_RANGE= {32'h00080002,32'h00010001,32'h00000000} // 端口禁止重叠
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511:0]        udp_axis_sdata  ,
  input  wire          [                  63:0]        udp_axis_skeep  ,
  input  wire                                          udp_axis_slast  ,
  input  wire                                          udp_axis_svalid ,
  input  wire          [                 192:0]        udp_axis_susr   ,
  output wire                                          udp_axis_sready ,

  output wire          [  512*(PORT_NUM+1)-1:0]        udp_axis_mdata  ,
  output wire          [   64*(PORT_NUM+1)-1:0]        udp_axis_mkeep  ,
  output wire          [            PORT_NUM:0]        udp_axis_mlast  ,
  output wire          [            PORT_NUM:0]        udp_axis_mvalid ,
  output wire          [  193*(PORT_NUM+1)-1:0]        udp_axis_musr   ,
  input  wire          [            PORT_NUM:0]        udp_axis_mready  
);

  reg                                                  is_first_beat    ;

  reg                  [                 511:0]        udp_axis_sdata_s1;
  reg                  [                  63:0]        udp_axis_skeep_s1;
  reg                                                  udp_axis_slast_s1;
  reg                                                  udp_axis_svalid_s1;
  reg                  [                 192:0]        udp_axis_susr_s1 ;

  reg                  [  512*(PORT_NUM+1)-1:0]        udp_axis_mdata_reg;
  reg                  [   64*(PORT_NUM+1)-1:0]        udp_axis_mkeep_reg;
  reg                  [            PORT_NUM:0]        udp_axis_mlast_reg;
  reg                  [            PORT_NUM:0]        udp_axis_mvalid_reg;
  reg                  [  193*(PORT_NUM+1)-1:0]        udp_axis_musr_reg;

  reg                  [  512*(PORT_NUM+1)-1:0]        udp_axis_mdata_skid;
  reg                  [   64*(PORT_NUM+1)-1:0]        udp_axis_mkeep_skid;
  reg                  [            PORT_NUM:0]        udp_axis_mlast_skid;
  reg                  [            PORT_NUM:0]        udp_axis_mvalid_skid;
  reg                  [  193*(PORT_NUM+1)-1:0]        udp_axis_musr_skid;

  wire                 [            PORT_NUM:0]        port_compare     ;
  wire                 [            PORT_NUM:0]        port_hit         ;

  reg                  [            PORT_NUM:0]        sel_type_one_hot_s1;
  wire                                                 s_handshake       = udp_axis_svalid&&udp_axis_sready                                ;
  wire                                                 s1_ready          = |(sel_type_one_hot_s1&(~udp_axis_mvalid_skid))                  ;
  wire                                                 s1_handshake      = s1_ready&&udp_axis_svalid_s1                                    ;
  assign  udp_axis_sready  = !udp_axis_svalid_s1 || s1_ready;

  // s1: data keep last
  always @(posedge clk) begin
    if (s_handshake) begin
      udp_axis_sdata_s1 <= udp_axis_sdata;
      udp_axis_skeep_s1 <= udp_axis_skeep;
      udp_axis_slast_s1 <= udp_axis_slast;
      udp_axis_susr_s1  <= udp_axis_susr;
    end
  end
  // s1: valid
  always @(posedge clk) begin
    if (rst) begin
      udp_axis_svalid_s1 <= 1'd0;
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

  genvar port_index;
  generate
    for (port_index = 0; port_index <= PORT_NUM; port_index=port_index+1) begin:gen_port
  wire                                                 m_handshake   = udp_axis_mvalid_reg[port_index]&udp_axis_mready[port_index]     ;
  wire                                                 reg_can_take  = m_handshake||!udp_axis_mvalid_reg[port_index]               ;
  wire                                                 skid_to_reg   = udp_axis_mvalid_skid[port_index]&&reg_can_take              ;
  wire                                                 s1_to_skid    = s1_handshake&&sel_type_one_hot_s1[port_index]&&!reg_can_take;
  wire                                                 s1_to_reg     = s1_handshake&&sel_type_one_hot_s1[port_index]&&reg_can_take ;

      if (port_index == PORT_NUM) begin : gen_default_port
  assign  port_hit[port_index]= 1'b0             ;
        // other(兜底)档命中逻辑：PORT_NUM=0 ⇒ 无用户档，所有帧全部落 other
        if (PORT_NUM == 0) begin:gen_no_user_port
  assign  port_compare[port_index]= 1'b1 ;
        end
        else begin:gen_has_user_port
  assign  port_compare[port_index]= ~(|port_hit[PORT_NUM-1:0]) ;
        end
      end
      else begin : gen_range_port
  wire                                                 is_low_port_bound = DST_PORT_RANGE[port_index*32+:16]<=udp_axis_sdata[16+:16]       ;
  wire                                                 is_high_port_bound = DST_PORT_RANGE[port_index*32+16+:16]>=udp_axis_sdata[16+:16]    ;
  assign  port_hit[port_index]= is_low_port_bound && is_high_port_bound;
  assign  port_compare[port_index]= port_hit[port_index] && ~(|port_index == 0 ? 1'b0 : port_hit[port_index-1:0]);
      end

      // udp
      always @(posedge clk) begin
        if (rst) begin
          udp_axis_mvalid_reg[port_index] <= 'd0;
          udp_axis_mvalid_skid[port_index] <= 'd0;
        end
        else begin
          if (skid_to_reg || s1_to_reg) begin
            udp_axis_mvalid_reg[port_index] <= 1'b1;
          end
          else if (m_handshake) begin
            udp_axis_mvalid_reg[port_index] <= 1'b0;
          end

          if (s1_to_skid) begin
            udp_axis_mvalid_skid[port_index] <= 1'b1;
          end
          else if (skid_to_reg) begin
            udp_axis_mvalid_skid[port_index] <= 1'b0;
          end
        end
      end

      always @(posedge clk) begin
        if (skid_to_reg) begin
          udp_axis_mdata_reg[port_index*512+:512] <= udp_axis_mdata_skid[port_index*512+:512];
          udp_axis_mkeep_reg[port_index*64+:64] <= udp_axis_mkeep_skid[port_index*64+:64];
          udp_axis_mlast_reg[port_index] <= udp_axis_mlast_skid[port_index];
          udp_axis_musr_reg[port_index*193+:193] <= udp_axis_musr_skid[port_index*193+:193];
        end
        else if (s1_to_reg) begin
          udp_axis_mdata_reg[port_index*512+:512] <= udp_axis_sdata_s1;
          udp_axis_mkeep_reg[port_index*64+:64] <= udp_axis_skeep_s1;
          udp_axis_mlast_reg[port_index] <= udp_axis_slast_s1;
          udp_axis_musr_reg[port_index*193+:193] <= udp_axis_susr_s1;
        end
      end

      always @(posedge clk) begin
        if (s1_to_skid) begin
          udp_axis_mdata_skid[port_index*512+:512] <= udp_axis_sdata_s1;
          udp_axis_mkeep_skid[port_index*64+:64] <= udp_axis_skeep_s1;
          udp_axis_mlast_skid[port_index] <= udp_axis_slast_s1;
          udp_axis_musr_skid[port_index*193+:193] <= udp_axis_susr_s1;
        end
      end
    end
  endgenerate

  // sel_type_one_hot_s1
  always @(posedge clk) begin
    if (rst) begin
      sel_type_one_hot_s1 <= 'd0;
    end
    else begin
      if (s_handshake && is_first_beat) begin
        sel_type_one_hot_s1 <= port_compare;
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
        is_first_beat <= udp_axis_slast;                            // 本拍收的是本包最后一拍 -> 下一拍即新包首拍
      end
    end
  end

  assign  udp_axis_mdata   = udp_axis_mdata_reg;
  assign  udp_axis_mkeep   = udp_axis_mkeep_reg;
  assign  udp_axis_mlast   = udp_axis_mlast_reg;
  assign  udp_axis_mvalid  = udp_axis_mvalid_reg;
  assign  udp_axis_musr    = udp_axis_musr_reg;

endmodule
`resetall
