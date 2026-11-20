// -----------------------------------------------------------------------------
// File Name   : tdp_bram.v
// Module Name : tdp_bram
// Author      : LiXintao
// Created     : 2026-08-29
// Version     : 1.0
// -----------------------------------------------------------------------------
// Description : 单时钟真双口块RAM，支持可选输出寄存器、独立读写模式、旁路和初始化。
// Note        : DoaReg/DobReg=0时对应端口读延迟为1拍，为1时读延迟为2拍；
//               同地址双写时仅保留WritePriority指定端口的写入；
//               BypassEn=1时，跨端口同地址读写通过旁路返回新值。
// -----------------------------------------------------------------------------

`resetall
`default_nettype none
`timescale 1ns / 100ps

module tdp_bram #(
    parameter integer DataWidth = 36,
    parameter integer Depth = 1024,
    localparam integer AddrWidth = Depth == 1 ? 1 : $clog2(Depth),
    parameter integer DoaReg = 1,
    parameter integer DobReg = 1,
    parameter integer InitEn = 1,
    parameter integer InitUseFile = 0,
    parameter InitFileName = "init_data.txt",
    parameter WriteModeA = "WRITE_FIRST",  // WRITE_FIRST / READ_FIRST / NO_CHANGE
    parameter WriteModeB = "WRITE_FIRST",
    parameter WritePriority = "A",
    parameter integer BypassEn = 1  // 0: 关闭旁路, 1: 同地址读写时输出新值
) (
    input wire clk,
    input wire rst,

    // A 端口
    input  wire                 a_we,
    input  wire [AddrWidth-1:0] a_addr,
    input  wire [DataWidth-1:0] a_din,
    input  wire                 a_re,
    output wire [DataWidth-1:0] a_dout,

    // B 端口
    input  wire                 b_we,
    input  wire [AddrWidth-1:0] b_addr,
    input  wire [DataWidth-1:0] b_din,
    input  wire                 b_re,
    output wire [DataWidth-1:0] b_dout
);

  // 参数范围检查
  initial begin
    if (DataWidth < 1 || Depth < 1) begin
      $display("错误：tdp_bram：不支持的参数配置。");
      $finish;
    end
    if ((InitEn != 0 && InitEn != 1) || (InitUseFile != 0 && InitUseFile != 1)) begin
      $display("错误：tdp_bram：不支持的参数配置。");
      $finish;
    end
    if ((DoaReg != 0 && DoaReg != 1)) begin
      $display("错误：tdp_bram：不支持的参数配置。");
      $finish;
    end
    if ((DobReg != 0 && DobReg != 1)) begin
      $display("错误：tdp_bram：不支持的参数配置。");
      $finish;
    end
    if ((BypassEn != 0 && BypassEn != 1)) begin
      $display("错误：tdp_bram：不支持的参数配置。");
      $finish;
    end
    if ((WriteModeA != "WRITE_FIRST" && WriteModeA != "READ_FIRST"
        && WriteModeA != "NO_CHANGE")) begin
      $display("错误：tdp_bram：不支持的参数配置。");
      $finish;
    end
    if ((WriteModeB != "WRITE_FIRST" && WriteModeB != "READ_FIRST"
        && WriteModeB != "NO_CHANGE")) begin
      $display("错误：tdp_bram：不支持的参数配置。");
      $finish;
    end
    if ((WritePriority != "A" && WritePriority != "B")) begin
      $display("错误：tdp_bram：不支持的参数配置。");
      $finish;
    end
  end

  // 存储体
  (* ram_style = "block" *)reg  [DataWidth-1:0] bram             [0:Depth-1];

  // 端口访问控制
  wire                 a_en;
  wire                 b_en;
  wire                 write_collision;
  wire                 a_we_granted;
  wire                 b_we_granted;

  // A端口读出与旁路
  reg                  a_en_d1;
  reg  [DataWidth-1:0] a_dout_bram;
  reg  [DataWidth-1:0] a_dout_reg;
  reg  [DataWidth-1:0] a_dout_bypass;
  reg  [DataWidth-1:0] a_dout_bypass_d1;
  reg                  a_bypass_sel;
  reg                  a_bypass_sel_d1;

  // B端口读出与旁路
  reg                  b_en_d1;
  reg  [DataWidth-1:0] b_dout_bram;
  reg  [DataWidth-1:0] b_dout_reg;
  reg  [DataWidth-1:0] b_dout_bypass;
  reg  [DataWidth-1:0] b_dout_bypass_d1;
  reg                  b_bypass_sel;
  reg                  b_bypass_sel_d1;

  // 存储器初始化
  if (InitEn != 0) begin : gen_init
    if (InitUseFile != 0) begin : gen_init_file
      initial begin
        // 加载十六进制文件，文件需加入 Vivado 工程的仿真或综合源
        $readmemh(InitFileName, bram);
      end
    end else begin : gen_init_clear
      integer init_index;
      initial begin
        for (init_index = 0; init_index < Depth; init_index = init_index + 1) begin
          bram[init_index] = 'd0;
        end
      end
    end
  end

  // 端口访问使能与写冲突仲裁
  assign a_en            = a_we | a_re;
  assign b_en            = b_we | b_re;
  assign write_collision = a_we && b_we && (a_addr == b_addr);
  if (WritePriority == "B") begin : gen_write_priority_b
    // B 端口优先，冲突时禁止 A 端口写入
    assign a_we_granted = a_we && !write_collision;
    assign b_we_granted = b_we;
  end else begin : gen_write_priority_a
    // 默认 A 端口优先，冲突时禁止 B 端口写入
    assign a_we_granted = a_we;
    assign b_we_granted = b_we && !write_collision;
  end

  // 跨端口同地址读写旁路
  // BypassEn=0且写端口为WRITE_FIRST时，须避免跨端口同地址读写，硬件读值不保证。
  //// A端口旁路
  always @(posedge clk) begin
    if (rst) begin
      a_dout_bypass <= 'd0;
      a_bypass_sel  <= 1'b0;
    end else begin
      if (b_we_granted && a_re && (a_addr == b_addr)) begin
        a_dout_bypass <= b_din;
        a_bypass_sel  <= (BypassEn != 0);
      end else if (a_en) begin
        a_bypass_sel <= 1'b0;
      end
    end
  end
  //// B端口旁路
  always @(posedge clk) begin
    if (rst) begin
      b_dout_bypass <= 'd0;
      b_bypass_sel  <= 1'b0;
    end else begin
      if (a_we_granted && b_re && (a_addr == b_addr)) begin
        b_dout_bypass <= a_din;
        b_bypass_sel  <= (BypassEn != 0);
      end else if (b_en) begin
        b_bypass_sel <= 1'b0;
      end
    end
  end

  // A 端口输出寄存器选择
  if (DoaReg != 0) begin : gen_doa_reg
    always @(posedge clk) begin
      if (rst) begin
        a_en_d1          <= 1'b0;
        a_dout_bypass_d1 <= 'd0;
        a_bypass_sel_d1  <= 1'b0;
      end else begin
        a_en_d1 <= a_en;
        if (a_en_d1) begin
          a_dout_bypass_d1 <= a_dout_bypass;
          a_bypass_sel_d1  <= a_bypass_sel;
        end
      end
    end

    always @(posedge clk) begin
      if (rst) begin
        a_dout_reg <= 'd0;
      end else if (a_en_d1) begin
        a_dout_reg <= a_dout_bram;
      end
    end

    assign a_dout = a_bypass_sel_d1 ? a_dout_bypass_d1 : a_dout_reg;
  end else begin : gen_doa_direct
    assign a_dout = a_bypass_sel ? a_dout_bypass : a_dout_bram;
  end

  // B 端口输出寄存器选择
  if (DobReg != 0) begin : gen_dob_reg
    always @(posedge clk) begin
      if (rst) begin
        b_en_d1          <= 1'b0;
        b_dout_bypass_d1 <= 'd0;
        b_bypass_sel_d1  <= 1'b0;
      end else begin
        b_en_d1 <= b_en;
        if (b_en_d1) begin
          b_dout_bypass_d1 <= b_dout_bypass;
          b_bypass_sel_d1  <= b_bypass_sel;
        end
      end
    end

    always @(posedge clk) begin
      if (rst) begin
        b_dout_reg <= 'd0;
      end else if (b_en_d1) begin
        b_dout_reg <= b_dout_bram;
      end
    end

    assign b_dout = b_bypass_sel_d1 ? b_dout_bypass_d1 : b_dout_reg;
  end else begin : gen_dob_direct
    assign b_dout = b_bypass_sel ? b_dout_bypass : b_dout_bram;
  end

  // A 端口读写控制
  if (WriteModeA == "WRITE_FIRST") begin : gen_write_first_a
    always @(posedge clk) begin
      if (a_en) begin
        if (a_we_granted) begin
          bram[a_addr] <= a_din;
          a_dout_bram  <= a_din;
        end else begin
          a_dout_bram <= bram[a_addr];
        end
      end
    end
  end else if (WriteModeA == "READ_FIRST") begin : gen_read_first_a
    always @(posedge clk) begin
      if (a_en) begin
        if (a_we_granted) bram[a_addr] <= a_din;
        a_dout_bram <= bram[a_addr];
      end
    end
  end else begin : gen_no_change_a
    always @(posedge clk) begin
      if (a_en) begin
        if (a_we_granted) bram[a_addr] <= a_din;
        else a_dout_bram <= bram[a_addr];
      end
    end
  end

  // B 端口读写控制
  if (WriteModeB == "WRITE_FIRST") begin : gen_write_first_b
    always @(posedge clk) begin
      if (b_en) begin
        if (b_we_granted) begin
          bram[b_addr] <= b_din;
          b_dout_bram  <= b_din;
        end else begin
          b_dout_bram <= bram[b_addr];
        end
      end
    end
  end else if (WriteModeB == "READ_FIRST") begin : gen_read_first_b
    always @(posedge clk) begin
      if (b_en) begin
        if (b_we_granted) bram[b_addr] <= b_din;
        b_dout_bram <= bram[b_addr];
      end
    end
  end else begin : gen_no_change_b
    always @(posedge clk) begin
      if (b_en) begin
        if (b_we_granted) bram[b_addr] <= b_din;
        else b_dout_bram <= bram[b_addr];
      end
    end
  end

endmodule
`resetall
