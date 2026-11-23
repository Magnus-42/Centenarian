`timescale 1ns/1ps
`default_nettype none

// Verify packet locking, per-channel ordering and complete payload/sideband preservation.
module axis_arbiter_case #(parameter integer LowValue = 0, LowIndex = 1)
    (output reg done = 0);
  localparam integer N = 3, Beats = 30;
  reg clk = 0, rst = 1, mready = 0;
  reg [N*64-1:0] sdata = 0;
  reg [N*8-1:0] skeep = 0;
  reg [N*12-1:0] susr = 0;
  reg [N-1:0] svalid = 0, slast = 0;
  wire [N-1:0] sready;
  wire [63:0] mdata;
  wire [7:0] mkeep;
  wire [11:0] musr;
  wire mvalid, mlast;
  integer sent[0:N-1], received[0:N-1];
  integer count = 0, cycle = 0, active = -1, phase = 0, first_channel = -1, packets = 0;
  reg [84:0] held;
  reg stalled = 0;
  always #5 clk = ~clk;
  axis_value_rr_arbiter #(.RequesterCount(N), .DataWidth(64), .UsrWidth(12), .ReqWidth(4),
      .LowReqFirst(LowValue), .LowFirst(LowIndex), .SelectGroupWidth(16)) dut (
      .clk(clk), .rst(rst), .axis_sdata(sdata), .axis_skeep(skeep), .axis_susr(susr),
      .axis_svalid(svalid), .axis_slast(slast), .axis_sready(sready),
      .axis_mdata(mdata), .axis_mkeep(mkeep), .axis_musr(musr),
      .axis_mvalid(mvalid), .axis_mlast(mlast), .axis_mready(mready));

  function automatic [3:0] priority_of(input integer channel);
    return phase == 0 ? (LowValue ? 4'(N-channel) : 4'(channel+1)) : 4'd5;
  endfunction
  function automatic [63:0] data_of(input integer channel, input integer beat);
    return {16'h593a, 16'(channel), 32'(beat * 7919 + 19)};
  endfunction

  always @(posedge clk) begin : score
    integer channel, beat;
    if (!rst) begin
      for (integer i = 0; i < N; i++) if (svalid[i] && sready[i]) sent[i]++;
      if (stalled && (mvalid !== 1'b1 || {mdata,mkeep,musr,mlast} !== held))
        $fatal(1, "arbiter changed a stalled output");
      if (mvalid && mready) begin
        channel = mdata[47:32];
        if (channel < 0 || channel >= N) $fatal(1, "invalid channel");
        beat = received[channel];
        if (beat >= sent[channel] || mdata !== data_of(channel,beat) ||
            mkeep !== 8'(beat*13+1) || musr !== {8'(channel+8'h80),priority_of(channel)} ||
            mlast !== (beat % 3 == 2)) $fatal(1, "arbiter payload/order mismatch");
        if (first_channel == -1) first_channel = channel;
        if (active != -1 && active != channel) $fatal(1, "arbiter interleaved a packet");
        if (phase == 1 && active == -1 && channel != (LowIndex ? packets%N : N-1-packets%N))
          $fatal(1, "arbiter equal-priority round-robin order mismatch");
        active = mlast ? -1 : channel;
        if (mlast) packets++;
        received[channel]++; count++;
      end
      held = {mdata,mkeep,musr,mlast}; stalled = mvalid && !mready;
    end else stalled = 0;
  end

  always @(negedge clk) begin
    if (rst) begin svalid = 0; cycle = 0; mready = 0; end
    else begin
      cycle++;
      mready = cycle > 15 && cycle % 13 >= 5;
      for (integer i = 0; i < N; i++) begin
        svalid[i] = sent[i] < Beats;
        sdata[i*64+:64] = data_of(i,sent[i]);
        skeep[i*8+:8] = 8'(sent[i]*13+1);
        susr[i*12+:12] = {8'(i+8'h80),priority_of(i)};
        slast[i] = sent[i] % 3 == 2;
      end
    end
  end

  initial begin
    for (integer trial = 0; trial < 2; trial++) begin
      @(negedge clk); rst = 1;
      repeat (4) @(posedge clk);
      @(negedge clk);
      phase = trial; count = 0; active = -1; first_channel = -1; packets = 0;
      for (integer i = 0; i < N; i++) begin sent[i] = 0; received[i] = 0; end
      rst = 0;
      wait (count == N*Beats);
      repeat (20) @(posedge clk);
      if (mvalid || count != N*Beats) $fatal(1, "arbiter duplicate output");
      if (trial == 0 && first_channel != N-1) $fatal(1, "arbiter numerical priority mismatch");
      if (trial == 1 && first_channel != (LowIndex ? 0 : N-1))
        $fatal(1, "arbiter initial tie direction mismatch");
    end
    done = 1;
  end
endmodule

module tb_axis_value_rr_arbiter;
  wire [3:0] done;
  for (genvar v = 0; v < 2; v++) begin
    for (genvar i = 0; i < 2; i++) begin
      axis_arbiter_case #(v,i) test_case(done[v*2+i]);
    end
  end
  initial begin wait (&done); $display("PASS: tb_axis_value_rr_arbiter"); $finish; end
  initial begin #100000; $fatal(1, "AXIS arbiter watchdog"); end
endmodule
`resetall
