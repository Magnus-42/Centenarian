`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : eth_type_demux.v
// Module Name : eth_type_demux
// Author      : LiXintao
// Date        : 2026-09-19
// Version     : v2.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计，将数据按TYPE_DICT匹配，没有匹配到的走默认通道
// 
// ============================================================================

module eth_type_demux#(
  parameter  TYPE_NUM= 2 ,
  localparam TYPE_NUM_EFF = (TYPE_NUM > 0) ? TYPE_NUM : 1,  // 字典占位项数(>=1；TYPE_NUM=0 时为 1 项占位，内容不被读取)
  parameter  [TYPE_NUM_EFF*16-1:0]        TYPE_DICT= {16'h0008,16'h0608} // ipv4/arp
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511:0]        eth_axis_sdata  ,
  input  wire          [                  63:0]        eth_axis_skeep  ,
  input  wire                                          eth_axis_slast  ,
  input  wire                                          eth_axis_svalid ,
  input  wire                                          eth_axis_susr   ,
  output wire                                          eth_axis_sready ,

  output wire          [  512*(TYPE_NUM+1)-1:0]        eth_axis_mdata  ,
  output wire          [   64*(TYPE_NUM+1)-1:0]        eth_axis_mkeep  ,
  output wire          [            TYPE_NUM:0]        eth_axis_mlast  ,
  output wire          [            TYPE_NUM:0]        eth_axis_mvalid ,
  output wire          [            TYPE_NUM:0]        eth_axis_musr   ,
  input  wire          [            TYPE_NUM:0]        eth_axis_mready  
);
  
  // raw 比较
  // s1 出比较结果
  // s2 输出

  reg                                                  is_first_beat    ;

  reg                  [                 511:0]        eth_axis_sdata_s1;
  reg                  [                  63:0]        eth_axis_skeep_s1;
  reg                                                  eth_axis_slast_s1;
  reg                                                  eth_axis_svalid_s1;
  reg                                                  eth_axis_susr_s1 ;

  reg                  [  512*(TYPE_NUM+1)-1:0]        eth_axis_mdata_reg;
  reg                  [   64*(TYPE_NUM+1)-1:0]        eth_axis_mkeep_reg;
  reg                  [            TYPE_NUM:0]        eth_axis_mlast_reg;
  reg                  [            TYPE_NUM:0]        eth_axis_mvalid_reg;
  reg                  [            TYPE_NUM:0]        eth_axis_musr_reg;

  reg                  [  512*(TYPE_NUM+1)-1:0]        eth_axis_mdata_skid;
  reg                  [   64*(TYPE_NUM+1)-1:0]        eth_axis_mkeep_skid;
  reg                  [            TYPE_NUM:0]        eth_axis_mlast_skid;
  reg                  [            TYPE_NUM:0]        eth_axis_mvalid_skid;
  reg                  [            TYPE_NUM:0]        eth_axis_musr_skid;

  wire                 [            TYPE_NUM:0]        type_compare     ;
  wire                 [            TYPE_NUM:0]        type_hit         ;

  reg                  [            TYPE_NUM:0]        sel_type_one_hot_s1;

  wire                                                 s_handshake       = eth_axis_svalid&&eth_axis_sready                                ;
  wire                                                 s1_ready          = |(sel_type_one_hot_s1&(~eth_axis_mvalid_skid))                  ;
  wire                                                 s1_handshake      = s1_ready && eth_axis_svalid_s1                                  ;
  assign  eth_axis_sready  = !eth_axis_svalid_s1 || s1_ready;

  // s1: data keep last
  always @(posedge clk) begin
    if (s_handshake) begin
      eth_axis_sdata_s1 <= eth_axis_sdata;
      eth_axis_skeep_s1 <= eth_axis_skeep;
      eth_axis_slast_s1 <= eth_axis_slast;
      eth_axis_susr_s1 <= eth_axis_susr;
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

  genvar type_index;
  generate
    for (type_index = 0; type_index<=TYPE_NUM; type_index=type_index+1) begin:gen_type
  wire                                                 m_handshake       = eth_axis_mready[type_index] && eth_axis_mvalid[type_index]      ;
  wire                                                 reg_can_take      = !eth_axis_mvalid_reg[type_index] || m_handshake                 ;
  wire                                                 skid_to_reg       = eth_axis_mvalid_skid[type_index] && reg_can_take                ;
  wire                                                 s1_to_reg         = s1_handshake && sel_type_one_hot_s1[type_index] && reg_can_take ;
  wire                                                 s1_to_skid        = s1_handshake && sel_type_one_hot_s1[type_index] && !reg_can_take;

      if (type_index == TYPE_NUM) begin:gen_default_type
  assign  type_hit[type_index]= 1'b0             ;
        // other(兜底)档命中逻辑：TYPE_NUM=0 ⇒ 无用户档，所有帧全部落 other
        if (TYPE_NUM == 0) begin:gen_no_user_type
  assign  type_compare[type_index]= 1'b1 ;
        end
        else begin:gen_has_user_type
  assign  type_compare[type_index]= ~(|type_hit[TYPE_NUM-1:0]) ;
        end
      end
      else begin:gen_range_type
  wire                                                 is_match          = TYPE_DICT[type_index*16+:16]==eth_axis_sdata[96 +: 16]          ;
        
  assign  type_hit[type_index]= is_match         ;
  assign  type_compare[type_index]= type_hit[type_index] && ~(|type_index == 0 ? 1'b0 : type_hit[type_index-1:0]);
      end

      // udp
      always @(posedge clk) begin
        if (rst) begin
          eth_axis_mvalid_reg[type_index] <= 'd0;
          eth_axis_mvalid_skid[type_index] <= 'd0;
        end
        else begin
          if (skid_to_reg || s1_to_reg) begin
            eth_axis_mvalid_reg[type_index] <= 1'b1;
          end
          else if (m_handshake) begin
            eth_axis_mvalid_reg[type_index] <= 1'b0;
          end

          if (s1_to_skid) begin
            eth_axis_mvalid_skid[type_index] <= 1'b1;
          end
          else if (skid_to_reg) begin
            eth_axis_mvalid_skid[type_index] <= 1'b0;
          end
        end
      end

      always @(posedge clk) begin
        if (skid_to_reg) begin
          eth_axis_mdata_reg[type_index*512+:512] <= eth_axis_mdata_skid[type_index*512+:512];
          eth_axis_mkeep_reg[type_index*64+:64] <= eth_axis_mkeep_skid[type_index*64+:64];
          eth_axis_mlast_reg[type_index] <= eth_axis_mlast_skid[type_index];
          eth_axis_musr_reg[type_index] <= eth_axis_musr_skid[type_index];
        end
        else if (s1_to_reg) begin
          eth_axis_mdata_reg[type_index*512+:512] <= eth_axis_sdata_s1;
          eth_axis_mkeep_reg[type_index*64+:64] <= eth_axis_skeep_s1;
          eth_axis_mlast_reg[type_index] <= eth_axis_slast_s1;
          eth_axis_musr_reg[type_index] <= eth_axis_susr_s1;
        end

        if (s1_to_skid) begin
          eth_axis_mdata_skid[type_index*512+:512] <= eth_axis_sdata_s1;
          eth_axis_mkeep_skid[type_index*64+:64] <= eth_axis_skeep_s1;
          eth_axis_mlast_skid[type_index] <= eth_axis_slast_s1;
          eth_axis_musr_skid[type_index] <= eth_axis_susr_s1;
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
        sel_type_one_hot_s1 <= type_compare;
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
        is_first_beat <= eth_axis_slast;                            // 本拍收的是本包最后一拍 -> 下一拍即新包首拍
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
