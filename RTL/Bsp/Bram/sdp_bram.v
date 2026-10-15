`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : sdp_bram.v
// Module Name : sdp_bram
// Author      : LiXintao
// Date        : 2026-08-29
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 单时钟简单双口块 RAM，支持独立读写、旁路和初始化。
// Note        : DO_REG=1 时，读数据相对 b_re 额外增加一拍输出寄存延迟。
// ============================================================================
module sdp_bram #(
    // --- 存储参数 ---
    parameter DATA_WIDTH     = 36,
    parameter DEEP           = 1024,
    parameter DEEP_WIDTH     = DEEP == 1 ? 1 : $clog2(DEEP),

    // --- 输出与初始化参数 ---
    parameter DO_REG         = 1,
    parameter INIT_EN        = 1,
    parameter INIT_USE_FILE  = 0,
    parameter INIT_FILE_NAME = "init_data.txt",
    parameter BYPASS_EN      = 1  // 0: 关闭旁路, 1: 同地址读写时输出新值
) (
    input  wire                  clk,
    input  wire                  rst,

    // ============================================================================
    // A 写端口
    // ============================================================================
    input  wire                  a_we,
    input  wire [DEEP_WIDTH-1:0] a_addr,
    input  wire [DATA_WIDTH-1:0] a_din,

    // ============================================================================
    // B 读端口
    // ============================================================================
    input  wire                  b_re,
    input  wire [DEEP_WIDTH-1:0] b_addr,
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
  // 读数据与旁路通路
  // ----------------------------------------------------------------------------
  reg                  b_re_d0;
  reg  [DATA_WIDTH-1:0] b_dout_direct;
  reg  [DATA_WIDTH-1:0] b_dout_passby;
  reg                  b_out_sel;

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
  // A 端口写控制
  // ============================================================================
  always @(posedge clk) begin
    if (a_we) begin
      bram[a_addr] <= a_din;
    end
  end

  // ============================================================================
  // 同地址读写旁路
  // ============================================================================
  always @(posedge clk) begin
    if (rst_d1) begin
      b_dout_passby <= 'd0;
      b_out_sel     <= 1'b0;
    end else if (a_we && b_re && (a_addr == b_addr)) begin
      b_dout_passby <= a_din;
      b_out_sel     <= BYPASS_EN;
    end else if (b_re) begin
      b_out_sel <= 1'b0;
    end
  end

  // ============================================================================
  // B 端口读控制
  // ============================================================================
  always @(posedge clk) begin
    if (b_re) begin
      b_dout_direct <= bram[b_addr];
    end
  end

  // ============================================================================
  // 输出寄存器选择
  // ============================================================================
  generate
    if (DO_REG) begin : gen_do_reg
      reg  [DATA_WIDTH-1:0] b_dout_reg;
      reg  [DATA_WIDTH-1:0] b_dout_passby_d0;
      reg                  b_out_sel_d0;

      always @(posedge clk) begin
        if (rst_d1) begin
          b_re_d0            <= 1'b0;
          b_dout_passby_d0   <= 'd0;
          b_out_sel_d0       <= 1'b0;
        end else begin
          b_re_d0 <= b_re;
          if (b_re_d0) begin
            b_dout_passby_d0 <= b_dout_passby;
            b_out_sel_d0     <= b_out_sel;
          end
        end
      end

      always @(posedge clk) begin
        if (rst_d1) begin
          b_dout_reg <= 'd0;
        end else if (b_re_d0) begin
          b_dout_reg <= b_dout_direct;
        end
      end

      assign b_dout = b_out_sel_d0 ? b_dout_passby_d0 : b_dout_reg;
    end else begin : gen_do_direct
      assign b_dout = b_out_sel ? b_dout_passby : b_dout_direct;
    end
  endgenerate

endmodule
`resetall
