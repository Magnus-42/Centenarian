`timescale 1ns/1ps
`default_nettype none

// Check the public FIFO contract with a software queue, including a non-power-of-two depth.
module fifo_case #(parameter MemoryType = "distributed", parameter integer Depth = 7)
    (output reg done = 0);
  reg clk = 0, rst = 1, wr_en = 0, rd_en = 0;
  reg [31:0] din = 0;
  wire [31:0] dout;
  wire full, empty, prog_full, prog_empty;
  wire [$clog2(Depth):0] count;
  reg [31:0] queue[0:4095];
  integer head = 0, tail = 0, occupancy = 0, accepted = 0;
  reg pending = 0;
  reg [31:0] pending_data;
  reg [31:0] random_state = 32'h3f18a792;
  always #5 clk = ~clk;

  fifo_sync #(.Depth(Depth), .Width(32), .MemoryType(MemoryType)) dut (
      .clk(clk), .rst(rst), .din(din), .wr_en(wr_en), .rd_en(rd_en), .dout(dout),
      .full(full), .empty(empty), .prog_full(prog_full), .prog_empty(prog_empty),
      .stat_data_count(count));

  always @(posedge clk) begin : scoreboard
    reg take_read, take_write;
    reg [31:0] expected;
    take_read = !rst && rd_en && !empty;
    take_write = !rst && wr_en && !full;
    if (rst) begin
      head = 0; tail = 0; occupancy = 0; pending = 0;
    end else begin
      if (MemoryType == "distributed" && take_read && dout !== queue[head])
        $fatal(1, "FIFO distributed data mismatch");
      expected = pending_data;
      if (take_read) begin pending_data = queue[head]; head++; accepted++; end
      if (take_write) begin queue[tail] = din; tail++; end
      occupancy += int'(take_write) - int'(take_read);
      #1;
      if (MemoryType == "block" && pending && dout !== expected)
        $fatal(1, "FIFO block data/read-latency mismatch");
      pending = take_read;
      if (count !== occupancy || full !== (occupancy == Depth) || empty !== (occupancy == 0) ||
          prog_full !== (occupancy >= Depth/2) || prog_empty !== (occupancy <= Depth/4))
        $fatal(1, "FIFO count/flag mismatch, memory=%s count=%0d expected=%0d", MemoryType, count, occupancy);
    end
  end

  task automatic step(input bit write, input bit read);
    @(negedge clk);
    wr_en = write; rd_en = read; din++;
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (Depth + 4) step(1, 0); // Full, including rejected writes.
    repeat (Depth + 4) step(0, 1); // Empty, including rejected reads.
    repeat (1000) begin
      random_state = {random_state[30:0], random_state[31]^random_state[21]^random_state[1]^random_state[0]};
      step(random_state[0], random_state[4]);
    end
    @(negedge clk); rst = 1; wr_en = 0; rd_en = 0;
    repeat (3) @(negedge clk);
    rst = 0;
    repeat (Depth) step(1, 0);
    repeat (Depth) begin step(0, 1); step(0, 0); step(0, 0); end
    repeat (5) step(0, 0);
    if (occupancy != 0 || accepted < 100) $fatal(1, "FIFO insufficient transfers or failed drain");
    done = 1;
  end
endmodule

module tb_fifo_sync;
  wire [3:0] done;
  fifo_case #("distributed", 7) a(done[0]);
  fifo_case #("block", 7) b(done[1]);
  fifo_case #("distributed", 8) c(done[2]);
  fifo_case #("block", 8) d(done[3]);
  initial begin wait (&done); $display("PASS: tb_fifo_sync"); $finish; end
  initial begin #100000; $fatal(1, "FIFO watchdog"); end
endmodule
`resetall
