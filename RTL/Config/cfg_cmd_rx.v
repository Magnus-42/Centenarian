`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : cfg_cmd_rx.v
// Module Name : cfg_cmd_rx
// Author      : LiXintao
// Date        : 2026-10-22
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 配置命令接收解析，支持跨帧解析
// Note        : 下游发起读FIFO，时延为2
//               支持任意长度MAX_VALUE_BYTES
//
// 帧格式(请求):
// +------+-------+-------+-------+-------+---------+
// |      | OP    | SEQ   | TAG1  | LEN1  | VALUE1  |
// |------+-------+-------+-------+-------+---------+
// | 大小 | 1字节 | 1字节 | 2字节 | 1字节 | LEN字节 |
// +------+-------+-------+-------+-------+---------+
// ============================================================================
module cfg_cmd_rx#(
  parameter  AXIS_WIDTH= 512,
  parameter  MAX_VALUE_BYTES= 16,
  localparam MAX_VALUE_BIT= MAX_VALUE_BYTES*8,
  parameter  CMD_USR_WIDTH= 96
)(
  input  wire                                          clk             ,
  input  wire                                          rst             ,

  input  wire          [        AXIS_WIDTH-1:0]        axis_sdata      ,
  input  wire          [      AXIS_WIDTH/8-1:0]        axis_skeep      ,
  input  wire                                          axis_slast      ,
  input  wire                                          axis_svalid     ,
  output wire                                          axis_sready     ,
  input  wire          [     CMD_USR_WIDTH-1:0]        axis_susr       ,// 帧级侧带：仅第一拍有效
  input  wire                                          is_beat1_drop   ,// 本帧是否丢弃

  input  wire                                          frame_rd_en     ,
  output wire                                          frame_empty     ,
  output wire          [                   7:0]        rec_op          ,
  output wire          [                   7:0]        rec_seq         ,
  output wire          [                   7:0]        rec_item        ,
  output wire          [                   3:0]        rec_set         ,
  output wire          [                   3:0]        rec_port        ,
  output wire          [                   7:0]        rec_len         ,
  output wire          [     MAX_VALUE_BIT-1:0]        rec_val         ,
  output wire          [     CMD_USR_WIDTH-1:0]        rec_usr
);
  // fifo 存储格式：{rec_usr,rec_val,rec_len,rec_set,rec_port,rec_item,rec_seq,rec_op}
  //                = CMD_USR_WIDTH + 40 + MAX_VALUE_BIT
  localparam REC_WIDTH = CMD_USR_WIDTH + 40 + MAX_VALUE_BIT;
  localparam STATE_WIDTH= 3 ;
  localparam [       STATE_WIDTH-1:0]        S_IDLE= 'd0;
  localparam [       STATE_WIDTH-1:0]        S_OP= 'd1;
  localparam [       STATE_WIDTH-1:0]        S_SEQ= 'd2;
  localparam [       STATE_WIDTH-1:0]        S_ITEM= 'd3;
  localparam [       STATE_WIDTH-1:0]        S_PORT= 'd4;
  localparam [       STATE_WIDTH-1:0]        S_LEN= 'd5;
  localparam [       STATE_WIDTH-1:0]        S_VAL_LOOP= 'd6;
  reg                  [       STATE_WIDTH-1:0]        state_reg        ,state_next;

  reg  is_first_beat, is_first_beat_s1;
  reg  is_drop_reg;
  wire data_valid = is_first_beat ? !is_beat1_drop : !is_drop_reg;
  
  // 标志位
  wire                                                 is_val_end       ;// 值最后一拍
  reg                                                  is_loop_frame_end;// 标记帧结束
  reg                                                  is_len_frame_end ;
  wire                                                 is_data_valid    ;
  wire                                                 is_len_zero_pre  ;
  wire                                                 is_use_last_data ;// 使用最后一拍active data

  // 解析得到的TLV数据
  reg                  [                   7:0]        op_reg           ;
  reg                  [                   7:0]        seq_reg          ;
  reg                  [                   7:0]        item_reg         ;
  reg                  [                   3:0]        set_reg          ;
  reg                  [                   3:0]        port_reg         ;
  reg                  [                   7:0]        len_reg          ;
  reg                  [     MAX_VALUE_BIT-1:0]        val_reg          ;
  reg                  [     CMD_USR_WIDTH-1:0]        usr_reg          ;

  // FIFO输入输出
  reg                                                  fifo_wr_en_reg   ;

  wire                 [      REC_WIDTH-1:0]           fifo_din         ;
  wire                                                 fifo_wr_en       ;
  wire                                                 fifo_rd_en       ;
  wire                 [      REC_WIDTH-1:0]           fifo_dout        ;
  wire                                                 fifo_full        ;
  wire                                                 fifo_empty       ;

  // 指针基地址和计数器
  localparam VAL_INDEX_WIDTH= $clog2(MAX_VALUE_BIT);
  reg                  [   VAL_INDEX_WIDTH-1:0]        val_index        ;
  reg                  [                   7:0]        val_cnt_pre      ;

  // 正在被观察的字节
  localparam USE_DATA_CNT_WIDTH= $clog2(AXIS_WIDTH/8);
  reg                  [USE_DATA_CNT_WIDTH-1:0]        used_data_cnt    ;// 使用过的active_data计数
  reg                  [USE_DATA_CNT_WIDTH-1:0]        used_data_cnt_next;

  // s1 段
  reg                  [        AXIS_WIDTH-1:0]        axis_sdata_s1    ;
  reg                  [      AXIS_WIDTH/8-1:0]        axis_skeep_s1    ;
  reg                                                  axis_slast_s1    ;
  reg                  [     CMD_USR_WIDTH-1:0]        axis_susr_s1     ;
  reg                                                  axis_svalid_s1   ;
  wire                                                 s1_ready         ;
  assign  s1_ready         = is_use_last_data && !fifo_full;// 最后一拍消费
  assign  axis_sready      = !axis_svalid_s1 || s1_ready;
  wire                                                 s1_handshake      = s1_ready && axis_svalid_s1;
  wire                                                 s_handshake       = axis_sready && axis_svalid;

  wire [7:0]           active_data   = axis_sdata_s1[{used_data_cnt[5:0],3'b0} +: 8] ;

  // s1: valid
  always @(posedge clk) begin
    if (rst) begin
      axis_svalid_s1 <= 'd0;
    end
    else begin
      if (s_handshake) begin
        axis_svalid_s1 <= data_valid;
      end
      else if(s1_handshake) begin
        axis_svalid_s1 <= 1'b0;
      end
    end
  end

  // s1: data keep last
  always @(posedge clk) begin
    if (s_handshake) begin
      axis_sdata_s1 <= axis_sdata;
      axis_skeep_s1 <= axis_skeep;
      axis_slast_s1 <= axis_slast;
      axis_susr_s1 <= axis_susr;
    end
  end

  // state_reg
  always @(posedge clk) begin
    if (rst) begin
      state_reg <= S_IDLE;
    end
    else begin
      state_reg <= state_next;
    end
  end

  // state_next
  always @(*) begin
    state_next = state_reg;

    case (state_reg)
      S_IDLE: begin
        if (s_handshake && data_valid) begin
          state_next = S_OP;
        end
      end
      S_OP: begin
        state_next = S_SEQ;
      end
      S_SEQ: begin
        state_next = S_ITEM;
      end
      S_ITEM: begin
        if (is_data_valid) begin
          state_next = S_PORT;
        end
      end
      S_PORT: begin
        if (is_data_valid) begin
          state_next = S_LEN;
        end
      end
      S_LEN: begin
        if (is_data_valid) begin
          if (is_len_frame_end) begin
            if (s_handshake && data_valid) begin
              state_next = S_OP;
            end
            else begin
              state_next = S_IDLE;
            end
          end
          else if (is_len_zero_pre) begin
            state_next = S_OP;
          end
          else begin
            state_next = S_VAL_LOOP;
          end
        end
      end
      S_VAL_LOOP: begin
        if (is_loop_frame_end) begin
          if (s_handshake && data_valid) begin
            state_next = S_OP;
          end
          else begin
            state_next = S_IDLE;
          end
        end
        else if (is_val_end) begin
          state_next = S_OP;
        end
      end
      default: begin
        state_next = S_IDLE;
      end
    endcase
  end

  assign  is_data_valid    = axis_svalid_s1   ;
  assign  is_len_zero_pre  = (active_data == 'd0);

  // TLV解析值
  always @(posedge clk) begin
    case (state_reg)
      S_IDLE: begin
        // do nothing
      end
      S_OP: begin
        op_reg  <= active_data;
      end
      S_SEQ: begin
        seq_reg <= active_data;
      end
      S_ITEM: begin
        if (is_data_valid) begin
          item_reg <= active_data;
        end
      end
      S_PORT: begin
        if (is_data_valid) begin
          set_reg <= active_data[7:4];
          port_reg <= active_data[3:0];
        end
      end
      S_LEN: begin
        if (is_data_valid) begin
          len_reg <= active_data;
          val_reg <= 'd0;
        end
      end
      S_VAL_LOOP: begin
        val_reg[val_index +:8] <= active_data;
      end
      default: begin
        // do nothing
      end
    endcase
  end

  // usr_reg
  always @(posedge clk) begin
    if (is_data_valid && is_first_beat_s1) begin
      usr_reg <= axis_susr_s1;
    end
  end

  // val_index
  always @(posedge clk) begin
    if (rst) begin
      val_index <= 'd0;
    end
    else begin
      if (state_reg == S_LEN) begin
        val_index <= 'd0;
      end
      else if (state_reg == S_VAL_LOOP) begin
        val_index <= val_index + 'd8;
      end
    end
  end

  // val_cnt_pre
  always @(posedge clk) begin
    if (rst) begin
      val_cnt_pre <= 'd1;
    end
    else begin
      if (state_reg == S_LEN) begin
        val_cnt_pre <= 'd1;
      end
      else if (state_reg == S_VAL_LOOP && is_data_valid) begin
        val_cnt_pre <= val_cnt_pre + 'd1;
      end
    end
  end

  // used_data_cnt
  always @(posedge clk) begin
    if (rst) begin
      used_data_cnt <= 'd0;
    end
    else begin
      if (s_handshake) begin
        used_data_cnt <= 1'b0;
      end
      else if (is_data_valid) begin
        used_data_cnt <= used_data_cnt + 1'b1;
      end
    end
  end
  assign  is_use_last_data = used_data_cnt == {USE_DATA_CNT_WIDTH{1'b1}};
  
  // used_data_cnt_next
  always @(posedge clk) begin
    if (rst) begin
      used_data_cnt_next <= 'd1;
    end
    else begin
      if (s_handshake) begin
        used_data_cnt_next <= 1'b1;
      end
      else if (is_data_valid) begin
        used_data_cnt_next <= used_data_cnt_next + 1'b1;
      end
    end
  end


  // is_val_end
  assign  is_val_end       = (val_cnt_pre==len_reg);

  // is_len_frame_end
  always @(*) begin
    is_len_frame_end = 'd0;
    is_loop_frame_end = 'd0;

    if (is_use_last_data && active_data == 'd0) begin               // 最后一拍且长度为0
      is_len_frame_end = axis_slast_s1;
    end
    else if(axis_skeep_s1[used_data_cnt_next] == 'd0) begin         // 非最后一拍，但是下一个keep为0
      is_len_frame_end = axis_slast_s1;
    end

    if (is_use_last_data && is_val_end) begin                       // 最后一拍且长度为0
      is_loop_frame_end = axis_slast_s1;
    end
    else if(axis_skeep_s1[used_data_cnt_next] == 'd0) begin         // 非最后一拍，但是下一个keep为0
      is_loop_frame_end = axis_slast_s1;
    end
  end

  // is_first_beat
  always @(posedge clk) begin
    if(rst) begin
      is_first_beat <= 'd1;
    end
    else begin
      if (s_handshake) begin
        is_first_beat <= axis_slast;
      end
    end
  end

  // is_first_beat_s1
  always @(posedge clk) begin
    if(rst) begin
      is_first_beat_s1 <= 'd1;
    end
    else begin
      if (s_handshake) begin
        is_first_beat_s1 <= is_first_beat;
      end
    end
  end

  // is_drop_reg
  always @(posedge clk) begin
    if(rst) begin
      is_drop_reg <= 'd0;
    end
    else begin
      if (s_handshake && is_first_beat) begin
        is_drop_reg <= is_beat1_drop;
      end
    end
  end

  // fifo_wr_en_reg
  always @(posedge clk) begin
    if (rst) begin
      fifo_wr_en_reg <= 'd0;
    end
    else begin
      if (state_reg == S_VAL_LOOP) begin
        fifo_wr_en_reg <= is_val_end;
      end
      else if (state_reg == S_LEN) begin
        fifo_wr_en_reg <= is_len_zero_pre;
      end
      else begin
        fifo_wr_en_reg <= 'd0;
      end
    end
  end


  assign  fifo_din         = {usr_reg,val_reg,len_reg,set_reg,port_reg,item_reg,seq_reg,op_reg};
  assign  fifo_wr_en       = fifo_wr_en_reg   ;
  assign  frame_empty      = fifo_empty       ;
  assign  fifo_rd_en       = frame_rd_en      ;

  assign  rec_op           = fifo_dout[0+:8];
  assign  rec_seq          = fifo_dout[8+:8];
  assign  rec_item         = fifo_dout[16+:8];
  assign  rec_port         = fifo_dout[24+:4];
  assign  rec_set          = fifo_dout[28+:4];
  assign  rec_len          = fifo_dout[32+:8];
  assign  rec_val          = fifo_dout[40+:MAX_VALUE_BIT];
  assign  rec_usr          = fifo_dout[40+MAX_VALUE_BIT+:CMD_USR_WIDTH];

  fifo_sync#(
    .FIFO_DEPTH       (512              ),
    .DATA_WIDTH       (REC_WIDTH        ),
    .FIFO_MEMORY_TYPE ("block"          ), // 计算得应该选择BLOCK
    .BRAM_DO_REG      (2                )
  )
  u_fifo_sync(
    // ============================================================================
    // 时钟与复位
    // ============================================================================
    .rst              (rst              ),// (input)
    .clk              (clk              ),// (input)
    // ============================================================================
    // FIFO 数据接口
    // ============================================================================
    .din              (fifo_din         ),// (input)
    .wr_en            (fifo_wr_en       ),// (input)
    .rd_en            (fifo_rd_en       ),// (input)
    .dout             (fifo_dout        ),// (output)
    .full             (fifo_full        ),// (output)
    .empty            (fifo_empty       ),// (output)
    .prog_full        (                 ),// (output)
    .prog_empty       (                 ),// (output)
    .remain_count     (                 ) // (output)
  );

endmodule
`resetall
