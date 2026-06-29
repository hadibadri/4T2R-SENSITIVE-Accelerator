// -----------------------------------------------------------------------------
// dense_out_collector.sv  (Phase-7d-pipeline rewrite)
//
// Phase-5c bridge: drains the dense_array's 128-column snap output into
//   (1) an on-chip OUTPUT URAM region for ST_OUT -> DRAM drain, and
//   (2) the dense2sparse_if producer port for FFN forwarding.
//
// Phase-7d-pipeline change
// ------------------------
// The original single-cycle BFP requantizer was 51 logic levels deep
// (block-select -> abs -> 16-way max -> priority encode on 44b ->
//  shared_exp compute -> 16 parallel barrel shifts of 44b -> truncate ->
//  pack 16 mantissas). Post-route timing closed at -10 ns WNS at 250 MHz;
// the path was internal to this module and dominated by carry chains. The
// requantizer is now a 5-stage pipeline:
//
//   S1  block-select + abs_val per element        (~3 logic levels)
//   S2  16-way OR-reduce of abs_vals              (~2 logic levels)
//   S3  priority encode + shared_exp compute      (~6 logic levels)
//   S4  16 parallel arith-shift + truncate to 12b (~5 logic levels)
//   S5  pack 16 x 12 = 192b beat into d2s_data_q  (~1 logic level)
//
// Each stage is registered. End-to-end latency from "first beat issued"
// to "first d2s.valid" is 5 cycles. Throughput is one beat per cycle once
// primed. The pipeline stalls only when the d2s consumer back-pressures.
//
// What stayed the same
// --------------------
// * Module port list and parameters: unchanged.
// * y_out_q snap register (5632b): unchanged.
// * URAM sink: unchanged (simple sequential writes, 1 logic level deep).
// * busy_o semantics: high from y_valid until both URAM and d2s pipelines
//   are fully drained.
// * d2s wire-level protocol: data/valid/ready/last/user, hold-on-backpressure.
// * Bit-exactness of the BFP requantization vs the original combinational
//   form. The pipelined version computes the same shared_exp and the same
//   mantissas as the reference - tb_dense_out_collector validates this.
//
// Resource impact
// ---------------
// * +5 stages of pipeline registers per beat. Per-stage cost roughly:
//     S1: 16 x 44b   blk + 16 x 44b abs + valid/idx/last ~= 1500 FFs
//     S2: 16 x 44b   blk forward + 44b max + meta        ~=  800 FFs
//     S3: 16 x 44b   blk forward + 8b exp + meta         ~=  720 FFs
//     S4: 16 x 12b   mants + 8b exp + meta               ~=  220 FFs
//     S5: existing d2s_data_q / d2s_user_q / d2s_valid_q
//   Total added: ~3200 FFs (0.7 % of 433920). Acceptable.
// * No DSPs, no BRAM, no URAM added.
//
// Discipline
// ----------
// CLAUDE.md sec 8 quality bar: correctness > methodology > timing > area.
// This rewrite trades ~3 KFF of area to fix a -10 ns timing violation that
// blocked the journal-grade frequency claim. That is the right trade.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE_OUT_COLLECTOR_SV
`define ARCHBETTER_DENSE_OUT_COLLECTOR_SV
`default_nettype none

module dense_out_collector
    import types_pkg::*;
