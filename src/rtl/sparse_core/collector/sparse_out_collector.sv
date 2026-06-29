// -----------------------------------------------------------------------------
// sparse_out_collector.sv  (Phase-8, Stage 8d)
//
// Sparse-core analogue of dense_out_collector. The tlmm_driver folds every
// accepted compute beat's tile-partials into a per-lane INT32 K-reduction
// accumulator (tlmm_acc_q) and presents the final bank on result_acc, with
// result_valid pulsing once on tlmm.done. This module snapshots that bank and
// drains it sequentially into an OUTPUT URAM region for ST_OUT -> DRAM write-
// back.
//
// Why this module exists
// ----------------------
// Before Stage 8d the K-reduction accumulator was an internal (* keep *) bank
// with no observable consumer: in out-of-context synthesis the entire sparse
// datapath dead-ended and was pruned, which is what made the open-harness
// power/utilization numbers phantom (see project memory). Giving the bank a
// real URAM-write sink turns the sparse core into a live, observable endpoint
// that survives synthesis.
//
// Contract
// --------
//   * result_valid is a 1-cycle pulse; on that cycle result_acc is final and
//     stable (the driver does not clear tlmm_acc_q until the next op begins).
//   * On result_valid && !busy we snapshot all TLMM_LANES accumulators, then
//     emit one URAM write per lane on consecutive cycles:
//       wr_addr = wr_base_addr + lane_index   (lane 0 .. TLMM_LANES-1)
//       wr_data = sign-correct INT32 accumulator in the low TLMM_ACC_W bits.
//   * busy_o is high from snapshot until the final lane has been written.
//   * A new result_valid while still draining is a contract violation
//     (asserted) — the dispatcher serializes TLMM ops, so a fresh op cannot
//     complete inside the 16-cycle drain window.
//
// Resource class: no DSP, no BRAM, no URAM (the URAM lives upstream in the
// memory manager). One TLMM_LANES x tlmm_acc_t snap register + a small counter.
//
// Latency contract: first wr_en one cycle after result_valid; TLMM_LANES
// writes back-to-back; busy_o drops the cycle after the last write.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_SPARSE_OUT_COLLECTOR_SV
`define ARCHBETTER_SPARSE_OUT_COLLECTOR_SV
`default_nettype none

module sparse_out_collector
    import types_pkg::*;
#(
    parameter int unsigned WR_DATA_W = URAM_WIDTH_BITS  // 72
) (
    input  wire logic                   clk,
    input  wire logic                   rst_n,

    // Result bus from tlmm_driver.
    input  wire logic                   result_valid,
    input  wire tlmm_acc_vec_t          result_acc,

    // OUTPUT URAM base for this op's lane vector.
    input  wire logic [URAM_ADDR_W-1:0] wr_base_addr,

    // OUTPUT URAM write port (driven into memory_manager / a dedicated bank).
    output logic                        wr_en,
    output logic [URAM_ADDR_W-1:0]      wr_addr,
    output logic [WR_DATA_W-1:0]        wr_data,

    output logic                        busy_o
);

    // -------------------------------------------------------------------------
    // Elaboration consistency.
    // -------------------------------------------------------------------------
    initial begin : elab_checks
        if (WR_DATA_W < TLMM_ACC_W) begin
            $fatal(1, "sparse_out_collector: WR_DATA_W=%0d < TLMM_ACC_W=%0d",
                   WR_DATA_W, TLMM_ACC_W);
        end
    end

    // -------------------------------------------------------------------------
    // Derived counts.
    // -------------------------------------------------------------------------
    localparam int unsigned LANE_CNT_W = $clog2(TLMM_LANES + 1);   // 5
    localparam int unsigned LANE_IDX_W = $clog2(TLMM_LANES);       // 4

    // -------------------------------------------------------------------------
    // Snap register bank + sequential URAM sink.
    // -------------------------------------------------------------------------
    tlmm_acc_t              acc_q [TLMM_LANES];
    logic                   have_snap_q;
    logic [URAM_ADDR_W-1:0] wr_base_addr_q;
    logic [LANE_CNT_W-1:0]  lane_idx_q;

    logic drain_done;
    assign drain_done = (lane_idx_q == LANE_CNT_W'(TLMM_LANES));

    // -------------------------------------------------------------------------
    // URAM write port (combinational, 1 logic level).
    // -------------------------------------------------------------------------
    always_comb begin
        wr_en   = have_snap_q && !drain_done;
        wr_addr = URAM_ADDR_W'(wr_base_addr_q + URAM_ADDR_W'(lane_idx_q));
        wr_data = '0;
        if (wr_en) begin
            wr_data[TLMM_ACC_W-1:0] = acc_q[lane_idx_q[LANE_IDX_W-1:0]];
        end
    end

    assign busy_o = have_snap_q;

    // -------------------------------------------------------------------------
    // Sequential state.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int ln = 0; ln < int'(TLMM_LANES); ln++) acc_q[ln] <= '0;
            have_snap_q    <= 1'b0;
            wr_base_addr_q <= '0;
            lane_idx_q     <= '0;
        end else begin
            // ---- Snap capture ----------------------------------------------
            if (result_valid && !have_snap_q) begin
                for (int ln = 0; ln < int'(TLMM_LANES); ln++) begin
                    acc_q[ln] <= result_acc[ln];
                end
                have_snap_q    <= 1'b1;
                wr_base_addr_q <= wr_base_addr;
                lane_idx_q     <= '0;
            end

            // ---- Sequential drain ------------------------------------------
            if (wr_en) begin
                lane_idx_q <= lane_idx_q + LANE_CNT_W'(1);
            end

            // ---- Release once the full lane vector is written --------------
            if (have_snap_q && drain_done) begin
                have_snap_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    // -------------------------------------------------------------------------
    // Do not accept a new result while still draining the previous one.
    // -------------------------------------------------------------------------
    a_no_snap_while_busy: assert property (
        @(posedge clk) disable iff (!rst_n)
        result_valid |-> !have_snap_q
    ) else $error("sparse_out_collector: result_valid while still draining previous snap");

    // The drain counter must never run past the lane count.
    a_lane_idx_bound: assert property (
        @(posedge clk) disable iff (!rst_n)
        lane_idx_q <= LANE_CNT_W'(TLMM_LANES)
    ) else $error("sparse_out_collector: lane_idx_q exceeded TLMM_LANES");
`endif

endmodule : sparse_out_collector

`default_nettype wire
`endif // ARCHBETTER_SPARSE_OUT_COLLECTOR_SV
