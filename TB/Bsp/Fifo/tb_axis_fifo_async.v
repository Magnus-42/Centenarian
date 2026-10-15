`timescale 1ns/100ps

module tb_axis_fifo_async;

  // ============================================================================
  // 参数配置 (匹配待测模块)
  // ============================================================================
  parameter FIFO_DEPTH         = 32;
  parameter AXIS_WIDTH         = 64;
  parameter AXIS_USER_WIDTH    = 1;
  parameter AXIS_ID_WIDTH      = 1;
  parameter AXIS_DEST_WIDTH    = 1;
  parameter REMAIN_COUNT_WIDTH = 6; // $clog2(32) + 1 = 6

  // ============================================================================
  // 时钟、复位与接口信号
  // ============================================================================
  reg srst;
  reg sclk;
  reg mclk;

  // AXI-Stream Slave (上游写端)
  reg  [        AXIS_WIDTH-1:0] axis_sdata;
  reg  [      AXIS_WIDTH/8-1:0] axis_skeep;
  reg                           axis_svalid;
  reg                           axis_slast;
  wire                          axis_sready;
  reg  [   AXIS_USER_WIDTH-1:0] axis_suser;
  reg  [      AXIS_WIDTH/8-1:0] axis_sstrb;
  reg  [     AXIS_ID_WIDTH-1:0] axis_sid;
  reg  [   AXIS_DEST_WIDTH-1:0] axis_sdest;

  // AXI-Stream Master (下游读端)
  wire [        AXIS_WIDTH-1:0] axis_mdata;
  wire [      AXIS_WIDTH/8-1:0] axis_mkeep;
  wire                          axis_mvalid;
  wire                          axis_mlast;
  reg                           axis_mready;
  wire [   AXIS_USER_WIDTH-1:0] axis_muser;
  wire [      AXIS_WIDTH/8-1:0] axis_mstrb;
  wire [     AXIS_ID_WIDTH-1:0] axis_mid;
  wire [   AXIS_DEST_WIDTH-1:0] axis_mdest;

  // 状态信号
  wire                          prog_almost_empty;
  wire                          prog_almost_full;
  wire                          almost_empty;
  wire                          almost_full;
  wire [REMAIN_COUNT_WIDTH-1:0] wr_almost_remain_count;
  wire [REMAIN_COUNT_WIDTH-1:0] rd_almost_remain_count;

  // ============================================================================
  // 异步时钟生成
  // ============================================================================
  initial begin
    sclk = 0;
    forever #5.0 sclk = ~sclk; // 100MHz 写时钟
  end

  initial begin
    mclk = 0;
    forever #3.3 mclk = ~mclk; // ~151MHz 读时钟
  end

  // ============================================================================
  // 待测模块实例化 (DUT)
  // ============================================================================
  axis_fifo_async #(
    .FIFO_DEPTH       (FIFO_DEPTH),
    .AXIS_WIDTH       (AXIS_WIDTH),
    .AXIS_USER_WIDTH  (AXIS_USER_WIDTH),
    .AXIS_ID_WIDTH    (AXIS_ID_WIDTH),
    .AXIS_DEST_WIDTH  (AXIS_DEST_WIDTH),
    .PACKET_FIFO      (1),              // 测试关键: 开启整包模式
    .FIFO_MEMORY_TYPE ("block"),        // 测试关键: BRAM类型
    .BRAM_DO_REG      (2),              // 测试关键: 2级输出流水线
    .PROG_EMPTY_THRESH(FIFO_DEPTH/4),
    .PROG_FULL_THRESH (FIFO_DEPTH/2),
    .REMAIN_COUNT_WIDTH(REMAIN_COUNT_WIDTH)
  ) dut (
    .srst                  (srst),
    .sclk                  (sclk),
    .mclk                  (mclk),
    .axis_sdata            (axis_sdata),
    .axis_skeep            (axis_skeep),
    .axis_svalid           (axis_svalid),
    .axis_slast            (axis_slast),
    .axis_sready           (axis_sready),
    .axis_suser            (axis_suser),
    .axis_sstrb            (axis_sstrb),
    .axis_sid              (axis_sid),
    .axis_sdest            (axis_sdest),
    .axis_mdata            (axis_mdata),
    .axis_mkeep            (axis_mkeep),
    .axis_mvalid           (axis_mvalid),
    .axis_mlast            (axis_mlast),
    .axis_mready           (axis_mready),
    .axis_muser            (axis_muser),
    .axis_mstrb            (axis_mstrb),
    .axis_mid              (axis_mid),
    .axis_mdest            (axis_mdest),
    .prog_almost_empty     (prog_almost_empty),
    .prog_almost_full      (prog_almost_full),
    .almost_empty          (almost_empty),
    .almost_full           (almost_full),
    .wr_almost_remain_count(wr_almost_remain_count),
    .rd_almost_remain_count(rd_almost_remain_count)
  );

  // ============================================================================
  // AXI-Stream 发送 Task (Verilog 2001 兼容写法)
  // ============================================================================
  task send_packet;
    input integer length;
    input [7:0]   start_val;
    integer i;
    begin
      @(posedge sclk);
      for (i = 0; i < length; i = i + 1) begin
        axis_svalid <= 1'b1;
        axis_sdata  <= { {(AXIS_WIDTH-8){1'b0}}, start_val + i[7:0] };
        axis_skeep  <= {(AXIS_WIDTH/8){1'b1}}; // 全 1 填充
        axis_sstrb  <= {(AXIS_WIDTH/8){1'b1}};
        axis_slast  <= (i == length - 1) ? 1'b1 : 1'b0;

        // 等待握手成功
        @(posedge sclk);
        while (!(axis_svalid && axis_sready)) begin
          @(posedge sclk);
        end
      end
      // 包发送完毕，清零
      axis_svalid <= 1'b0;
      axis_slast  <= 1'b0;
    end
  endtask

  // ============================================================================
  // 激励与测试序列
  // ============================================================================
  initial begin
    // 初始化信号
    srst = 1'b1;
    axis_svalid = 1'b0;
    axis_sdata  = {AXIS_WIDTH{1'b0}};
    axis_skeep  = {(AXIS_WIDTH/8){1'b0}};
    axis_slast  = 1'b0;
    axis_suser  = {AXIS_USER_WIDTH{1'b0}};
    axis_sstrb  = {(AXIS_WIDTH/8){1'b0}};
    axis_sid    = {AXIS_ID_WIDTH{1'b0}};
    axis_sdest  = {AXIS_DEST_WIDTH{1'b0}};
    axis_mready = 1'b0;

    // 释放复位
    #30;
    srst = 1'b0;
    #100;

    // ------------------------------------------------------------------
    // Case 1: 写入完整数据包并读出 (基础功能测试)
    // ------------------------------------------------------------------
    $display("[%0t] --- Case 1: Basic Write/Read ---", $time);
    send_packet(4, 8'hA0); // 发送长度为4的包
    
    #100; // 等待跨时钟域及包状态更新
    
    axis_mready = 1'b1;
    wait(axis_mvalid && axis_mlast);
    @(posedge mclk);
    axis_mready = 1'b0;

    #50;

    // ------------------------------------------------------------------
    // Case 2: 包模式(PACKET_FIFO=1) 防泄漏测试
    // ------------------------------------------------------------------
    $display("[%0t] --- Case 2: Packet Mode Leakage Test ---", $time);
    
    // 只写入半个包（不给 last）
    @(posedge sclk);
    axis_svalid <= 1'b1;
    axis_sdata  <= {{(AXIS_WIDTH-32){1'b0}}, 32'hDEADBEEF};
    axis_slast  <= 1'b0;
    
    @(posedge sclk);
    while (!(axis_svalid && axis_sready)) begin
      @(posedge sclk);
    end
    axis_svalid <= 1'b0;

    // 在读时钟域观察 mvalid 是否被错误拉高（预期应保持为0）
    axis_mready = 1'b1;
    repeat(20) @(posedge mclk);
    if (axis_mvalid) begin
      $display("[%0t] ERROR: Leakage Detected! mvalid asserted for incomplete packet.", $time);
    end else begin
      $display("[%0t] Pass: No leakage. Data is held in FIFO.", $time);
    end
    axis_mready = 1'b0;

    // 补齐该数据包的最后一拍 (拉高 last)
    #20;
    send_packet(1, 8'hFF); 

    // 读出该包
    #100;
    axis_mready = 1'b1;
    wait(axis_mvalid && axis_mlast);
    @(posedge mclk);
    axis_mready = 1'b0;

    #50;

    // ------------------------------------------------------------------
    // Case 3: 背靠背连续流与反压测试 (Fork-Join 并发)
    // ------------------------------------------------------------------
    $display("[%0t] --- Case 3: Back-to-Back & Backpressure ---", $time);
    fork
      // 线程1: 连续打入 3 个包，塞满 FIFO
      begin
        send_packet(10, 8'h10);
        send_packet(8,  8'h20);
        send_packet(15, 8'h30);
      end
      
      // 线程2: 随机置起/拉低 mready 产生下游反压
      begin
        #150; // 等待上游先塞一些数据
        repeat(30) begin
          @(posedge mclk);
          // 使用系统随机数并通过按位与取得 0 或 1，兼容 V2001
          axis_mready <= $random & 1'b1;
        end
        // 最终保持常高，排空 FIFO
        axis_mready <= 1'b1;
      end
    join
    
    // 等待 FIFO 被读空
    wait(almost_empty == 1'b1);
    repeat(10) @(posedge mclk);
    axis_mready = 1'b0;

    $display("[%0t] --- Simulation Finished ---", $time);
    $finish;
  end

  // ============================================================================
  // 波形生成 (VCD)
  // ============================================================================
  initial begin
    $dumpfile("tb_axis_fifo_async.vcd");
    $dumpvars(0, tb_axis_fifo_async);
  end

endmodule