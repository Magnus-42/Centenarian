`resetall
`default_nettype none
`timescale 1ns/100ps

// Language: Verilog 2001
// ============================================================================
// File Name   : sp_bram.v
// Module Name : sp_bram
// Author      : LiXintao
// Date        : 2026-08-29
// Version     : v1.0
// ----------------------------------------------------------------------------
// Description : 单时钟单端口块 RAM，支持可选输出寄存器、读写模式和初始化。
// Note        : DO_REG=1 时，输出数据相对使能请求额外延迟一拍。
// ============================================================================
module sp_bram #(
    // --- 存储参数 ---
    parameter DATA_WIDTH     = 36,
    parameter DEEP           = 1024,
    parameter DEEP_WIDTH     = DEEP == 1 ? 1 : $clog2(DEEP),

    // --- 输出与初始化参数 ---
    parameter DO_REG         = 1,
    parameter INIT_EN        = 1,
    parameter INIT_USE_FILE  = 0,
    parameter INIT_FILE_NAME = "init_data.txt",

    // --- 读写模式参数 ---
    parameter WRITE_MODE     = "WRITE_FIRST"  // WRITE_FIRST / READ_FIRST / NO_CHANGE
) (
    input  wire                  clk,
    input  wire                  rst,

    // ============================================================================
    // 存储端口
    // ============================================================================
    input  wire                  we,
    input  wire [DEEP_WIDTH-1:0] addr,
    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  re,
    output wire [DATA_WIDTH-1:0] dout
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
  // 端口控制与读数据通路
  // ----------------------------------------------------------------------------
  wire                  en;
  reg  [DATA_WIDTH-1:0] dout_direct;

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
  // 端口使能
  // ============================================================================
  assign en = we | re;

  // ============================================================================
  // 单端口读写控制
  // ============================================================================
  generate
    if (WRITE_MODE == "WRITE_FIRST") begin : gen_write_first
      always @(posedge clk) begin
        if (en) begin
          if (we) begin
            bram[addr]  <= din;
            dout_direct <= din;
          end else begin
            dout_direct <= bram[addr];
          end
        end
      end
    end else if (WRITE_MODE == "READ_FIRST") begin : gen_read_first
      always @(posedge clk) begin
        if (en) begin
          if (we) begin
            bram[addr] <= din;
          end
          dout_direct <= bram[addr];
        end
      end
    end else begin : gen_no_change
      always @(posedge clk) begin
        if (en) begin
          if (we) begin
            bram[addr] <= din;
          end else begin
            dout_direct <= bram[addr];
          end
        end
      end
    end
  endgenerate

  // ============================================================================
  // 输出寄存器选择
  // ============================================================================
  generate
    if (DO_REG) begin : gen_do_reg
      reg                  en_d0;
      reg [DATA_WIDTH-1:0] dout_reg;

      always @(posedge clk) begin
        if (rst_d1) begin
          en_d0 <= 1'b0;
        end else begin
          en_d0 <= en;
        end
      end

      always @(posedge clk) begin
        if (rst_d1) begin
          dout_reg <= 'd0;
        end else if (en_d0) begin
          dout_reg <= dout_direct;
        end
      end

      assign dout = dout_reg;
    end else begin : gen_do_direct
      assign dout = dout_direct;
    end
  endgenerate

endmodule
`resetall
