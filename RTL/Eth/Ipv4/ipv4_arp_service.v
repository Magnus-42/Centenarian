`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : ipv4_arp_service.v
// Module Name : ipv4_arp_service
// Author      : LiXintao
// Date        : 2026-09-18
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 支持流水线设计，输出查询ARP请求，接收ARP查询结果并输出数据流
// 
// ============================================================================

module ipv4_arp_service(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [                 511: 0]       ipv4_axis_sdata ,
  input  wire          [                  63: 0]       ipv4_axis_skeep ,
  input  wire                                          ipv4_axis_slast ,
  input  wire                                          ipv4_axis_svalid,
  output wire                                          ipv4_axis_sready,

  output wire          [                 511: 0]       ipv4_axis_mdata ,
  output wire          [                  63: 0]       ipv4_axis_mkeep ,
  output wire                                          ipv4_axis_mlast ,
  output wire                                          ipv4_axis_mvalid,
  input  wire                                          ipv4_axis_mready,

  output wire          [                  47: 0]       dst_mac         ,// 仅首拍有效
  output wire          [                  47: 0]       src_mac         ,// 仅首拍有效

  output wire          [                  31: 0]       query_dst_ip     ,
  output wire          [                  31: 0]       query_src_ip     ,
  output wire                                          query_valid_pulse,
  input  wire          [                  47: 0]       arp_dst_mac      ,
  input  wire          [                  47: 0]       arp_src_mac      ,
  input  wire                                          arp_miss         ,
  input  wire                                          arp_valid        
);

  // arp 结果缓存:
  // 在飞最多 10 个包(10 级流水; 已进入输出寄存器的那个包其查表结果已被实时取走) => 最多缓存 10 条
  localparam BUF_DEPTH= 16 ; // 必须是2的幂次，使用FIFO原理
  localparam BUF_PTR_WIDTH= BUF_DEPTH <= 1 ? 1 :$clog2(BUF_DEPTH);

  // 流水线
  reg                  [                 511: 0]       ipv4_axis_sdata_s1,ipv4_axis_sdata_s2,ipv4_axis_sdata_s3,ipv4_axis_sdata_s4  ;
  reg                  [                 511: 0]       ipv4_axis_sdata_s5,ipv4_axis_sdata_s6,ipv4_axis_sdata_s7,ipv4_axis_sdata_s8  ;
  reg                  [                 511: 0]       ipv4_axis_sdata_s9,ipv4_axis_sdata_s10;
  reg                  [                  63: 0]       ipv4_axis_skeep_s1,ipv4_axis_skeep_s2,ipv4_axis_skeep_s3,ipv4_axis_skeep_s4  ;
  reg                  [                  63: 0]       ipv4_axis_skeep_s5,ipv4_axis_skeep_s6,ipv4_axis_skeep_s7,ipv4_axis_skeep_s8  ;
  reg                  [                  63: 0]       ipv4_axis_skeep_s9,ipv4_axis_skeep_s10;
  reg                                                  ipv4_axis_slast_s1,ipv4_axis_slast_s2,ipv4_axis_slast_s3,ipv4_axis_slast_s4  ;
  reg                                                  ipv4_axis_slast_s5,ipv4_axis_slast_s6,ipv4_axis_slast_s7,ipv4_axis_slast_s8  ;
  reg                                                  ipv4_axis_slast_s9,ipv4_axis_slast_s10;
  reg                                                  ipv4_axis_svalid_s1,ipv4_axis_svalid_s2,ipv4_axis_svalid_s3,ipv4_axis_svalid_s4  ;
  reg                                                  ipv4_axis_svalid_s5,ipv4_axis_svalid_s6,ipv4_axis_svalid_s7,ipv4_axis_svalid_s8  ;
  reg                                                  ipv4_axis_svalid_s9,ipv4_axis_svalid_s10;

  reg                                                  is_first_beat_s1,is_first_beat_s2,is_first_beat_s3,is_first_beat_s4  ;
  reg                                                  is_first_beat_s5,is_first_beat_s6,is_first_beat_s7,is_first_beat_s8  ;
  reg                                                  is_first_beat_s9,is_first_beat_s10;

  // 输出寄存器
  reg                  [                 511: 0]       ipv4_axis_mdata_reg  ;
  reg                  [                  63: 0]       ipv4_axis_mkeep_reg  ;
  reg                                                  ipv4_axis_mlast_reg  ;
  reg                                                  ipv4_axis_mvalid_reg  ;

  reg                  [                  47: 0]       dst_mac_reg        ;
  reg                  [                  47: 0]       src_mac_reg        ;

  // arp输出缓存
  reg                  [     BUF_PTR_WIDTH-1: 0]       arp_buf_wr_ptr     ;
  reg                  [     BUF_PTR_WIDTH-1: 0]       arp_buf_rd_ptr     ;
  reg                                                  arp_miss_buf[BUF_DEPTH-1:0]  ;
  reg                  [                  47: 0]       dst_mac_buf[BUF_DEPTH-1:0]  ;
  reg                  [                  47: 0]       src_mac_buf[BUF_DEPTH-1:0]  ;


  reg                                                  is_first_beat      ;
  reg                                                  is_drop_other_beat  ;// 第二拍及其之后需要丢弃

  // skid_buffer
  reg                  [                 511: 0]       ipv4_axis_mdata_skid  ;
  reg                  [                  63: 0]       ipv4_axis_mkeep_skid  ;
  reg                                                  ipv4_axis_mlast_skid  ;
  reg                                                  ipv4_axis_mvalid_skid  ;
  reg                  [                  47: 0]       dst_mac_skid       ;
  reg                  [                  47: 0]       src_mac_skid       ;

  // 握手
  wire                                                 s_handshake      =ipv4_axis_svalid&&ipv4_axis_sready;
  wire                                                 m_handshake      =ipv4_axis_mvalid_reg&&ipv4_axis_mready;
  wire                                                 s10_ready         =!ipv4_axis_mvalid_skid;
  wire                                                 s9_ready         =!ipv4_axis_svalid_s10||s10_ready;
  wire                                                 s8_ready         =!ipv4_axis_svalid_s9||s9_ready;
  wire                                                 s7_ready         =!ipv4_axis_svalid_s8||s8_ready;
  wire                                                 s6_ready         =!ipv4_axis_svalid_s7||s7_ready;
  wire                                                 s5_ready         =!ipv4_axis_svalid_s6||s6_ready;
  wire                                                 s4_ready         =!ipv4_axis_svalid_s5||s5_ready;
  wire                                                 s3_ready         =!ipv4_axis_svalid_s4||s4_ready;
  wire                                                 s2_ready         =!ipv4_axis_svalid_s3||s3_ready;
  wire                                                 s1_ready         =!ipv4_axis_svalid_s2||s2_ready;
  assign  ipv4_axis_sready = !ipv4_axis_svalid_s1 || s1_ready;
  wire                                                 s10_handshake    =s10_ready&&ipv4_axis_svalid_s10;
  wire                                                 s9_handshake     =s9_ready&&ipv4_axis_svalid_s9;
  wire                                                 s8_handshake     =s8_ready&&ipv4_axis_svalid_s8;
  wire                                                 s7_handshake     =s7_ready&&ipv4_axis_svalid_s7;
  wire                                                 s6_handshake     =s6_ready&&ipv4_axis_svalid_s6;
  wire                                                 s5_handshake     =s5_ready&&ipv4_axis_svalid_s5;
  wire                                                 s4_handshake     =s4_ready&&ipv4_axis_svalid_s4;
  wire                                                 s3_handshake     =s3_ready&&ipv4_axis_svalid_s3;
  wire                                                 s2_handshake     =s2_ready&&ipv4_axis_svalid_s2;
  wire                                                 s1_handshake     =s1_ready&&ipv4_axis_svalid_s1;

  wire                                                 arp_buf_empty    =arp_buf_wr_ptr==arp_buf_rd_ptr;
  wire                                                 current_miss     =arp_buf_empty?arp_miss : arp_miss_buf[arp_buf_rd_ptr];
  wire                 [                  47: 0]       current_dst_mac  =arp_buf_empty?arp_dst_mac : dst_mac_buf[arp_buf_rd_ptr];
  wire                 [                  47: 0]       current_src_mac  =arp_buf_empty?arp_src_mac : src_mac_buf[arp_buf_rd_ptr];
  wire                                                 is_drop          =is_first_beat_s10?current_miss : is_drop_other_beat;
  wire                                                 arp_buf_take_live=s10_handshake&&is_first_beat_s10&& arp_buf_empty;
  wire                                                 arp_buf_wr_en    =arp_valid&& !arp_buf_take_live;

  assign  query_src_ip         = ipv4_axis_sdata[127:96]; // src ip 字段
  assign  query_dst_ip         = ipv4_axis_sdata[159:128]; // des ip 字段
  assign  query_valid_pulse= s_handshake && is_first_beat; // 第一拍握手则开始查询

  ////////////////////// 水线缓存
  // ipv4_axis_sdata_s1
  always @(posedge clk) begin
    if (s_handshake) begin
      ipv4_axis_sdata_s1 <= ipv4_axis_sdata;
    end
  end

  // ipv4_axis_skeep_s1
  always @(posedge clk) begin
    if (s_handshake) begin
      ipv4_axis_skeep_s1 <= ipv4_axis_skeep;
    end
  end

  // ipv4_axis_slast_s1
  always @(posedge clk) begin
    if (s_handshake) begin
      ipv4_axis_slast_s1 <= ipv4_axis_slast;
    end
  end

  // ipv4_axis_svalid_s1
  always @(posedge clk) begin
    if (rst) begin
      ipv4_axis_svalid_s1 <= 1'b0;
    end
    else begin
      if (s_handshake) begin
        ipv4_axis_svalid_s1 <= 1'b1;
      end
      else if(s1_handshake) begin
        ipv4_axis_svalid_s1 <= 1'b0;
      end
    end
  end

  // is_first_beat_s1
  always @(posedge clk) begin
    if (s_handshake) begin
      is_first_beat_s1 <= is_first_beat;
    end
  end

  // ============================================================================
  // 第二级 ~ 第七级打拍
  // ============================================================================
  // s2
  always @(posedge clk) begin
    if (s1_handshake) begin
      ipv4_axis_sdata_s2 <= ipv4_axis_sdata_s1;
      ipv4_axis_skeep_s2 <= ipv4_axis_skeep_s1;
      ipv4_axis_slast_s2 <= ipv4_axis_slast_s1;
      is_first_beat_s2    <= is_first_beat_s1 ;
    end
  end
  always @(posedge clk) begin
    if (rst)               begin ipv4_axis_svalid_s2 <= 1'b0; end
    else if (s1_handshake) begin ipv4_axis_svalid_s2 <= 1'b1; end
    else if (s2_handshake) begin ipv4_axis_svalid_s2 <= 1'b0; end
  end

  // s3
  always @(posedge clk) begin
    if (s2_handshake) begin
      ipv4_axis_sdata_s3 <= ipv4_axis_sdata_s2;
      ipv4_axis_skeep_s3 <= ipv4_axis_skeep_s2;
      ipv4_axis_slast_s3 <= ipv4_axis_slast_s2;
      is_first_beat_s3    <= is_first_beat_s2 ;
    end
  end
  always @(posedge clk) begin
    if (rst)               begin ipv4_axis_svalid_s3 <= 1'b0; end
    else if (s2_handshake) begin ipv4_axis_svalid_s3 <= 1'b1; end
    else if (s3_handshake) begin ipv4_axis_svalid_s3 <= 1'b0; end
  end

  // s4
  always @(posedge clk) begin
    if (s3_handshake) begin
      ipv4_axis_sdata_s4 <= ipv4_axis_sdata_s3;
      ipv4_axis_skeep_s4 <= ipv4_axis_skeep_s3;
      ipv4_axis_slast_s4 <= ipv4_axis_slast_s3;
      is_first_beat_s4    <= is_first_beat_s3 ;
    end
  end
  always @(posedge clk) begin
    if (rst)               begin ipv4_axis_svalid_s4 <= 1'b0; end
    else if (s3_handshake) begin ipv4_axis_svalid_s4 <= 1'b1; end
    else if (s4_handshake) begin ipv4_axis_svalid_s4 <= 1'b0; end
  end

  // s5
  always @(posedge clk) begin
    if (s4_handshake) begin
      ipv4_axis_sdata_s5 <= ipv4_axis_sdata_s4;
      ipv4_axis_skeep_s5 <= ipv4_axis_skeep_s4;
      ipv4_axis_slast_s5 <= ipv4_axis_slast_s4;
      is_first_beat_s5    <= is_first_beat_s4 ;
    end
  end
  always @(posedge clk) begin
    if (rst)               begin ipv4_axis_svalid_s5 <= 1'b0; end
    else if (s4_handshake) begin ipv4_axis_svalid_s5 <= 1'b1; end
    else if (s5_handshake) begin ipv4_axis_svalid_s5 <= 1'b0; end
  end

  // s6
  always @(posedge clk) begin
    if (s5_handshake) begin
      ipv4_axis_sdata_s6 <= ipv4_axis_sdata_s5;
      ipv4_axis_skeep_s6 <= ipv4_axis_skeep_s5;
      ipv4_axis_slast_s6 <= ipv4_axis_slast_s5;
      is_first_beat_s6    <= is_first_beat_s5 ;
    end
  end
  always @(posedge clk) begin
    if (rst)               begin ipv4_axis_svalid_s6 <= 1'b0; end
    else if (s5_handshake) begin ipv4_axis_svalid_s6 <= 1'b1; end
    else if (s6_handshake) begin ipv4_axis_svalid_s6 <= 1'b0; end
  end

  // s7
  always @(posedge clk) begin
    if (s6_handshake) begin
      ipv4_axis_sdata_s7 <= ipv4_axis_sdata_s6;
      ipv4_axis_skeep_s7 <= ipv4_axis_skeep_s6;
      ipv4_axis_slast_s7 <= ipv4_axis_slast_s6;
      is_first_beat_s7    <= is_first_beat_s6 ;
    end
  end
  always @(posedge clk) begin
    if (rst)               begin ipv4_axis_svalid_s7 <= 1'b0; end
    else if (s6_handshake) begin ipv4_axis_svalid_s7 <= 1'b1; end
    else if (s7_handshake) begin ipv4_axis_svalid_s7 <= 1'b0; end
  end

  // s8
  always @(posedge clk) begin
    if (s7_handshake) begin
      ipv4_axis_sdata_s8 <= ipv4_axis_sdata_s7;
      ipv4_axis_skeep_s8 <= ipv4_axis_skeep_s7;
      ipv4_axis_slast_s8 <= ipv4_axis_slast_s7;
      is_first_beat_s8    <= is_first_beat_s7 ;
    end
  end
  always @(posedge clk) begin
    if (rst)               begin ipv4_axis_svalid_s8 <= 1'b0; end
    else if (s7_handshake) begin ipv4_axis_svalid_s8 <= 1'b1; end
    else if (s8_handshake) begin ipv4_axis_svalid_s8 <= 1'b0; end
  end

  // s9
  always @(posedge clk) begin
    if (s8_handshake) begin
      ipv4_axis_sdata_s9 <= ipv4_axis_sdata_s8;
      ipv4_axis_skeep_s9 <= ipv4_axis_skeep_s8;
      ipv4_axis_slast_s9 <= ipv4_axis_slast_s8;
      is_first_beat_s9    <= is_first_beat_s8 ;
    end
  end
  always @(posedge clk) begin
    if (rst)               begin ipv4_axis_svalid_s9 <= 1'b0; end
    else if (s8_handshake) begin ipv4_axis_svalid_s9 <= 1'b1; end
    else if (s9_handshake) begin ipv4_axis_svalid_s9 <= 1'b0; end
  end

  // s10
  always @(posedge clk) begin
    if (s9_handshake) begin
      ipv4_axis_sdata_s10 <= ipv4_axis_sdata_s9;
      ipv4_axis_skeep_s10 <= ipv4_axis_skeep_s9;
      ipv4_axis_slast_s10 <= ipv4_axis_slast_s9;
      is_first_beat_s10    <= is_first_beat_s9 ;
    end
  end
  always @(posedge clk) begin
    if (rst)               begin ipv4_axis_svalid_s10 <= 1'b0; end
    else if (s9_handshake) begin ipv4_axis_svalid_s10 <= 1'b1; end
    else if (s10_handshake) begin ipv4_axis_svalid_s10 <= 1'b0; end
  end

  //////////////////////标志位
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

  // is_drop_other_beat
  always @(posedge clk) begin
    if (rst) begin
      is_drop_other_beat <= 'd0;
    end
    else begin
      if (ipv4_axis_slast_s10) begin
        is_drop_other_beat <= 1'b0;
      end
      else if (s10_handshake && is_first_beat_s10) begin
        is_drop_other_beat <= current_miss;                         // 命中->0(正常转发), 未命中->1(丢弃本包其余拍)
      end
    end
  end

  //////////////////////ARP 流水线缓存FIFO，设计逻辑保证不会写满，只需要判空
  // arp_buf_wr_ptr
  always @(posedge clk) begin
    if (rst) begin
      arp_buf_wr_ptr <= 'd0;
    end
    else begin
      if (arp_buf_wr_en) begin
        arp_buf_wr_ptr <= arp_buf_wr_ptr + 1'b1;                    // 塞入缓存
      end
    end
  end

  // arp_buf_rd_ptr
  always @(posedge clk) begin
    if (rst) begin
      arp_buf_rd_ptr <= 'd0;
    end
    else begin
      if (!arp_buf_empty && s10_handshake && is_first_beat_s10) begin
        arp_buf_rd_ptr <= arp_buf_rd_ptr + 1'b1;                    // 取出缓存
      end
    end
  end
  
  // arp_miss_buf
  always @(posedge clk) begin
    if (arp_buf_wr_en) begin
      arp_miss_buf[arp_buf_wr_ptr] <= arp_miss;                     // 塞入缓存
    end
  end

  // dst_mac_buf
  always @(posedge clk) begin
    if (arp_buf_wr_en) begin
      dst_mac_buf[arp_buf_wr_ptr] <= arp_dst_mac;                       // 塞入缓存
    end
  end

  // src_mac_buf
  always @(posedge clk) begin
    if (arp_buf_wr_en) begin
      src_mac_buf[arp_buf_wr_ptr] <= arp_src_mac;                       // 塞入缓存
    end
  end

  // skid
  wire                    reg_can_take = !ipv4_axis_mvalid_reg || m_handshake;
  wire                    skid_to_reg  = ipv4_axis_mvalid_skid && reg_can_take;// skid 顶上
  wire                    s10_to_reg    = s10_handshake && reg_can_take;          // s10 直入 reg
  wire                    s10_to_skid   = s10_handshake && !reg_can_take;         // s10 存入 skid
  wire [                  47: 0]       s10_dst_mac    = is_first_beat_s10 ? current_dst_mac : 48'd0;
  wire [                  47: 0]       s10_src_mac    = is_first_beat_s10 ? current_src_mac : 48'd0;

  // 输出寄存器: data / keep / last / dst
  always @(posedge clk) begin
    if (skid_to_reg) begin
      ipv4_axis_mdata_reg <= ipv4_axis_mdata_skid;
      ipv4_axis_mkeep_reg <= ipv4_axis_mkeep_skid;
      ipv4_axis_mlast_reg <= ipv4_axis_mlast_skid;
      dst_mac_reg         <= dst_mac_skid;
    end
    else if (s10_to_reg) begin
      ipv4_axis_mdata_reg <= ipv4_axis_sdata_s10;
      ipv4_axis_mkeep_reg <= ipv4_axis_skeep_s10;
      ipv4_axis_mlast_reg <= ipv4_axis_slast_s10;
      dst_mac_reg         <= s10_dst_mac;
      src_mac_reg         <= s10_src_mac;
    end
  end

  // 输出寄存器 valid
  always @(posedge clk) begin
    if (rst)              ipv4_axis_mvalid_reg <= 1'b0;
    else if (skid_to_reg) ipv4_axis_mvalid_reg <= 1'b1;                         // skid 只存有效拍
    else if (s10_to_reg)  ipv4_axis_mvalid_reg <= ~is_drop;                     // 未命中 => 丢弃
    else if (m_handshake) ipv4_axis_mvalid_reg <= 1'b0;
  end

  // skid: data / keep / last / dst
  always @(posedge clk) begin
    if (s10_to_skid) begin
      ipv4_axis_mdata_skid <= ipv4_axis_sdata_s10;
      ipv4_axis_mkeep_skid <= ipv4_axis_skeep_s10;
      ipv4_axis_mlast_skid <= ipv4_axis_slast_s10;
      dst_mac_skid         <= s10_dst_mac;
      src_mac_skid         <= s10_src_mac;
    end
  end

  // skid valid
  always @(posedge clk) begin
    if (rst)              ipv4_axis_mvalid_skid <= 1'b0;
    else if (s10_to_skid) ipv4_axis_mvalid_skid <= ~is_drop;
    else if (skid_to_reg) ipv4_axis_mvalid_skid <= 1'b0;                        // 顶上后清空
  end

  assign  ipv4_axis_mdata  = ipv4_axis_mdata_reg;
  assign  ipv4_axis_mkeep  = ipv4_axis_mkeep_reg;
  assign  ipv4_axis_mlast  = ipv4_axis_mlast_reg;
  assign  ipv4_axis_mvalid = ipv4_axis_mvalid_reg;
  assign  dst_mac          = dst_mac_reg      ;
  assign  src_mac          = src_mac_reg      ;

endmodule
`resetall