#(
    parameter int unsigned WR_DATA_W = URAM_WIDTH_BITS  // 72
) (
    input  wire logic                              clk,
    input  wire logic                              rst_n,

    input  wire logic                              y_valid,
    input  wire array_acc_t [DENSE_ARRAY_COLS-1:0] y_out,

    input  wire logic [URAM_ADDR_W-1:0]            wr_base_addr,

    output logic                                   wr_en,
    output logic [URAM_ADDR_W-1:0]                 wr_addr,
    output logic [WR_DATA_W-1:0]                   wr_data,

    dense2sparse_if.dense                          d2s,

    output logic                                   busy_o
);

    // -------------------------------------------------------------------------
    // Elaboration consistency.
    // -------------------------------------------------------------------------
    initial begin : elab_checks
        if (WR_DATA_W < ARRAY_ACC_W) begin
            $fatal(1, "dense_out_collector: WR_DATA_W=%0d < ARRAY_ACC_W=%0d",
                   WR_DATA_W, ARRAY_ACC_W);
        end
        if ((DENSE_ARRAY_COLS % BFP12_BLK) != 0) begin
            $fatal(1, "dense_out_collector: DENSE_ARRAY_COLS=%0d not a multiple of BFP12_BLK=%0d",
                   DENSE_ARRAY_COLS, BFP12_BLK);
        end
    end

    // -------------------------------------------------------------------------
    // Derived counts.
    // -------------------------------------------------------------------------
    localparam int unsigned NUM_D2S_BEATS = DENSE_ARRAY_COLS / BFP12_BLK; // 8
    localparam int unsigned URAM_CNT_W    = $clog2(DENSE_ARRAY_COLS + 1); // 8
    localparam int unsigned D2S_CNT_W     = $clog2(NUM_D2S_BEATS + 1);    // 4
    localparam int unsigned MSB_POS_W     = $clog2(ARRAY_ACC_W + 1);      // 6

    // -------------------------------------------------------------------------
    // Snap register bank + URAM sink (unchanged from pre-pipeline version).
    // -------------------------------------------------------------------------
    array_acc_t y_out_q [DENSE_ARRAY_COLS];
    logic       have_snap_q;

    logic [URAM_CNT_W-1:0] uram_idx_q;
    logic                  uram_done;
    assign uram_done = (uram_idx_q == URAM_CNT_W'(DENSE_ARRAY_COLS));

    logic [URAM_ADDR_W-1:0] wr_base_addr_q;

    always_comb begin
        wr_en   = have_snap_q && !uram_done;
        wr_addr = URAM_ADDR_W'(wr_base_addr_q + URAM_ADDR_W'(uram_idx_q));
        wr_data = '0;
        if (wr_en) begin
            wr_data[ARRAY_ACC_W-1:0] = y_out_q[uram_idx_q[URAM_CNT_W-2:0]];
        end
    end

    // -------------------------------------------------------------------------
    // BFP12 requantizer helpers (combinational primitives, used inside one
    // pipeline stage each).
    // -------------------------------------------------------------------------
    function automatic logic [ARRAY_ACC_W-1:0] abs_val (input array_acc_t v);
        logic [ARRAY_ACC_W-1:0] raw;
        raw = v;
        return (v < 0) ? ((~raw) + 1'b1) : raw;
    endfunction

    function automatic logic [MSB_POS_W-1:0] find_msb_pos (
        input logic [ARRAY_ACC_W-1:0] w
    );
        logic [MSB_POS_W-1:0] pos;
        pos = '0;
        for (int b = ARRAY_ACC_W-1; b >= 0; b--) begin
            if (w[b]) begin
                pos = MSB_POS_W'(b);
                break;
            end
        end
        return pos;
    endfunction

    // -------------------------------------------------------------------------
    // d2s back-pressure stall: the entire pipeline holds when the output
    // beat has been computed but the consumer is not ready. All five stages
    // share `adv` so a stall freezes everything cleanly without overwriting
    // in-flight data. d2s_valid_q is registered at S5; when held high during
    // a stall, d2s_data_q / d2s_user_q / d2s_last_q must remain stable
    // (hold-on-backpressure invariant on dense2sparse_if).
    // -------------------------------------------------------------------------
    logic                         d2s_valid_q;
    logic [BFP12_BLK*BFP12_MANT_W-1:0] d2s_data_q;
    logic [BFP12_EXP_W-1:0]       d2s_user_q;
    logic                         d2s_last_q;

    logic stall;
    logic adv;
    assign stall = d2s_valid_q && !d2s.ready;
    assign adv   = !stall;

    assign d2s.valid = d2s_valid_q;
    assign d2s.data  = d2s_data_q;
    assign d2s.user  = d2s_user_q;
    assign d2s.last  = d2s_last_q;

    // -------------------------------------------------------------------------
    // Pipeline issue: d2s_issue_idx_q counts beats issued INTO S1 (0..8).
    // When it reaches NUM_D2S_BEATS, no more beats are issued, but the in-
    // flight beats continue to drain through S2..S5.
    // -------------------------------------------------------------------------
    logic [D2S_CNT_W-1:0] d2s_issue_idx_q;
    logic                 issue_now;
    assign issue_now = have_snap_q
                    && (d2s_issue_idx_q != D2S_CNT_W'(NUM_D2S_BEATS))
                    && adv;

    // -------------------------------------------------------------------------
    // Stage 1 — block select + abs_val per element
    // -------------------------------------------------------------------------
    logic                   s1_v_q;
    logic [D2S_CNT_W-1:0]   s1_idx_q;
    logic                   s1_last_q;
    array_acc_t             s1_blk_q  [BFP12_BLK];
    logic [ARRAY_ACC_W-1:0] s1_abs_q  [BFP12_BLK];

    array_acc_t             s1_blk_w  [BFP12_BLK];
    logic [ARRAY_ACC_W-1:0] s1_abs_w  [BFP12_BLK];
    always_comb begin
        for (int i = 0; i < int'(BFP12_BLK); i++) begin
            automatic int idx;
            idx = int'(d2s_issue_idx_q) * int'(BFP12_BLK) + i;
            s1_blk_w[i] = y_out_q[idx < int'(DENSE_ARRAY_COLS) ? idx : 0];
            s1_abs_w[i] = abs_val(s1_blk_w[i]);
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2 — 16-way OR-reduce of abs values; forward blk and metadata
    //
    // The shared exponent depends ONLY on the position of the highest set bit
    // across the 16 abs values, i.e. find_msb_pos(max_i abs_i). For unsigned
    // magnitudes, the value carrying the highest set bit *is* the maximum, and
    // a bitwise OR preserves that bit's position:
    //
    //     find_msb_pos( OR_i abs_i )  ==  find_msb_pos( max_i abs_i )
    //
    // So an OR-reduce yields the identical shared_exp as a max-reduce, but maps
    // to a ~2-level LUT6 OR tree instead of 16 chained 44-bit comparators
    // (23 CARRY8). This is the fix for the prior S1->S2 critical path
    // (-5.898 ns WNS, 44 logic levels). Bit-exact vs the golden max-based
    // reference — tb_dense_out_collector still passes unchanged.
    // -------------------------------------------------------------------------
    logic                   s2_v_q;
    logic                   s2_last_q;
    array_acc_t             s2_blk_q [BFP12_BLK];
    logic [ARRAY_ACC_W-1:0] s2_or_q;

    logic [ARRAY_ACC_W-1:0] s2_or_w;
    always_comb begin
        s2_or_w = '0;
        for (int i = 0; i < int'(BFP12_BLK); i++) begin
            s2_or_w = s2_or_w | s1_abs_q[i];
        end
    end

    // -------------------------------------------------------------------------
    // Stage 3 — priority encode -> shared_exp; forward blk
    // -------------------------------------------------------------------------
    logic            s3_v_q;
    logic            s3_last_q;
    array_acc_t      s3_blk_q [BFP12_BLK];
    bfp12_exp_t      s3_exp_q;

    logic [MSB_POS_W-1:0] s3_msb_w;
    bfp12_exp_t           s3_exp_w;
    always_comb begin
        s3_msb_w = find_msb_pos(s2_or_q);
        if (s3_msb_w > MSB_POS_W'(BFP12_MANT_W - 2)) begin
            s3_exp_w = bfp12_exp_t'(s3_msb_w - MSB_POS_W'(BFP12_MANT_W - 2));
        end else begin
            s3_exp_w = '0;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 4 — 16 parallel arith-shift + truncate to 12b mantissa
    // -------------------------------------------------------------------------
    logic         s4_v_q;
    logic         s4_last_q;
    bfp12_mant_t  s4_mants_q [BFP12_BLK];
    bfp12_exp_t   s4_exp_q;

    bfp12_mant_t  s4_mants_w [BFP12_BLK];
    always_comb begin
        for (int i = 0; i < int'(BFP12_BLK); i++) begin
            automatic array_acc_t shifted;
            shifted        = s3_blk_q[i] >>> s3_exp_q;
            s4_mants_w[i]  = bfp12_mant_t'(shifted);
        end
    end

    // -------------------------------------------------------------------------
    // Stage 5 — pack into 192b beat; this is what reaches d2s_data_q
    // -------------------------------------------------------------------------
    logic [BFP12_BLK*BFP12_MANT_W-1:0] s5_packed_w;
    always_comb begin
        s5_packed_w = '0;
        for (int i = 0; i < int'(BFP12_BLK); i++) begin
            s5_packed_w[i*BFP12_MANT_W +: BFP12_MANT_W] = s4_mants_q[i];
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline empty detector for both_done
    // -------------------------------------------------------------------------
    logic pipeline_empty;
    assign pipeline_empty = !s1_v_q && !s2_v_q && !s3_v_q && !s4_v_q
                         && !d2s_valid_q;

    logic d2s_done;
    assign d2s_done = (d2s_issue_idx_q == D2S_CNT_W'(NUM_D2S_BEATS))
                   && pipeline_empty;

    logic both_done;
    assign both_done = uram_done && d2s_done;

    assign busy_o = have_snap_q;

    // -------------------------------------------------------------------------
    // Sequential state.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < int'(DENSE_ARRAY_COLS); i++) y_out_q[i] <= '0;
            have_snap_q       <= 1'b0;
            uram_idx_q        <= '0;
            wr_base_addr_q    <= '0;
            d2s_issue_idx_q   <= '0;
            // pipeline regs
            s1_v_q     <= 1'b0; s1_idx_q  <= '0; s1_last_q <= 1'b0;
            s2_v_q     <= 1'b0; s2_last_q <= 1'b0; s2_or_q  <= '0;
            s3_v_q     <= 1'b0; s3_last_q <= 1'b0; s3_exp_q <= '0;
            s4_v_q     <= 1'b0; s4_last_q <= 1'b0; s4_exp_q <= '0;
            for (int i = 0; i < int'(BFP12_BLK); i++) begin
                s1_blk_q[i] <= '0; s1_abs_q[i] <= '0;
                s2_blk_q[i] <= '0;
                s3_blk_q[i] <= '0;
                s4_mants_q[i] <= '0;
            end
            d2s_valid_q <= 1'b0;
            d2s_data_q  <= '0;
            d2s_user_q  <= '0;
            d2s_last_q  <= 1'b0;
        end else begin
            // ---- Snap capture ----------------------------------------------
            if (y_valid && !have_snap_q) begin
                for (int i = 0; i < int'(DENSE_ARRAY_COLS); i++) begin
                    y_out_q[i] <= y_out[i];
                end
                have_snap_q     <= 1'b1;
                uram_idx_q      <= '0;
                d2s_issue_idx_q <= '0;
                wr_base_addr_q  <= wr_base_addr;
            end

            // ---- URAM sink advance (unchanged) -----------------------------
            if (wr_en) begin
                uram_idx_q <= uram_idx_q + URAM_CNT_W'(1);
            end

            // ---- Pipeline advance (gated by adv to honor d2s back-pressure)
            if (adv) begin
                // S1 input
                s1_v_q    <= issue_now;
                if (issue_now) begin
                    s1_idx_q  <= d2s_issue_idx_q;
                    s1_last_q <= (d2s_issue_idx_q == D2S_CNT_W'(NUM_D2S_BEATS - 1));
                    for (int i = 0; i < int'(BFP12_BLK); i++) begin
                        s1_blk_q[i] <= s1_blk_w[i];
                        s1_abs_q[i] <= s1_abs_w[i];
                    end
                    d2s_issue_idx_q <= d2s_issue_idx_q + D2S_CNT_W'(1);
                end

                // S2 latch
                s2_v_q    <= s1_v_q;
                s2_last_q <= s1_last_q;
                if (s1_v_q) begin
                    s2_or_q <= s2_or_w;
                    for (int i = 0; i < int'(BFP12_BLK); i++) begin
                        s2_blk_q[i] <= s1_blk_q[i];
                    end
                end

                // S3 latch
                s3_v_q    <= s2_v_q;
                s3_last_q <= s2_last_q;
                if (s2_v_q) begin
                    s3_exp_q <= s3_exp_w;
                    for (int i = 0; i < int'(BFP12_BLK); i++) begin
                        s3_blk_q[i] <= s2_blk_q[i];
                    end
                end

                // S4 latch
                s4_v_q    <= s3_v_q;
                s4_last_q <= s3_last_q;
                if (s3_v_q) begin
                    s4_exp_q <= s3_exp_q;
                    for (int i = 0; i < int'(BFP12_BLK); i++) begin
                        s4_mants_q[i] <= s4_mants_w[i];
                    end
                end

                // S5 latch -> d2s outputs
                d2s_valid_q <= s4_v_q;
                if (s4_v_q) begin
                    d2s_data_q  <= s5_packed_w;
                    d2s_user_q  <= s4_exp_q;
                    d2s_last_q  <= s4_last_q;
                end
            end

            // ---- Snap release once both sinks are fully drained ------------
            if (have_snap_q && both_done) begin
                have_snap_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    // -------------------------------------------------------------------------
    // Sanity: do not accept a new snap while busy.
    // -------------------------------------------------------------------------
    a_no_snap_while_busy: assert property (
        @(posedge clk) disable iff (!rst_n)
        y_valid |-> !have_snap_q
    ) else $error("dense_out_collector: y_valid while still draining previous snap");

    // d2s.last should pulse exactly once per snap, and only on the 8th beat.
    // The pipeline propagates s*_last_q strictly with the beat that started
    // life as `d2s_issue_idx_q == NUM_D2S_BEATS - 1`, so checking d2s_last_q
    // at d2s.valid&d2s.ready time is the right invariant.
    int unsigned last_count_q;
    always_ff @(posedge clk) begin
        if (!rst_n)                                   last_count_q <= 0;
        else if (y_valid && !have_snap_q)             last_count_q <= 0;
        else if (d2s_valid_q && d2s.ready && d2s_last_q) last_count_q <= last_count_q + 1;
    end
    a_one_last_per_snap: assert property (
        @(posedge clk) disable iff (!rst_n)
        (d2s_valid_q && d2s.ready && d2s_last_q) |-> (last_count_q == 0)
    ) else $error("dense_out_collector: d2s.last pulsed more than once per snap");
`endif

endmodule : dense_out_collector

`default_nettype wire
`endif // ARCHBETTER_DENSE_OUT_COLLECTOR_SV
