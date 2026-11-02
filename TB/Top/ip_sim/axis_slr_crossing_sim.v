`resetall
`timescale 1ns/100ps

// ============================================================================
// axis_slr_crossing —— SLR 跨片寄存 IP 的仿真桩（仅 xsim，不参与综合）
//   真实 IP 是单时钟（aclk）的深 FIFO，只做 SLR 边界打拍；
//   仿真用 axis_fifo_sync(512 深) 等价替代：
//     - 上游 s_axis_tready 在 eth_port_top 里是悬空的（设计假定 IP 不反压）
//     - 下游 m_axis_tready 正常反压
// ============================================================================
module axis_slr_crossing (
  input  wire                                          aclk           ,
  input  wire                                          aresetn        ,

  input  wire                                          s_axis_tvalid  ,
  output wire                                          s_axis_tready  ,
  input  wire          [                 511:0]         s_axis_tdata   ,
  input  wire          [                  63:0]         s_axis_tkeep   ,
  input  wire                                          s_axis_tlast   ,
  input  wire                                          s_axis_tuser   ,

  output wire                                          m_axis_tvalid  ,
  input  wire                                          m_axis_tready  ,
  output wire          [                 511:0]         m_axis_tdata   ,
  output wire          [                  63:0]         m_axis_tkeep   ,
  output wire                                          m_axis_tlast   ,
  output wire                                          m_axis_tuser
);

  axis_fifo_sync #(
    .FIFO_DEPTH      (512           ),
    .AXIS_WIDTH      (512           ),
    .AXIS_USER_WIDTH (1             ),
    .AXIS_ID_WIDTH   (1             ),
    .AXIS_DEST_WIDTH (1             ),
    .PACKET_FIFO     (0             ),
    .FIFO_MEMORY_TYPE("auto"        ),
    .BRAM_DO_REG     (2             ),
    .DEADLOCK_RISK   (0             )
  ) u_fifo (
    .rst             (~aresetn      ),
    .clk             (aclk          ),
    .axis_sdata      (s_axis_tdata  ),
    .axis_skeep      (s_axis_tkeep  ),
    .axis_svalid     (s_axis_tvalid ),
    .axis_slast      (s_axis_tlast  ),
    .axis_sready     (s_axis_tready ),
    .axis_susr       (s_axis_tuser  ),
    .axis_sstrb      (64'd0         ),
    .axis_sid        (1'b0          ),
    .axis_sdest      (1'b0          ),
    .axis_mdata      (m_axis_tdata  ),
    .axis_mkeep      (m_axis_tkeep  ),
    .axis_mvalid     (m_axis_tvalid ),
    .axis_mlast      (m_axis_tlast  ),
    .axis_mready     (m_axis_tready ),
    .axis_musr       (m_axis_tuser  ),
    .axis_mstrb      (              ),
    .axis_mid        (              ),
    .axis_mdest      (              ),
    .prog_empty      (              ),
    .prog_full       (              ),
    .empty           (              ),
    .full            (              ),
    .remain_count    (              )
  );

endmodule
`resetall
