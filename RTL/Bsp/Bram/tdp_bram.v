`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : tdp_bram.v
// Module Name : tdp_bram
// Author      : LiXintao
// Date        : 2026-08-29
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 单时钟真双口块 RAM，支持独立读写模式、旁路和初始化。
// Note        : 同地址双写时仅保留 WRITE_PRIORITY 指定端口的写入。
// ============================================================================
module tdp_bram #(
    // --- 存储参数 ---
    parameter DATA_WIDTH     = 36,
    parameter DEEP           = 1024,
    parameter DEEP_WIDTH     = DEEP == 1 ? 1 : $clog2(DEEP),

    // --- 输出与初始化参数 ---
    parameter DOA_REG        = 1,
    parameter DOB_REG        = 1,
    parameter INIT_EN        = 1,
    parameter INIT_USE_FILE  = 0,
    parameter INIT_FILE_NAME = "init_data.txt",

    // --- 读写模式与冲突处理参数 ---
    parameter WRITE_MODE_A   = "WRITE_FIRST",  // WRITE_FIRST / READ_FIRST / NO_CHANGE
    parameter WRITE_MODE_B   = "WRITE_FIRST",
    parameter WRITE_PRIORITY = "A",
    parameter BYPASS_EN      = 1  // 0: 关闭旁路, 1: 同地址读写时输出新值
) (
    input  wire                  clk,
    input  wire                  rst,

    // ============================================================================
    // A 端口
    // ============================================================================
    input  wire                  a_we,
    input  wire [DEEP_WIDTH-1:0] a_addr,
    input  wire [DATA_WIDTH-1:0] a_din,
    input  wire                  a_re,
    output wire [DATA_WIDTH-1:0] a_dout,

    // ============================================================================
    // B 端口
    // ============================================================================
    input  wire                  b_we,
    input  wire [DEEP_WIDTH-1:0] b_addr,
    input  wire [DATA_WIDTH-1:0] b_din,
    input  wire                  b_re,
    output wire [DATA_WIDTH-1:0] b_dout
);

  // ----------------------------------------------------------------------------
  // rst_*
  // ----------------------------------------------------------------------------
  reg rst_d0, rst_d1;

  // ----------------------------------------------------------------------------
  // 存储阵列与初始化索引
  // ----------------------------------------------------------------------------
  (* ram_style = "block" *) reg [DATA_WIDTH-1:0] bram [0:DEEP-1];
  integer init_index;

  // ----------------------------------------------------------------------------
  // 端口使能与同地址写冲突控制
  // ----------------------------------------------------------------------------
  wire a_en;
  wire b_en;
  wire is_collision;
  wire a_we_safe;
  wire b_we_safe;

  // ----------------------------------------------------------------------------
  // A 端口读数据与旁路通路
  // ----------------------------------------------------------------------------
  reg                  a_en_d0;
  reg  [DATA_WIDTH-1:0] a_dout_direct;
  reg  [DATA_WIDTH-1:0] a_dout_reg;
  reg  [DATA_WIDTH-1:0] a_dout_passby;
  reg  [DATA_WIDTH-1:0] a_dout_passby_d0;
  reg                  a_out_sel;
  reg                  a_out_sel_d0;

  // ----------------------------------------------------------------------------
  // B 端口读数据与旁路通路
  // ----------------------------------------------------------------------------
  reg                  b_en_d0;
  reg  [DATA_WIDTH-1:0] b_dout_direct;
  reg  [DATA_WIDTH-1:0] b_dout_reg;
  reg  [DATA_WIDTH-1:0] b_dout_passby;
  reg  [DATA_WIDTH-1:0] b_dout_passby_d0;
  reg                  b_out_sel;
  reg                  b_out_sel_d0;

  // ============================================================================
  // 复位同步释放
  // ============================================================================
  always @(posedge clk) begin
    if (rst) begin
      rst_d0 <= 1'b1;
      rst_d1 <= 1'b1;
    end else begin
      rst_d0 <= 1'b0;
      rst_d1 <= rst_d0;
    end
  end

  // ============================================================================
  // 存储器初始化
  // ============================================================================
  generate
    if (INIT_EN) begin : gen_init
      if (INIT_USE_FILE) begin : gen_init_file
        initial begin
          // 加载十六进制文件，文件需加入 Vivado 工程的仿真或综合源。
          $readmemh(INIT_FILE_NAME, bram);
        end
      end else begin : gen_init_clear
        initial begin
          for (init_index = 0; init_index < DEEP; init_index = init_index + 1) begin
            bram[init_index] = 'd0;
          end
        end
      end
    end
  endgenerate

  // ============================================================================
  // 端口访问使能与写冲突仲裁
  // ============================================================================
  assign a_en         = a_we | a_re;
  assign b_en         = b_we | b_re;
  assign is_collision = a_we && b_we && (a_addr == b_addr);

  generate
    if (WRITE_PRIORITY == "B") begin : gen_write_priority_b
      // B 端口优先，冲突时禁止 A 端口写入。
      assign a_we_safe = a_we && !is_collision;
      assign b_we_safe = b_we;
    end else begin : gen_write_priority_a
      // 默认 A 端口优先，冲突时禁止 B 端口写入。
      assign a_we_safe = a_we;
      assign b_we_safe = b_we && !is_collision;
    end
  endgenerate

  // ============================================================================
  // 跨端口同地址读写旁路
  // ============================================================================
  always @(posedge clk) begin
    if (rst_d1) begin
      a_dout_passby <= 'd0;
      a_out_sel     <= 1'b0;
      b_dout_passby <= 'd0;
      b_out_sel     <= 1'b0;
    end else begin
      if (b_we_safe && a_re && (a_addr == b_addr)) begin
        a_dout_passby <= b_din;
        a_out_sel     <= BYPASS_EN;
      end else if (a_en) begin
        a_out_sel <= 1'b0;
      end

      if (a_we_safe && b_re && (a_addr == b_addr)) begin
        b_dout_passby <= a_din;
        b_out_sel     <= BYPASS_EN;
      end else if (b_en) begin
        b_out_sel <= 1'b0;
      end
    end
  end

  // ============================================================================
  // A 端口输出寄存器选择
  // ============================================================================
  generate
    if (DOA_REG) begin : gen_doa_reg
      always @(posedge clk) begin
        if (rst_d1) begin
          a_en_d0            <= 1'b0;
          a_dout_passby_d0   <= 'd0;
          a_out_sel_d0       <= 1'b0;
        end else begin
          a_en_d0 <= a_en;
          if (a_en_d0) begin
            a_dout_passby_d0 <= a_dout_passby;
            a_out_sel_d0     <= a_out_sel;
          end
        end
      end

      always @(posedge clk) begin
        if (rst_d1) begin
          a_dout_reg <= 'd0;
        end else if (a_en_d0) begin
          a_dout_reg <= a_dout_direct;
        end
      end

      assign a_dout = a_out_sel_d0 ? a_dout_passby_d0 : a_dout_reg;
    end else begin : gen_doa_direct
      assign a_dout = a_out_sel ? a_dout_passby : a_dout_direct;
    end
  endgenerate

  // ============================================================================
  // B 端口输出寄存器选择
  // ============================================================================
  generate
    if (DOB_REG) begin : gen_dob_reg
      always @(posedge clk) begin
        if (rst_d1) begin
          b_en_d0            <= 1'b0;
          b_dout_passby_d0   <= 'd0;
          b_out_sel_d0       <= 1'b0;
        end else begin
          b_en_d0 <= b_en;
          if (b_en_d0) begin
            b_dout_passby_d0 <= b_dout_passby;
            b_out_sel_d0     <= b_out_sel;
          end
        end
      end

      always @(posedge clk) begin
        if (rst_d1) begin
          b_dout_reg <= 'd0;
        end else if (b_en_d0) begin
          b_dout_reg <= b_dout_direct;
        end
      end

      assign b_dout = b_out_sel_d0 ? b_dout_passby_d0 : b_dout_reg;
    end else begin : gen_dob_direct
      assign b_dout = b_out_sel ? b_dout_passby : b_dout_direct;
    end
  endgenerate

  // ============================================================================
  // A 端口读写控制
  // ============================================================================
  generate
    if (WRITE_MODE_A == "WRITE_FIRST") begin : gen_write_first_a
      always @(posedge clk) begin
        if (a_en) begin
          if (a_we_safe) begin
            bram[a_addr]  <= a_din;
            a_dout_direct <= a_din;
          end else begin
            a_dout_direct <= bram[a_addr];
          end
        end
      end
    end else if (WRITE_MODE_A == "READ_FIRST") begin : gen_read_first_a
      always @(posedge clk) begin
        if (a_en) begin
          if (a_we_safe) begin
            bram[a_addr] <= a_din;
          end
          a_dout_direct <= bram[a_addr];
        end
      end
    end else begin : gen_no_change_a
      always @(posedge clk) begin
        if (a_en) begin
          if (a_we_safe) begin
            bram[a_addr] <= a_din;
          end else begin
            a_dout_direct <= bram[a_addr];
          end
        end
      end
    end
  endgenerate

  // ============================================================================
  // B 端口读写控制
  // ============================================================================
  generate
    if (WRITE_MODE_B == "WRITE_FIRST") begin : gen_write_first_b
      always @(posedge clk) begin
        if (b_en) begin
          if (b_we_safe) begin
            bram[b_addr]  <= b_din;
            b_dout_direct <= b_din;
          end else begin
            b_dout_direct <= bram[b_addr];
          end
        end
      end
    end else if (WRITE_MODE_B == "READ_FIRST") begin : gen_read_first_b
      always @(posedge clk) begin
        if (b_en) begin
          if (b_we_safe) begin
            bram[b_addr] <= b_din;
          end
          b_dout_direct <= bram[b_addr];
        end
      end
    end else begin : gen_no_change_b
      always @(posedge clk) begin
        if (b_en) begin
          if (b_we_safe) begin
            bram[b_addr] <= b_din;
          end else begin
            b_dout_direct <= bram[b_addr];
          end
        end
      end
    end
  endgenerate

endmodule
`resetall
