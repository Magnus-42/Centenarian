`timescale 1ns/1ps
`default_nettype none

// Independent scan model: choose the best value, then scan cyclically from the last winner.
module value_arbiter_case #(parameter integer Registered = 1, LowValue = 0, LowIndex = 1)
    (output reg done = 0);
  localparam integer N = 3, W = 4;
  reg clk = 0, rst = 1, refresh = 0;
  reg [N*W-1:0] req = 0;
  wire [N-1:0] onehot;
  wire [1:0] index;
  integer cursor, winner, best, candidate, value, checked = 0;
  reg [N-1:0] expected = 0;
  reg [N*W-1:0] random_state = 12'hb3d;
  always #5 clk = ~clk;
  value_rr_arbiter #(.RequesterCount(N), .ReqWidth(W), .IsInsertReg(Registered),
      .LowReqFirst(LowValue), .LowFirst(LowIndex)) dut (.*);

  initial begin
    cursor = LowIndex ? 0 : N-1;
    repeat (4) @(negedge clk);
    rst = 0;
    for (integer trial = 0; trial < 160; trial++) begin
      @(negedge clk);
      random_state = {random_state[10:0], random_state[11]^random_state[5]^random_state[3]^random_state[0]};
      req = trial < 12 ? {N{4'd7}} : trial < 16 ? {N{LowValue ? 4'hf : 4'h0}} : random_state;
      refresh = (trial % 7 != 0);
      if (refresh) begin
        winner = -1;
        best = LowValue ? 16 : -1;
        for (integer step = 0; step < N; step++) begin
          candidate = LowIndex ? (cursor+step)%N : (cursor-step+N)%N;
          value = req[candidate*W+:W];
          if (value != (LowValue ? 15 : 0) &&
              ((LowValue && value < best) || (!LowValue && value > best))) begin
            winner = candidate; best = value;
          end
        end
        expected = winner < 0 ? 0 : (1 << winner);
      end
      #1;
      // Combinational refresh presents the winner before the edge; after the edge the mask advances.
      if (!Registered && (onehot !== expected || (|expected && index !== 2'(winner))))
        $fatal(1, "combinational arbiter mismatch");
      @(posedge clk); #1;
      if (Registered && (onehot !== expected || (|expected && index !== 2'(winner))))
        $fatal(1, "arbiter mismatch reg=%0d low_value=%0d low_index=%0d req=%h got=%b expected=%b",
               Registered, LowValue, LowIndex, req, onehot, expected);
      if (refresh && winner >= 0) cursor = LowIndex ? (winner+1)%N : (winner-1+N)%N;
      checked++;
    end
    if (checked != 160) $fatal(1, "arbiter incomplete");
    done = 1;
  end
endmodule

module tb_value_rr_arbiter;
  wire [7:0] done;
  for (genvar r = 0; r < 2; r++) begin
    for (genvar v = 0; v < 2; v++) begin
      for (genvar i = 0; i < 2; i++) begin
        value_arbiter_case #(r,v,i) test_case(done[r*4+v*2+i]);
      end
    end
  end
  initial begin wait (&done); $display("PASS: tb_value_rr_arbiter"); $finish; end
  initial begin #30000; $fatal(1, "value arbiter watchdog"); end
endmodule
`resetall
