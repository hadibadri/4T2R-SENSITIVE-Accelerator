// -----------------------------------------------------------------------------
// dense_act_streamer.sv  (R6.8b.3 — WIDE single-read pipeline, II=1)
//
// Pulls activation beats from the dense URAM ping-pong read port and pushes them
// onto a NoC source, driven from the dispatcher's gemm_issue control plane.
//
// One BFP12 mantissa block (16 mantissas * 12b = 192b) per NoC beat, with the
// shared 8-bit exponent on strm.user. The dense pp is now a WIDE bank
// (DENSE_PP_URAM_W = 288 b = 4 native URAM288 leaves), so a whole block is
// returned in ONE read as { hi_cascade[143:0], lo_cascade[143:0] }:
//     mant[0..7]  = lo[95:0]  = rd_data[95:0]
//     mant[8..15] = hi[95:0]  = rd_data[144 +: 96]
//     exp         = lo[96+:8] = rd_data[96 +: 8]
// THROUGHPUT floor is now 1 read/beat = II=1 (vs R6.8a's 4 serial natives = II=4).
//
// R6.8b.3 — why this is a rewrite
// -------------------------------
// R6.8b.1/.2 made the dense pp a wide bank (one read = one block) and removed the
// uram_cascade_adapter from the dense path. So the previous lo/hi pairing (2
// cascade reads + an adapter that split each into 2 natives) collapses to a single
// wide read per beat. The prefetched pipeline structure is kept (issue ahead,
// capture into a beat FIFO, present at the NoC's pace) but each "read" is now one
// wide read returning a full beat:
//
//   * ISSUE: one wide read per beat at wide_addr = cascade_base/2, gated only by
//     beat-FIFO room (outstanding < FIFO_DEPTH). No adapter accept-depth bound.
//   * CAPTURE: each rd_valid IS a full beat (slice as above) -> push to beat FIFO.
//   * PRESENT: drains the FIFO onto strm.src at the NoC's pace.
//
// With the wide read + a stall-free present path, steady state is II=1.
//
// Modes (unchanged from R6.5): PER_TOKEN streams k_cnt K-beats at a fixed
// 2-words/beat stride; CONTINUOUS streams batch_n distinct tokens at token_stride.
//
// Resource class: no DSP, no BRAM/URAM (a depth-FIFO_DEPTH register FIFO).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE_ACT_STREAMER_SV
`define ARCHBETTER_DENSE_ACT_STREAMER_SV
`default_nettype none

module dense_act_streamer
    import types_pkg::*;
