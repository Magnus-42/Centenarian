`timescale 1ns/1ps
`default_nettype none

// Shared interface scoreboard for skid, sync FIFO and async FIFO configurations.
// Source and sink clocks have different periods for the asynchronous instances.
module axis_buffer_case #(
    parameter integer Kind = 0, PacketMode = 0, Strict = 0,
    parameter DataMemory = "distributed", UsrMemory = "distributed"
)(output reg done = 0);
  localparam integer Beats = 360;
  reg wr_clk = 0, slow_clk = 0, rst = 1;
  wire rd_clk = Kind == 2 ? slow_clk : wr_clk;
  reg [63:0] sdata = 0;
  reg [7:0] skeep = 0;
  reg [15:0] susr = 0;
  reg slast = 0, svalid = 0, mready = 0;
  wire sready, mvalid, mlast;
  wire [63:0] mdata;
  wire [7:0] mkeep;
  wire [15:0] musr;
  reg [88:0] expected[0:2047];
  reg [88:0] held;
  reg stalled = 0;
  integer sent = 0, received = 0, cycle = 0, epoch = 0, stalls = 0, complete_beats = 0;
  always #5 wr_clk = ~wr_clk;
  always #7 slow_clk = ~slow_clk;

  generate
    if (Kind == 0) begin
      axis_skid_buffer #(.DataWidth(64), .UsrWidth(16), .SelectGroupWidth(16)) dut (
        .clk(wr_clk), .rst(rst), .axis_sdata(sdata), .axis_skeep(skeep), .axis_susr(susr),
        .axis_svalid(svalid), .axis_slast(slast), .axis_sready(sready),
        .axis_mdata(mdata), .axis_mkeep(mkeep), .axis_musr(musr),
        .axis_mvalid(mvalid), .axis_mlast(mlast), .axis_mready(mready));
    end else if (Kind == 1) begin
      axis_fifo_sync #(.Depth(16), .DataWidth(64), .UsrWidth(16), .PacketFifo(PacketMode),
        .DeadlockRisk(Strict), .DataMemoryType(DataMemory), .UsrMemoryType(UsrMemory)) dut (
        .clk(wr_clk), .rst(rst), .axis_sdata(sdata), .axis_skeep(skeep), .axis_susr(susr),
        .axis_svalid(svalid), .axis_slast(slast), .axis_sready(sready),
        .axis_mdata(mdata), .axis_mkeep(mkeep), .axis_musr(musr),
        .axis_mvalid(mvalid), .axis_mlast(mlast), .axis_mready(mready));
    end else begin
      axis_fifo_async #(.Depth(16), .DataWidth(64), .UsrWidth(16), .PacketFifo(PacketMode),
        .DeadlockRisk(Strict), .DataMemoryType(DataMemory), .UsrMemoryType(UsrMemory)) dut (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .arst(rst),
        .axis_sdata(sdata), .axis_skeep(skeep), .axis_susr(susr),
        .axis_svalid(svalid), .axis_slast(slast), .axis_sready(sready),
        .axis_mdata(mdata), .axis_mkeep(mkeep), .axis_musr(musr),
        .axis_mvalid(mvalid), .axis_mlast(mlast), .axis_mready(mready));
    end
  endgenerate

  always @(posedge wr_clk) begin
    if (rst) begin sent = 0; complete_beats = 0; end
    else if (svalid && sready) begin
      expected[sent] = {sdata, skeep, susr, slast};
      sent++;
      if (slast) complete_beats = sent;
    end
  end
  always @(posedge rd_clk) begin
    if (rst) begin received = 0; stalled = 0; end
    else begin
      if (stalled && (mvalid !== 1'b1 || {mdata, mkeep, musr, mlast} !== held))
        $fatal(1, "AXIS output changed under backpressure, kind=%0d", Kind);
      if (mvalid && mready) begin
        if (PacketMode && Strict && received >= complete_beats)
          $fatal(1, "incomplete packet escaped strict packet FIFO");
        if (received >= sent || {mdata, mkeep, musr, mlast} !== expected[received])
          $fatal(1, "AXIS data/keep/usr/last mismatch, kind=%0d beat=%0d", Kind, received);
        received++;
      end
      held = {mdata, mkeep, musr, mlast};
      stalled = mvalid && !mready;
      if (stalled) stalls++;
    end
  end
  always @(negedge rd_clk) begin
    if (rst) begin cycle = 0; mready = 0; end
    else begin cycle++; mready = cycle > 45 && (cycle % 19 >= 7); end
  end

  task automatic send(input integer number);
    integer packet_length;
    // Strict packet FIFOs only receive frames that fit. Early-release mode also receives long frames.
    packet_length = (PacketMode && !Strict) ? 29 : 5;
    for (integer i = 0; i < number; i++) begin
      @(negedge wr_clk);
      sdata = {32'(epoch), 32'(i * 7919 + 23)};
      skeep = 8'(i * 17 + 1);
      susr = 16'(i ^ 16'h9ac7);
      slast = (i % packet_length == packet_length - 1) || i == number - 1;
      svalid = 1;
      do @(posedge wr_clk); while (!sready);
    end
    @(negedge wr_clk); svalid = 0;
  endtask

  initial begin
    repeat (8) @(negedge wr_clk);
    rst = 0;
    send(Beats);
    wait (received == sent);
    repeat (15) @(negedge rd_clk);
    if (stalls == 0) $fatal(1, "AXIS backpressure was not exercised");
    // Discard a frame in flight, then require a clean stream after reset.
    @(negedge wr_clk); svalid = 1; slast = 0;
    do @(posedge wr_clk); while (!sready);
    @(negedge wr_clk); rst = 1; svalid = 0;
    repeat (8) @(negedge wr_clk);
    epoch = 1; rst = 0;
    send(35);
    wait (received == sent);
    repeat (20) @(negedge rd_clk);
    if (mvalid || received != 35) $fatal(1, "AXIS reset/drain mismatch");
    done = 1;
  end
endmodule

module tb_axis_buffers;
  wire [8:0] done;
  axis_buffer_case #(0) a(done[0]);
  axis_buffer_case #(1, 0, 0, "distributed", "distributed") b(done[1]);
  axis_buffer_case #(1, 1, 0, "block", "distributed") c(done[2]);
  axis_buffer_case #(1, 1, 1, "distributed", "block") d(done[3]);
  axis_buffer_case #(1, 0, 0, "block", "block") e(done[4]);
  axis_buffer_case #(2, 0, 0, "distributed", "distributed") f(done[5]);
  axis_buffer_case #(2, 1, 0, "block", "distributed") g(done[6]);
  axis_buffer_case #(2, 1, 1, "distributed", "block") h(done[7]);
  axis_buffer_case #(2, 0, 0, "block", "block") i(done[8]);
  initial begin wait (&done); $display("PASS: tb_axis_buffers"); $finish; end
  initial begin #200000; $fatal(1, "AXIS buffer watchdog"); end
endmodule
`resetall
