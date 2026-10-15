`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv4_type_demux.v
// Module Name : ipv4_type_demux
// Author      : LiXintao
// Date        : 2026-09-29
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计，将数据分为udp、icmp、ospf、其他数据
// 
// ============================================================================

module ipv4_type_demux(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511: 0]       ipv4_axis_sdata ,
  input  wire          [                  63: 0]       ipv4_axis_skeep ,
  input  wire                                          ipv4_axis_slast ,
  input  wire                                          ipv4_axis_svalid,
  input  wire          [                  95: 0]       ipv4_axis_susr  ,
  output wire                                          ipv4_axis_sready,

  output wire          [                 511: 0]       ipv4_udp_axis_mdata,
  output wire          [                  63: 0]       ipv4_udp_axis_mkeep,
  output wire                                          ipv4_udp_axis_mlast,
  output wire                                          ipv4_udp_axis_mvalid,
  output wire          [                  95: 0]       ipv4_udp_axis_musr,
  input  wire                                          ipv4_udp_axis_mready,

  output wire          [                 511: 0]       ipv4_icmp_axis_mdata,
  output wire          [                  63: 0]       ipv4_icmp_axis_mkeep,
  output wire                                          ipv4_icmp_axis_mlast,
  output wire                                          ipv4_icmp_axis_mvalid,
  output wire          [                  95: 0]       ipv4_icmp_axis_musr,
  input  wire                                          ipv4_icmp_axis_mready,

  output wire          [                 511: 0]       ipv4_ospf_axis_mdata,
  output wire          [                  63: 0]       ipv4_ospf_axis_mkeep,
  output wire                                          ipv4_ospf_axis_mlast,
  output wire                                          ipv4_ospf_axis_mvalid,
  output wire          [                  95: 0]       ipv4_ospf_axis_musr,
  input  wire                                          ipv4_ospf_axis_mready,

  output wire          [                 511: 0]       ipv4_other_axis_mdata,
  output wire          [                  63: 0]       ipv4_other_axis_mkeep,
  output wire                                          ipv4_other_axis_mlast,
  output wire                                          ipv4_other_axis_mvalid,
  output wire          [                  95: 0]       ipv4_other_axis_musr,
  input  wire                                          ipv4_other_axis_mready 
);
  reg                                                  is_first_beat      ;

  reg                  [                 511: 0]       ipv4_axis_sdata_s1  ;
  reg                  [                  63: 0]       ipv4_axis_skeep_s1  ;
  reg                                                  ipv4_axis_slast_s1  ;
  reg                                                  ipv4_axis_svalid_s1  ;
  reg                  [                  95: 0]       ipv4_axis_susr_s1  ;

  reg                  [                 511: 0]       ipv4_udp_axis_mdata_reg  ;
  reg                  [                  63: 0]       ipv4_udp_axis_mkeep_reg  ;
  reg                                                  ipv4_udp_axis_mlast_reg  ;
  reg                                                  ipv4_udp_axis_mvalid_reg  ;
  reg                  [                  95: 0]       ipv4_udp_axis_musr_reg  ;

  reg                  [                 511: 0]       ipv4_udp_axis_mdata_skid  ;
  reg                  [                  63: 0]       ipv4_udp_axis_mkeep_skid  ;
  reg                                                  ipv4_udp_axis_mlast_skid  ;
  reg                                                  ipv4_udp_axis_mvalid_skid  ;
  reg                  [                  95: 0]       ipv4_udp_axis_musr_skid  ;

  reg                  [                 511: 0]       ipv4_icmp_axis_mdata_reg  ;
  reg                  [                  63: 0]       ipv4_icmp_axis_mkeep_reg  ;
  reg                                                  ipv4_icmp_axis_mlast_reg  ;
  reg                                                  ipv4_icmp_axis_mvalid_reg  ;
  reg                  [                  95: 0]       ipv4_icmp_axis_musr_reg  ;

  reg                  [                 511: 0]       ipv4_icmp_axis_mdata_skid  ;
  reg                  [                  63: 0]       ipv4_icmp_axis_mkeep_skid  ;
  reg                                                  ipv4_icmp_axis_mlast_skid  ;
  reg                                                  ipv4_icmp_axis_mvalid_skid  ;
  reg                  [                  95: 0]       ipv4_icmp_axis_musr_skid  ;

  reg                  [                 511: 0]       ipv4_ospf_axis_mdata_reg  ;
  reg                  [                  63: 0]       ipv4_ospf_axis_mkeep_reg  ;
  reg                                                  ipv4_ospf_axis_mlast_reg  ;
  reg                                                  ipv4_ospf_axis_mvalid_reg  ;
  reg                  [                  95: 0]       ipv4_ospf_axis_musr_reg  ;

  reg                  [                 511: 0]       ipv4_ospf_axis_mdata_skid  ;
  reg                  [                  63: 0]       ipv4_ospf_axis_mkeep_skid  ;
  reg                                                  ipv4_ospf_axis_mlast_skid  ;
  reg                                                  ipv4_ospf_axis_mvalid_skid  ;
  reg                  [                  95: 0]       ipv4_ospf_axis_musr_skid  ;

  reg                  [                 511: 0]       ipv4_other_axis_mdata_reg  ;
  reg                  [                  63: 0]       ipv4_other_axis_mkeep_reg  ;
  reg                                                  ipv4_other_axis_mlast_reg  ;
  reg                                                  ipv4_other_axis_mvalid_reg  ;
  reg                  [                  95: 0]       ipv4_other_axis_musr_reg  ;

  reg                  [                 511: 0]       ipv4_other_axis_mdata_skid  ;
  reg                  [                  63: 0]       ipv4_other_axis_mkeep_skid  ;
  reg                                                  ipv4_other_axis_mlast_skid  ;
  reg                                                  ipv4_other_axis_mvalid_skid  ;
  reg                  [                  95: 0]       ipv4_other_axis_musr_skid  ;

  reg                  [                   3: 0]       sel_type_one_hot_s1  ;
  wire                                                 s_handshake      =ipv4_axis_svalid&&ipv4_axis_sready;
  wire s1_ready = (sel_type_one_hot_s1[0] && !ipv4_udp_axis_mvalid_skid)  ||
                  (sel_type_one_hot_s1[1] && !ipv4_icmp_axis_mvalid_skid) ||
                  (sel_type_one_hot_s1[2] && !ipv4_ospf_axis_mvalid_skid) ||
                  (sel_type_one_hot_s1[3] && !ipv4_other_axis_mvalid_skid);
  wire                                                 s1_handshake     =s1_ready&&ipv4_axis_svalid_s1;
  assign  ipv4_axis_sready = !ipv4_axis_svalid_s1 || s1_ready;
  wire                                                 ipv4_udp_handshake=ipv4_udp_axis_mvalid_reg&&ipv4_udp_axis_mready  ;
  wire                                                 ipv4_icmp_handshake=ipv4_icmp_axis_mvalid_reg&&ipv4_icmp_axis_mready  ;
  wire                                                 ipv4_ospf_handshake=ipv4_ospf_axis_mvalid_reg&&ipv4_ospf_axis_mready  ;
  wire                                                 ipv4_other_handshake=ipv4_other_axis_mvalid_reg&&ipv4_other_axis_mready  ;

  // s1: data keep last
  always @(posedge clk) begin
    if (s_handshake) begin
      ipv4_axis_sdata_s1 <= ipv4_axis_sdata;
      ipv4_axis_skeep_s1 <= ipv4_axis_skeep;
      ipv4_axis_slast_s1 <= ipv4_axis_slast;
      ipv4_axis_susr_s1  <= ipv4_axis_susr;
    end
  end
  // s1: valid
  always @(posedge clk) begin
    if (rst) begin
      ipv4_axis_svalid_s1 <= 1'd0;
    end
    else begin
      if (s_handshake) begin
        ipv4_axis_svalid_s1 <= 1'b1;
      end
      else if (s1_handshake) begin
        ipv4_axis_svalid_s1 <= 1'b0;
      end
    end
  end

  wire                                                 udp_reg_can_take =ipv4_udp_handshake||!ipv4_udp_axis_mvalid_reg;
  wire                                                 udp_skid_to_reg  =ipv4_udp_axis_mvalid_skid&&udp_reg_can_take;
  wire                                                 udp_s1_to_skid   =s1_handshake&&sel_type_one_hot_s1[0]&&!udp_reg_can_take;
  wire                                                 udp_s1_to_reg    =s1_handshake&&sel_type_one_hot_s1[0]&&udp_reg_can_take;

  wire                                                 icmp_reg_can_take=ipv4_icmp_handshake||!ipv4_icmp_axis_mvalid_reg  ;
  wire                                                 icmp_skid_to_reg =ipv4_icmp_axis_mvalid_skid&&icmp_reg_can_take;
  wire                                                 icmp_s1_to_skid  =s1_handshake&&sel_type_one_hot_s1[1]&&!icmp_reg_can_take;
  wire                                                 icmp_s1_to_reg   =s1_handshake&&sel_type_one_hot_s1[1]&&icmp_reg_can_take;

  wire                                                 ospf_reg_can_take=ipv4_ospf_handshake||!ipv4_ospf_axis_mvalid_reg  ;
  wire                                                 ospf_skid_to_reg =ipv4_ospf_axis_mvalid_skid&&ospf_reg_can_take;
  wire                                                 ospf_s1_to_skid  =s1_handshake&&sel_type_one_hot_s1[2]&&!ospf_reg_can_take;
  wire                                                 ospf_s1_to_reg   =s1_handshake&&sel_type_one_hot_s1[2]&&ospf_reg_can_take;

  wire                                                 other_reg_can_take=ipv4_other_handshake||!ipv4_other_axis_mvalid_reg  ;
  wire                                                 other_skid_to_reg=ipv4_other_axis_mvalid_skid&&other_reg_can_take  ;
  wire                                                 other_s1_to_skid =s1_handshake&&sel_type_one_hot_s1[3]&&!other_reg_can_take;
  wire                                                 other_s1_to_reg  =s1_handshake&&sel_type_one_hot_s1[3]&&other_reg_can_take;

  // udp
  always @(posedge clk) begin
    if (rst) begin
      ipv4_udp_axis_mvalid_reg <= 'd0;
      ipv4_udp_axis_mvalid_skid <= 'd0;
    end
    else begin
      if (udp_skid_to_reg || udp_s1_to_reg) begin
        ipv4_udp_axis_mvalid_reg <= 1'b1;
      end
      else if (ipv4_udp_handshake) begin
        ipv4_udp_axis_mvalid_reg <= 1'b0;
      end

      if (udp_s1_to_skid) begin
        ipv4_udp_axis_mvalid_skid <= 1'b1;
      end
      else if (udp_skid_to_reg) begin
        ipv4_udp_axis_mvalid_skid <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (udp_skid_to_reg) begin
      ipv4_udp_axis_mdata_reg <= ipv4_udp_axis_mdata_skid;
      ipv4_udp_axis_mkeep_reg <= ipv4_udp_axis_mkeep_skid;
      ipv4_udp_axis_mlast_reg <= ipv4_udp_axis_mlast_skid;
      ipv4_udp_axis_musr_reg <= ipv4_udp_axis_musr_skid;
    end
    else if (udp_s1_to_reg) begin
      ipv4_udp_axis_mdata_reg <= ipv4_axis_sdata_s1;
      ipv4_udp_axis_mkeep_reg <= ipv4_axis_skeep_s1;
      ipv4_udp_axis_mlast_reg <= ipv4_axis_slast_s1;
      ipv4_udp_axis_musr_reg <= ipv4_axis_susr_s1;
    end
  end

  always @(posedge clk) begin
    if (udp_s1_to_skid) begin
      ipv4_udp_axis_mdata_skid <= ipv4_axis_sdata_s1;
      ipv4_udp_axis_mkeep_skid <= ipv4_axis_skeep_s1;
      ipv4_udp_axis_mlast_skid <= ipv4_axis_slast_s1;
      ipv4_udp_axis_musr_skid <= ipv4_axis_susr_s1;
    end
  end

  // icmp
  always @(posedge clk) begin
    if (rst) begin
      ipv4_icmp_axis_mvalid_reg <= 'd0;
      ipv4_icmp_axis_mvalid_skid <= 'd0;
    end
    else begin
      if (icmp_skid_to_reg || icmp_s1_to_reg) begin
        ipv4_icmp_axis_mvalid_reg <= 1'b1;
      end
      else if (ipv4_icmp_handshake) begin
        ipv4_icmp_axis_mvalid_reg <= 1'b0;
      end

      if (icmp_s1_to_skid) begin
        ipv4_icmp_axis_mvalid_skid <= 1'b1;
      end
      else if (icmp_skid_to_reg) begin
        ipv4_icmp_axis_mvalid_skid <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (icmp_skid_to_reg) begin
      ipv4_icmp_axis_mdata_reg <= ipv4_icmp_axis_mdata_skid;
      ipv4_icmp_axis_mkeep_reg <= ipv4_icmp_axis_mkeep_skid;
      ipv4_icmp_axis_mlast_reg <= ipv4_icmp_axis_mlast_skid;
      ipv4_icmp_axis_musr_reg <= ipv4_icmp_axis_musr_skid;
    end
    else if (icmp_s1_to_reg) begin
      ipv4_icmp_axis_mdata_reg <= ipv4_axis_sdata_s1;
      ipv4_icmp_axis_mkeep_reg <= ipv4_axis_skeep_s1;
      ipv4_icmp_axis_mlast_reg <= ipv4_axis_slast_s1;
      ipv4_icmp_axis_musr_reg <= ipv4_axis_susr_s1;
    end
  end

  always @(posedge clk) begin
    if (icmp_s1_to_skid) begin
      ipv4_icmp_axis_mdata_skid <= ipv4_axis_sdata_s1;
      ipv4_icmp_axis_mkeep_skid <= ipv4_axis_skeep_s1;
      ipv4_icmp_axis_mlast_skid <= ipv4_axis_slast_s1;
      ipv4_icmp_axis_musr_skid <= ipv4_axis_susr_s1;
    end
  end

  // ospf
  always @(posedge clk) begin
    if (rst) begin
      ipv4_ospf_axis_mvalid_reg <= 'd0;
      ipv4_ospf_axis_mvalid_skid <= 'd0;
    end
    else begin
      if (ospf_skid_to_reg || ospf_s1_to_reg) begin
        ipv4_ospf_axis_mvalid_reg <= 1'b1;
      end
      else if (ipv4_ospf_handshake) begin
        ipv4_ospf_axis_mvalid_reg <= 1'b0;
      end

      if (ospf_s1_to_skid) begin
        ipv4_ospf_axis_mvalid_skid <= 1'b1;
      end
      else if (ospf_skid_to_reg) begin
        ipv4_ospf_axis_mvalid_skid <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (ospf_skid_to_reg) begin
      ipv4_ospf_axis_mdata_reg <= ipv4_ospf_axis_mdata_skid;
      ipv4_ospf_axis_mkeep_reg <= ipv4_ospf_axis_mkeep_skid;
      ipv4_ospf_axis_mlast_reg <= ipv4_ospf_axis_mlast_skid;
      ipv4_ospf_axis_musr_reg <= ipv4_ospf_axis_musr_skid;
    end
    else if (ospf_s1_to_reg) begin
      ipv4_ospf_axis_mdata_reg <= ipv4_axis_sdata_s1;
      ipv4_ospf_axis_mkeep_reg <= ipv4_axis_skeep_s1;
      ipv4_ospf_axis_mlast_reg <= ipv4_axis_slast_s1;
      ipv4_ospf_axis_musr_reg <= ipv4_axis_susr_s1;
    end
  end

  always @(posedge clk) begin
    if (ospf_s1_to_skid) begin
      ipv4_ospf_axis_mdata_skid <= ipv4_axis_sdata_s1;
      ipv4_ospf_axis_mkeep_skid <= ipv4_axis_skeep_s1;
      ipv4_ospf_axis_mlast_skid <= ipv4_axis_slast_s1;
      ipv4_ospf_axis_musr_skid <= ipv4_axis_susr_s1;
    end
  end

  // other
  always @(posedge clk) begin
    if (rst) begin
      ipv4_other_axis_mvalid_reg <= 'd0;
      ipv4_other_axis_mvalid_skid <= 'd0;
    end
    else begin
      if (other_skid_to_reg || other_s1_to_reg) begin
        ipv4_other_axis_mvalid_reg <= 1'b1;
      end
      else if (ipv4_other_handshake) begin
        ipv4_other_axis_mvalid_reg <= 1'b0;
      end

      if (other_s1_to_skid) begin
        ipv4_other_axis_mvalid_skid <= 1'b1;
      end
      else if (other_skid_to_reg) begin
        ipv4_other_axis_mvalid_skid <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (other_skid_to_reg) begin
      ipv4_other_axis_mdata_reg <= ipv4_other_axis_mdata_skid;
      ipv4_other_axis_mkeep_reg <= ipv4_other_axis_mkeep_skid;
      ipv4_other_axis_mlast_reg <= ipv4_other_axis_mlast_skid;
      ipv4_other_axis_musr_reg <= ipv4_other_axis_musr_skid;
    end
    else if (other_s1_to_reg) begin
      ipv4_other_axis_mdata_reg <= ipv4_axis_sdata_s1;
      ipv4_other_axis_mkeep_reg <= ipv4_axis_skeep_s1;
      ipv4_other_axis_mlast_reg <= ipv4_axis_slast_s1;
      ipv4_other_axis_musr_reg <= ipv4_axis_susr_s1;
    end
  end

  always @(posedge clk) begin
    if (other_s1_to_skid) begin
      ipv4_other_axis_mdata_skid <= ipv4_axis_sdata_s1;
      ipv4_other_axis_mkeep_skid <= ipv4_axis_skeep_s1;
      ipv4_other_axis_mlast_skid <= ipv4_axis_slast_s1;
      ipv4_other_axis_musr_skid <= ipv4_axis_susr_s1;
    end
  end

  // sel_type_one_hot_s1
  always @(posedge clk) begin
    if (rst) begin
      sel_type_one_hot_s1 <= 'd0;
    end
    else begin
      if (s_handshake && is_first_beat) begin
        if (ipv4_axis_sdata[72 +: 8] == 8'h11) begin
          sel_type_one_hot_s1 <= 4'b001;
        end
        else if (ipv4_axis_sdata[72 +: 8] == 8'h01) begin
          sel_type_one_hot_s1 <= 4'b010;
        end
        else if (ipv4_axis_sdata[72 +: 8] == 8'h59) begin
          sel_type_one_hot_s1 <= 4'b0100;
        end
        else begin
          sel_type_one_hot_s1 <= 4'b1000;
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
        is_first_beat <= ipv4_axis_slast;                           // 本拍收的是本包最后一拍 -> 下一拍即新包首拍
      end
    end
  end

  assign  ipv4_udp_axis_mdata= ipv4_udp_axis_mdata_reg;
  assign  ipv4_udp_axis_mkeep= ipv4_udp_axis_mkeep_reg;
  assign  ipv4_udp_axis_mlast= ipv4_udp_axis_mlast_reg;
  assign  ipv4_udp_axis_mvalid= ipv4_udp_axis_mvalid_reg;
  assign  ipv4_udp_axis_musr= ipv4_udp_axis_musr_reg;
  assign  ipv4_icmp_axis_mdata= ipv4_icmp_axis_mdata_reg;
  assign  ipv4_icmp_axis_mkeep= ipv4_icmp_axis_mkeep_reg;
  assign  ipv4_icmp_axis_mlast= ipv4_icmp_axis_mlast_reg;
  assign  ipv4_icmp_axis_mvalid= ipv4_icmp_axis_mvalid_reg;
  assign  ipv4_icmp_axis_musr= ipv4_icmp_axis_musr_reg;
  assign  ipv4_ospf_axis_mdata= ipv4_ospf_axis_mdata_reg;
  assign  ipv4_ospf_axis_mkeep= ipv4_ospf_axis_mkeep_reg;
  assign  ipv4_ospf_axis_mlast= ipv4_ospf_axis_mlast_reg;
  assign  ipv4_ospf_axis_mvalid= ipv4_ospf_axis_mvalid_reg;
  assign  ipv4_ospf_axis_musr= ipv4_ospf_axis_musr_reg;
  assign  ipv4_other_axis_mdata= ipv4_other_axis_mdata_reg;
  assign  ipv4_other_axis_mkeep= ipv4_other_axis_mkeep_reg;
  assign  ipv4_other_axis_mlast= ipv4_other_axis_mlast_reg;
  assign  ipv4_other_axis_mvalid= ipv4_other_axis_mvalid_reg;
  assign  ipv4_other_axis_musr= ipv4_other_axis_musr_reg;

endmodule
`resetall