#(
    parameter int unsigned PP_DATA_W   = DENSE_PP_URAM_W, // 288: WIDE dense pp word
    parameter int unsigned NOC_DW      = NOC_DATA_W,    // 192
    parameter int unsigned NOC_UW      = NOC_USER_W,    // 8
    parameter int unsigned MANT_HALF_W = BFP12_BLK * BFP12_MANT_W / 2,  // 96
    // Beat FIFO depth. Buffers assembled beats so issue never stalls on present
    // (NoC backpressure). Measured: 8 already saturates the downstream consume
    // rate (the dispatcher/NoC/array present path is the throughput wall, not the
    // fetch); deeper buffering does not raise steady-state throughput.
    parameter int unsigned FIFO_DEPTH  = 8
) (
    input  wire logic                    clk,
    input  wire logic                    rst_n,

    input  wire logic [URAM_ADDR_W-1:0]  base_addr,
    input  wire logic [URAM_ADDR_W-1:0]  token_stride,

    gemm_issue_if.drv  gemm,
    pingpong_if.core   pp,
    strm_if.src        src
);

    // R6.8b.3: the WIDE dense pp returns a whole block (both cascade halves) in ONE
    // read, so the streamer no longer pairs lo/hi cascade words and there is no
    // cascade adapter to bound in-flight against -- a beat is exactly one wide read.
    // CASCADE_HALF_W is the 144b lo/hi split inside the 288b wide word.
    localparam int unsigned CASCADE_HALF_W = PP_DATA_W / 2;             // 144
    localparam int unsigned CNT_W          = $clog2(FIFO_DEPTH + 1);

    initial begin : geometry_check
        if (PP_DATA_W < (CASCADE_HALF_W + MANT_HALF_W))
            $error("dense_act_streamer: PP_DATA_W=%0d cannot hold the hi mantissa half at [%0d +: %0d]",
                   PP_DATA_W, CASCADE_HALF_W, MANT_HALF_W);
        if (NOC_DW != (2 * MANT_HALF_W))
            $error("dense_act_streamer: NOC_DW=%0d != 2*MANT_HALF_W=%0d", NOC_DW, 2*MANT_HALF_W);
    end

    // =========================================================================
    // Op-scoped state (latched at op start = the cycle gemm.busy first rises).
    // =========================================================================
    logic                    running_q;     // an op is in progress
    logic [MACRO_CNT_W-1:0]  total_beats_q;
    logic [URAM_ADDR_W-1:0]  beat_stride_q;

    logic op_start;
    assign op_start = gemm.busy && !running_q;

    // =========================================================================
    // Issue side: one wide read per beat. No lo/hi pairing, no cascade adapter,
    // so issue is gated only by beat-FIFO room (outstanding < FIFO_DEPTH).
    // =========================================================================
    logic [MACRO_CNT_W-1:0]  iss_beat_q;    // beat being issued (1 wide read each)
    logic [URAM_ADDR_W-1:0]  iss_base_q;    // CASCADE-word base of iss_beat

    // beats issued (reads sent) but not yet presented; bounds the FIFO + in-flight
    logic [CNT_W:0]          outstanding_q;

    logic iss_more;     // more reads of this op to issue
    logic can_issue;
    assign iss_more  = running_q && (iss_beat_q < total_beats_q);
    assign can_issue = iss_more && pp.side_valid
                     && (outstanding_q < CNT_W'(FIFO_DEPTH));

    // One wide read per beat at the block's wide-word address. A 288b wide word
    // holds the 2 cascade words (lo, hi) of a block, so wide_addr = cascade_base/2
    // (iss_base is even by construction: base_addr + beat*even_stride).
    logic [URAM_ADDR_W-1:0] issue_addr;
    assign issue_addr = iss_base_q >> 1;

    // A beat's read finishes issuing the cycle it is accepted (1 read = 1 beat).
    logic issued_beat;
    assign issued_beat = can_issue;

    // =========================================================================
    // Capture side: each wide read IS a full beat (no pairing).
    //   The 288b word = { hi_cascade[143:0], lo_cascade[143:0] }, so:
    //     mant[0..7]  = lo[95:0]   = rd_data[95:0]
    //     mant[8..15] = hi[95:0]   = rd_data[CASCADE_HALF_W +: 96]   (= [239:144])
    //     exp         = lo[96+:8]  = rd_data[96 +: 8]
    //   This is bit-identical to the old lo/hi pairing, in one read.
    // =========================================================================
    logic [MACRO_CNT_W-1:0] cap_beat_q;      // beat index being captured (for last)

    logic                 beat_ready;        // a full beat captured this cycle
    logic [NOC_DW-1:0]    beat_data;
    logic [NOC_UW-1:0]    beat_user;
    logic                 beat_last;
    assign beat_ready = pp.rd_valid;
    assign beat_data  = { pp.rd_data[CASCADE_HALF_W +: MANT_HALF_W],
                          pp.rd_data[MANT_HALF_W-1:0] };
    assign beat_user  = pp.rd_data[MANT_HALF_W +: BFP12_EXP_W];
    assign beat_last  = (cap_beat_q == (total_beats_q - 1));

    // =========================================================================
    // Beat FIFO (depth FIFO_DEPTH). Present drains it onto strm.src.
    // =========================================================================
    logic [NOC_DW-1:0] fifo_data [FIFO_DEPTH];
    logic [NOC_UW-1:0] fifo_user [FIFO_DEPTH];
    logic              fifo_last [FIFO_DEPTH];
    logic [$clog2(FIFO_DEPTH)-1:0] wr_ptr_q, rd_ptr_q;
    logic [CNT_W-1:0]              fifo_cnt_q;

    logic fifo_empty, fifo_full;
    assign fifo_empty = (fifo_cnt_q == '0);
    assign fifo_full  = (fifo_cnt_q == CNT_W'(FIFO_DEPTH));

    logic present_fire;
    assign present_fire = src.valid && src.ready;

    assign src.valid = !fifo_empty;
    assign src.data  = fifo_data[rd_ptr_q];
    assign src.user  = fifo_user[rd_ptr_q];
    assign src.last  = fifo_last[rd_ptr_q];

    assign gemm.beat_fire = present_fire;

    // present-side beat counter -> op completion
    logic [MACRO_CNT_W-1:0] pres_beat_q;
    logic op_done;
    assign op_done = running_q && (pres_beat_q == total_beats_q);

    // =========================================================================
    // Drive ping-pong read port + drain ack.
    // =========================================================================
    logic drain_ack_q;
    always_ff @(posedge clk) begin
        if (!rst_n) drain_ack_q <= 1'b0;
        else        drain_ack_q <= pp.drain_req && !drain_ack_q;
    end

    always_comb begin
        pp.rd_en     = can_issue;
        pp.rd_addr   = issue_addr;
        pp.drain_ack = drain_ack_q;
    end

    // =========================================================================
    // Sequential
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            running_q     <= 1'b0;
            total_beats_q <= '0;
            beat_stride_q <= URAM_ADDR_W'(2);
            iss_beat_q    <= '0;
            iss_base_q    <= '0;
            outstanding_q <= '0;
            cap_beat_q    <= '0;
            wr_ptr_q      <= '0;
            rd_ptr_q      <= '0;
            fifo_cnt_q    <= '0;
            pres_beat_q   <= '0;
        end else begin
            // ---- Op start: latch budget/stride and reset pointers ------------
            if (op_start) begin
                running_q     <= 1'b1;
                if (gemm.stream_mode == GEMM_SNAP_CONTINUOUS) begin
                    total_beats_q <= MACRO_CNT_W'(gemm.batch_n);
                    beat_stride_q <= token_stride;
                end else begin
                    total_beats_q <= gemm.k_cnt;
                    beat_stride_q <= URAM_ADDR_W'(2);
                end
                iss_beat_q    <= '0;
                iss_base_q    <= base_addr;
                outstanding_q <= '0;
                cap_beat_q    <= '0;
                pres_beat_q   <= '0;
                // FIFO ptrs/cnt are already drained to 0 by the prior op's
                // completion (op cannot restart until fully presented + idle).
            end

            // ---- Issue: one wide read per beat -------------------------------
            if (can_issue) begin
                iss_beat_q <= iss_beat_q + 1'b1;
                iss_base_q <= iss_base_q + beat_stride_q;
            end

            // ---- Capture: each wide read is a full beat ----------------------
            if (pp.rd_valid) begin
                cap_beat_q <= cap_beat_q + 1'b1;
            end

            // ---- Outstanding beats (issued reads vs presented beats) ---------
            // +1 when a beat's reads finish issuing (the hi half), -1 on present.
            // Bounds FIFO + in-flight so the beat FIFO can never overflow.
            outstanding_q <= outstanding_q
                           + (issued_beat  ? { {CNT_W{1'b0}}, 1'b1 } : '0)
                           - (present_fire ? { {CNT_W{1'b0}}, 1'b1 } : '0);

            // ---- FIFO push (assembled beat) ----------------------------------
            if (beat_ready) begin
                fifo_data[wr_ptr_q] <= beat_data;
                fifo_user[wr_ptr_q] <= beat_user;
                fifo_last[wr_ptr_q] <= beat_last;
                wr_ptr_q <= (wr_ptr_q == ($clog2(FIFO_DEPTH))'(FIFO_DEPTH-1))
                          ? '0 : wr_ptr_q + 1'b1;
            end

            // ---- FIFO pop (present) ------------------------------------------
            if (present_fire) begin
                rd_ptr_q <= (rd_ptr_q == ($clog2(FIFO_DEPTH))'(FIFO_DEPTH-1))
                          ? '0 : rd_ptr_q + 1'b1;
                pres_beat_q <= pres_beat_q + 1'b1;
            end

            // ---- FIFO occupancy ----------------------------------------------
            fifo_cnt_q <= fifo_cnt_q
                        + (beat_ready   ? CNT_W'(1) : CNT_W'(0))
                        - (present_fire ? CNT_W'(1) : CNT_W'(0));

            // ---- Op completion: all beats presented; wait for busy to drop ---
            if (op_done && !gemm.busy) begin
                running_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    // Never emit a beat when gemm is not busy.
    a_no_fire_outside_busy: assert property (
        @(posedge clk) disable iff (!rst_n) present_fire |-> gemm.busy
    ) else $error("dense_act_streamer: src fired while gemm.busy=0");

    // last only on the final beat of the op's beat budget.
    a_last_only_on_final: assert property (
        @(posedge clk) disable iff (!rst_n)
        (present_fire && src.last) |-> (pres_beat_q == (total_beats_q - 1))
    ) else $error("dense_act_streamer: src.last asserted on non-final beat");

    // FIFO never overflows / underflows.
    a_fifo_no_overflow: assert property (
        @(posedge clk) disable iff (!rst_n) !(beat_ready && fifo_full && !present_fire)
    ) else $error("dense_act_streamer: beat FIFO overflow");
    a_fifo_no_underflow: assert property (
        @(posedge clk) disable iff (!rst_n) present_fire |-> !fifo_empty
    ) else $error("dense_act_streamer: present from empty FIFO");
`endif

endmodule : dense_act_streamer

`default_nettype wire
`endif // ARCHBETTER_DENSE_ACT_STREAMER_SV
