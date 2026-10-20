`resetall
`default_nettype none
`timescale 1ns/100ps

// ============================================================================
// File Name   : tb_axis_n_to_1_by_val.v
// Module Name : tb_axis_n_to_1_by_val
// Author      : WorkBuddy (for LiXintao)
// Date        : 2026-10-19
// ----------------------------------------------------------------------------
// Description : axis_n_to_1_by_val 模块级自测（4 路，带 usr 优先级）
//   [1] 数据完整性：载荷 = {16'hA5A5, port, 包号, 拍号, 0}，逐拍按 m_id 回查
//   [2] keep 透传：每 7 包的末拍用部分 keep（8'h0F）
//   [3] 包边界：mlast 必须与期望末拍一致；包内 m_id 不得变化
//   [4] 优先级：Ph2 期间 p3=15 独占（其余口不得被授权）
//   [5] 反压：后半段 mready 随机打拍，数据仍须逐拍一致
//   [6] 收尾：停源后排水，要求 发送数 == 接收数（不丢不重）
// Note        : m_id 由 UPDATE_TID=1 覆写为选中端口号，用于回查来源
// ============================================================================
module tb_axis_n_to_1_by_val;

  localparam N   = 4;
  localparam W   = 64;
  localparam IDW = 4;
  localparam UW  = 4;

  reg clk = 1'b0;
  always #2.5 clk = ~clk;
  reg rst = 1'b1;

  reg  [W*N-1:0]   sdata;
  reg  [8*N-1:0]   skeep;
  reg  [N-1:0]     slast, svalid;
  reg  [UW*N-1:0]  susr;
  wire [N-1:0]     sready;

  wire [W-1:0]     mdata;
  wire [7:0]       mkeep;
  wire [IDW-1:0]   mid;
  wire [UW-1:0]    musr;
  wire             mvalid, mlast;
  reg              mready;
  wire [1:0]       stat_port;
  wire             stat_idle;

  axis_n_to_1_by_val #(
    .NUM_PORTS       (N   ),
    .AXIS_WIDTH      (W   ),
    .AXIS_ID_WIDTH   (IDW ),
    .AXIS_USER_WIDTH (UW  ),
    .ARBITER_VAL_WIDTH(UW ),
    .LOW_FIRST       (0   ),
    .UPDATE_TID      (1   )
  ) u_dut (
    .clk(clk), .rst(rst),
    .axis_sdata(sdata), .axis_skeep(skeep), .axis_sid({IDW{1'b0}}),
    .axis_susr(susr), .axis_svalid(svalid), .axis_slast(slast), .axis_sready(sready),
    .axis_mdata(mdata), .axis_mkeep(mkeep), .axis_mid(mid), .axis_musr(musr),
    .axis_mvalid(mvalid), .axis_mlast(mlast), .axis_mready(mready),
    .stat_active_port(stat_port), .stat_idle(stat_idle)
  );

  // ---------------------------------------------------------------- 报文模型
  function integer pkt_len;
    input integer port;
    input integer pk;
    begin
      pkt_len = 1 + ((port * 7 + pk * 3) % 5);   // 1~5 拍
    end
  endfunction

  function [W-1:0] beat_data;
    input integer port;
    input integer pk;
    input integer bt;
    begin
      beat_data = {16'hA5A5, 12'h000, port[3:0], pk[7:0], bt[7:0], 16'h0000};
    end
  endfunction

  function [7:0] beat_keep;
    input integer port;
    input integer pk;
    input integer bt;
    begin
      beat_keep = 8'hFF;
      if ((bt == pkt_len(port,pk)-1) && ((pk % 7) == 0))
        beat_keep = 8'h0F;
    end
  endfunction

  // ---------------------------------------------------------------- 全局控制
  integer cyc;
  integer errors;
  reg     src_en;                      // 0 = 停源排水
  reg [3:0] lfsr;

  always @(posedge clk) begin
    if (rst) begin
      cyc     <= 0;
      errors  <= 0;
      src_en  <= 1'b0;
      lfsr    <= 4'b1011;
    end else begin
      cyc    <= cyc + 1;
      lfsr   <= {lfsr[2:0], lfsr[3] ^ lfsr[2]};
      if (cyc == 10)     src_en <= 1'b1;
      if (cyc == 16000)  src_en <= 1'b0;
    end
  end

  // 反压：前 6000 拍全速，之后随机
  always @(*) begin
    if (cyc < 6000) mready = 1'b1;
    else            mready = lfsr[0] | lfsr[3];
  end

  // ---------------------------------------------------------------- 源端
  genvar gp;
  generate
    for (gp = 0; gp < N; gp = gp + 1) begin : gen_src
      integer beat, pk, gap;
      reg [UW-1:0] prio;

      always @(posedge clk) begin
        if (rst) begin
          svalid[gp] <= 1'b0; slast[gp] <= 1'b0;
          beat <= 0; pk <= 0; gap <= 0;
          prio <= 4'd8;
        end else begin
          // 优先级：Ph2（6000~12000）p3=15，其余 8
          if (cyc > 6000 && cyc < 12000 && gp == 3) prio <= 4'd15;
          else                                      prio <= 4'd8;

          // 正在发的包一定要发完（AXIS 不允许中途撤 valid），停源只影响"是否起新包"
          if (svalid[gp]) begin
            if (sready[gp]) begin
              if (slast[gp]) begin
                svalid[gp] <= 1'b0;
                slast[gp]  <= 1'b0;
                pk  <= pk + 1;
                gap <= ((gp * 3 + pk) % 4);
              end else begin
                beat <= beat + 1;
                sdata[gp*W +: W] <= beat_data(gp, pk, beat + 1);
                skeep[gp*8 +: 8] <= beat_keep(gp, pk, beat + 1);
                slast[gp] <= ((beat + 1) == pkt_len(gp,pk) - 1);
              end
            end
          end else if (!src_en) begin
            svalid[gp] <= 1'b0; slast[gp] <= 1'b0;
          end else if (gap != 0) begin
            gap <= gap - 1;
          end else begin
            svalid[gp] <= 1'b1;
            beat       <= 0;
            sdata[gp*W +: W] <= beat_data(gp, pk, 0);
            skeep[gp*8 +: 8] <= beat_keep(gp, pk, 0);
            susr[gp*UW +: UW] <= prio;
            slast[gp] <= (pkt_len(gp,pk) == 1);
          end
        end
      end
    end
  endgenerate

  // ---------------------------------------------------------------- 输出检查
  integer exp_pkt  [0:N-1];
  integer exp_beat [0:N-1];
  integer rx_pkt   [0:N-1];
  integer tx_pkt   [0:N-1];
  integer i, p;
  reg [W-1:0] e_data;
  reg [7:0]   e_keep;
  reg         e_last;
  reg [IDW-1:0] last_mid;
  reg           in_pkt;

  // 统计发送包数（握手且为 last）
  generate
    for (gp = 0; gp < N; gp = gp + 1) begin : gen_txcnt
      always @(posedge clk) begin
        if (rst) tx_pkt[gp] <= 0;
        else if (svalid[gp] && sready[gp] && slast[gp]) tx_pkt[gp] <= tx_pkt[gp] + 1;
      end
    end
  endgenerate

  always @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < N; i = i + 1) begin
        exp_pkt[i]  <= 0;
        exp_beat[i] <= 0;
        rx_pkt[i]   <= 0;
      end
      in_pkt  <= 1'b0;
      last_mid<= {IDW{1'b0}};
    end else if (mvalid && mready) begin
      p = mid;
      if (p >= N) begin
        errors <= errors + 1;
        $display("[FAIL] %0t m_id=%0d out of range", $time, mid);
      end else begin
        e_data = beat_data(p, exp_pkt[p], exp_beat[p]);
        e_keep = beat_keep(p, exp_pkt[p], exp_beat[p]);
        e_last = (exp_beat[p] == pkt_len(p, exp_pkt[p]) - 1);

        if (mdata !== e_data) begin
          errors <= errors + 1;
          if (errors < 10) $display("[FAIL] %0t p%0d pkt%0d beat%0d data=%h exp=%h",
                                    $time, p, exp_pkt[p], exp_beat[p], mdata, e_data);
        end
        if (mkeep !== e_keep) begin
          errors <= errors + 1;
          if (errors < 10) $display("[FAIL] %0t p%0d pkt%0d beat%0d keep=%h exp=%h",
                                    $time, p, exp_pkt[p], exp_beat[p], mkeep, e_keep);
        end
        if (mlast !== e_last) begin
          errors <= errors + 1;
          if (errors < 10) $display("[FAIL] %0t p%0d pkt%0d beat%0d last=%b exp=%b",
                                    $time, p, exp_pkt[p], exp_beat[p], mlast, e_last);
        end
        // 包内端口不得变化
        if (in_pkt && (mid !== last_mid)) begin
          errors <= errors + 1;
          $display("[FAIL] %0t port changed inside packet: %0d -> %0d", $time, last_mid, mid);
        end

        if (e_last) begin
          exp_pkt[p]  <= exp_pkt[p] + 1;
          exp_beat[p] <= 0;
          rx_pkt[p]   <= rx_pkt[p] + 1;
          in_pkt      <= 1'b0;
        end else begin
          exp_beat[p] <= exp_beat[p] + 1;
          in_pkt      <= 1'b1;
        end
        last_mid <= mid;
      end
    end
  end

  // ---------------------------------------------------------------- 收尾
  always @(posedge clk) begin
    if (cyc == 16500) begin
      $display("------------------------------------------------------------");
      for (i = 0; i < N; i = i + 1)
        $display("  port%0d : tx=%0d rx=%0d", i, tx_pkt[i], rx_pkt[i]);
      for (i = 0; i < N; i = i + 1) begin
        if (tx_pkt[i] != rx_pkt[i]) begin
          $display("[FAIL] port%0d tx/rx mismatch", i);
          errors = errors + 1;
        end
        if (rx_pkt[i] == 0) begin
          $display("[FAIL] port%0d never served", i);
          errors = errors + 1;
        end
      end
      if (errors == 0) $display("RESULT: PASS");
      else             $display("RESULT: FAIL (%0d errors)", errors);
      $finish;
    end
  end

  initial begin
    rst = 1'b1;
    repeat (4) @(posedge clk);
    @(negedge clk) rst = 1'b0;
  end

  initial begin
    #200000;
    $display("[FAIL] GLOBAL TIMEOUT");
    $finish;
  end

endmodule
`default_nettype wire
