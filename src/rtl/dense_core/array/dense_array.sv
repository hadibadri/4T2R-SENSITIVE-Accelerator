// -----------------------------------------------------------------------------
// dense_array.sv  (Phase-7d refactor: time-multiplexed)
//
// Logical 128 x 128 dense compute fabric implemented PHYSICALLY as a
// 16 x 32 kernel: two `dense_group` instances side-by-side in the column
// dimension, time-multiplexed across DENSE_LOGICAL_TILES_TOTAL (= 32) logical
// tiles to cover the full 128 x 128.
//
// See CLAUDE.md sec 2.2 (load-bearing) for the rationale: a literal spatial
// 128 x 128 generate would request ~32k DSP48E2; the device has 1824. This
// refactor shrinks DSP demand 32x by trading area for time.
//
// Per-tile semantics
// ------------------
//   * The dispatcher walks the logical 8 x 4 tile grid in raster order.
//     For each tile (tile_gr, tile_gc):
//       1. Weights are scanned into the two physical groups (w_we / w_phys_gc /
//          w_pe_addr / w_in). w_phys_gc selects which of the two physical
//          column-groups receives the weight beat.
//       2. Activations for the row-band selected by tile_gr stream in via
//          a_strm (single multicast stream, fanned out internally to both
//          physical groups in lockstep).
//       3. acc_clr / acc_snap pulse exactly as for a single dense_group: clr
//          starts the reduction, snap latches the 32 group_acc_t partials.
//       4. Two cycles after acc_snap (PE acc_out_valid +1, group y_valid +1),
//          the two physical groups assert y_valid and present 32 group_acc_t
//          partials. The dense_array adds these (widened to array_acc_t) into a
//          128-wide bank slot [tile_gc_q*32 +: 32], where tile_gc_q is the
//          latched value of tile_gc at the moment of acc_snap.
//
// Layer lifecycle
// ---------------
//   * tile_first   : pulsed in the cycle the first acc_clr of the layer is
//                    issued. Synchronously clears the 128-wide bank.
//   * tile_last    : pulsed concurrently with the FINAL acc_snap of the layer.
//                    Latched alongside tile_gc; one cycle after the last
//                    bank update, y_out is driven from the bank and y_valid
//                    pulses for one cycle.
//
// Output contract
// ---------------
//   * y_out is the full 128-column array_acc_t result of the layer's
//     128 x 128 matrix-vector product.
//   * y_valid is a one-cycle pulse, 4 cycles after the FINAL acc_snap
//     (2 cycles for the coherent phys-group y_valid, 1 for the bank update,
//     1 for the drain register to settle).
//
// What stayed
// -----------
//   * The single most important invariant from CLAUDE.md sec 2.2 holds:
//     partial sums never leave the 16 x 16 group on the global interconnect.
//     Only fully-reduced 16-wide group_acc_t outputs cross the array bank
//     boundary. The bank is a register file, not a spatial reduction tree.
//   * dense_pe and dense_group are unchanged. The kernels are correct; only
//     the array harness has been redesigned.
//
// Latency
// -------
//   * Weight scan: 1 cycle per PE per phys group (serial scan-in, dispatcher-
//     paced). 256 cycles / phys group / tile in the worst case.
//   * Compute per tile: K beats + 3 fused-MACC drain cycles + 3 cycles
//     (acc_snap -> phys y_valid (+2) -> bank update (+1)). The post-snap +3 is
//     unchanged by AREG=2 (it is self-timed on real y_valid pulses, not on the
//     MACC input latency); only the pre-snap drain grew 2 -> 3.
//   * End of layer: + 1 additional cycle for the drain register.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE_ARRAY_SV
`define ARCHBETTER_DENSE_ARRAY_SV
`default_nettype none

module dense_array
    import types_pkg::*;
#(
    parameter bit          ENABLE_NOISE_HOOKS = 1'b0,
    parameter int unsigned ARRAY_ID           = 0,
    // C1.5: per-token accumulator-bank depth. BATCH_T=1 is the decode/back-compat
    // case (single 128-wide output). BATCH_T>1 enables weight-resident batched
    // GEMM: T tokens accumulate into T independent bank rows and drain as T
    // outputs. v1 keeps the bank in registers; v2 will move large-T to BRAM.
    parameter int unsigned BATCH_T            = 1,
    // Accumulator-bank storage threshold (forwarded to dense_array_bank):
    // BATCH_T <= BANK_REG_MAX -> register file (v1-identical); larger -> BRAM.
    parameter int unsigned BANK_REG_MAX       = 8
) (
    input  wire logic clk,
    input  wire logic rst_n,

    // Single 16-mantissa activation stream. Multicast internally to both
    // physical groups; the parent NoC drop is responsible for selecting the
    // correct row-band based on tile_gr (this module does NOT route activations).
    strm_if.sink                                                   a_strm,

    // Logical tile coordinates. Held stable during a tile's compute window.
    input  wire logic [$clog2(DENSE_LOGICAL_TILE_ROWS)-1:0]        tile_gr,
    input  wire logic [$clog2(DENSE_LOGICAL_TILE_COLS)-1:0]        tile_gc,

    // Batched-GEMM sideband (C1.5). tile_tok selects which bank row accumulates
    // this snap; batch_n is the runtime token count (1 = decode). Both held
    // stable across a token's compute window. For BATCH_T=1, tie tile_tok=0 and
    // batch_n=1: behaviour is identical to the pre-C1.5 single-output array.
    input  wire logic [BATCH_TOK_W-1:0]                           tile_tok,
    input  wire logic [BATCH_TOK_W-1:0]                           batch_n,

    // Drain back-pressure (C1.5). High while the downstream collector is still
    // draining the previous snap (dense_out_collector.busy_o). The batched drain
    // emits one y_valid PULSE per token only when this is low, so a slow
    // single-snap collector is never overrun. Tie 0 for an always-ready sink.
    input  wire logic                                             drain_busy,

    // Layer lifecycle pulses (see header).
    input  wire logic                                              tile_first,
    input  wire logic                                              tile_last,

    // Per-tile compute pulses. Forwarded directly to both physical groups.
    input  wire logic                                              acc_clr,
    input  wire logic                                              acc_snap,

    // Snap mode (R6 / v2). PER_TOKEN (v1): one acc_snap per token, snap-latched
    // tile_gc/tile_tok/tile_last drive the bank RMW. CONTINUOUS (v2): T token
    // beats stream at II=1; the bank RMW token/gc/last come from a result-latency-
    // aligned shift register (tok_out), one RMW per cycle. Tie PER_TOKEN for v1.
    input  wire gemm_stream_mode_e                                 stream_mode,

    // Weight programming. w_phys_gc selects which physical column-group
    // receives the weight beat (0 or 1 for DENSE_PHYS_GROUPS_COL = 2).
    input  wire logic                                              w_we,
    input  wire logic [$clog2(DENSE_PHYS_GROUPS_COL)-1:0]          w_phys_gc,
    input  wire logic [$clog2(DENSE_PE_PER_GROUP)-1:0]             w_pe_addr,
    input  wire bfp12_mant_t [(BFP12_BLK/2)-1:0]                   w_in,  // 8/word (C1.5)

    // Drained 128-column array_acc_t output (one pulse per layer).
    output array_acc_t [DENSE_ARRAY_COLS-1:0]                      y_out,
    output logic                                                   y_valid,

    // High from a layer's GEMM start (tile_first) through its FINAL drain pulse.
    // Unlike the collector's per-snap busy (which dips between tokens), this stays
    // asserted across the whole batched drain, so a dispatcher barrier OR'd with
    // the collector busy never advances mid-batch. Leave unconnected if unused.
    output logic                                                   drain_active
);

    localparam int unsigned PHYS_COLS  = DENSE_PHYS_COLS;                       // 32
    localparam int unsigned TILE_GC_W  = $clog2(DENSE_LOGICAL_TILE_COLS);       //  2

    // -------------------------------------------------------------------------
    // 1. Stream multicast: forward parent a_strm to per-phys-group inner
    //    strm_if instances. Each dense_group always-readys its sink port by
    //    contract, so the parent ready can be tied 1 unconditionally.
    // -------------------------------------------------------------------------
    strm_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W))
        inner_strm [DENSE_PHYS_GROUPS_COL] (.clk(clk), .rst_n(rst_n));

    for (genvar PG0 = 0; PG0 < int'(DENSE_PHYS_GROUPS_COL); PG0++) begin : gen_strm_fanout
        assign inner_strm[PG0].valid = a_strm.valid;
        assign inner_strm[PG0].data  = a_strm.data;
        assign inner_strm[PG0].user  = a_strm.user;
        assign inner_strm[PG0].last  = a_strm.last;
        // inner_strm[PG0].ready is driven by dense_group (always 1 by contract)
        // and intentionally left unobserved here.
    end

    assign a_strm.ready = 1'b1;

    // -------------------------------------------------------------------------
    // 2. Two physical dense_group instances, side-by-side in the column dim.
    //    gp[0] handles physical cols [0 .. DENSE_GROUP_COLS-1].
    //    gp[1] handles physical cols [DENSE_GROUP_COLS .. PHYS_COLS-1].
    // -------------------------------------------------------------------------
    group_acc_t [DENSE_GROUP_COLS-1:0] gp_y_out   [DENSE_PHYS_GROUPS_COL];
    logic                              gp_y_valid [DENSE_PHYS_GROUPS_COL];

    for (genvar PG = 0; PG < int'(DENSE_PHYS_GROUPS_COL); PG++) begin : gen_phys
        logic w_we_local;
        assign w_we_local = w_we
                         && (w_phys_gc == ($clog2(DENSE_PHYS_GROUPS_COL))'(PG));

        dense_group #(
            .ENABLE_NOISE_HOOKS (ENABLE_NOISE_HOOKS),
            .GROUP_ID           (ARRAY_ID * DENSE_PHYS_GROUPS_COL + PG)
        ) u_gp (
            .clk      (clk),
            .rst_n    (rst_n),
            .a_strm   (inner_strm[PG]),
            .acc_clr  (acc_clr),
            .acc_snap (acc_snap),
            .stream_mode (stream_mode),
            .w_we     (w_we_local),
            .w_addr   (w_pe_addr),
            .w_in     (w_in),
            .y_out    (gp_y_out[PG]),
            .y_valid  (gp_y_valid[PG])
        );
    end

    // -------------------------------------------------------------------------
    // 3. Compose the 32-wide physical strip from the two phys groups; widen
    //    to array_acc_t for the bank accumulation (bank is signed 44b, group
    //    output is signed 40b, sign-extend happens implicitly through the
    //    assignment).
    // -------------------------------------------------------------------------
    array_acc_t [PHYS_COLS-1:0] phys_strip;
    always_comb begin
        for (int pc = 0; pc < int'(DENSE_GROUP_COLS); pc++) begin
            phys_strip[pc]                      = array_acc_t'(gp_y_out[0][pc]);
            phys_strip[DENSE_GROUP_COLS + pc]   = array_acc_t'(gp_y_out[1][pc]);
        end
    end

    // -------------------------------------------------------------------------
    // 4. Snap-aligned latches: tile_gc / tile_last latched on acc_snap and HELD
    //    until the phys groups present their result. The dense_group output
    //    latency is acc_snap -> PE acc_out_valid (+1 cycle) -> group y_valid
    //    (+2 cycles), so the bank update is gated directly on the coherent
    //    gp_y_valid pulse rather than on a fixed guess of that latency. By the
    //    time gp_y_valid arrives, tile_gc_q / tile_last_q still hold the values
    //    latched at this tile's acc_snap (snaps are spaced far wider than 2
    //    cycles), so the bank sees the correct slice index and lifecycle bit.
    // -------------------------------------------------------------------------
    logic                   tile_last_q;
    logic [TILE_GC_W-1:0]   tile_gc_q;
    logic [BATCH_TOK_W-1:0] tile_tok_q;
    logic                   tile_first_touch_q;   // first row-band (tile_gr==0)

    // First-touch = this beat's tile is the first row-band (tile_gr==0). The BRAM
    // bank LOADs (vs accumulates) on first-touch, replacing the impossible bulk
    // clear; the register bank ignores it (bulk clear handles reset).
    logic tile_first_touch;
    assign tile_first_touch = (tile_gr == '0);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tile_gc_q          <= '0;
            tile_last_q        <= 1'b0;
            tile_tok_q         <= '0;
            tile_first_touch_q <= 1'b0;
        end else if (acc_snap) begin
            tile_gc_q          <= tile_gc;
            tile_last_q        <= tile_last;
            tile_tok_q         <= tile_tok;
            tile_first_touch_q <= tile_first_touch;
        end
    end

    // -------------------------------------------------------------------------
    // 4b. tok_out alignment pipeline (R6 / v2 continuous).
    //
    //   In CONTINUOUS mode there is no per-token acc_snap to latch on. A complete
    //   16-wide partial falls out of the pipe every cycle; the partial emerging
    //   at bank_update_now belongs to the beat that ENTERED the array exactly
    //   DENSE_CONT_RESULT_LAT cycles earlier (a_fire -> acc_valid +4 -> pe snap
    //   +1 -> group y_valid +1 = +6, validated bit-exact at the group level in
    //   R6.2). So {tile_tok, tile_gc, tile_last} are pushed through a LAT-deep
    //   shift register; stage [LAT-1] is the value LAT cycles old, which is the
    //   token/strip/lifecycle of the beat whose result is landing now.
    //
    //   The shift is UNCONDITIONAL (wall-clock), which is correct even with
    //   stream bubbles: bank_update_now only pulses for a real beat, and that
    //   beat entered exactly LAT cycles ago, so stage [LAT-1] holds its sideband
    //   regardless of intervening idle cycles. Stale sidebands shifted in after a
    //   tile's last beat only reach [LAT-1] once bank_update_now has gone quiet.
    // -------------------------------------------------------------------------
    localparam int unsigned TOK_LAT = DENSE_CONT_RESULT_LAT;   // 6
    logic [BATCH_TOK_W-1:0] tok_pipe   [TOK_LAT];
    logic [TILE_GC_W-1:0]   gc_pipe    [TOK_LAT];
    logic                   last_pipe  [TOK_LAT];
    logic                   first_pipe [TOK_LAT];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < int'(TOK_LAT); i++) begin
                tok_pipe[i]   <= '0;
                gc_pipe[i]    <= '0;
                last_pipe[i]  <= 1'b0;
                first_pipe[i] <= 1'b0;
            end
        end else begin
            tok_pipe[0]   <= tile_tok;
            gc_pipe[0]    <= tile_gc;
            last_pipe[0]  <= tile_last;
            first_pipe[0] <= tile_first_touch;
            for (int i = 1; i < int'(TOK_LAT); i++) begin
                tok_pipe[i]   <= tok_pipe[i-1];
                gc_pipe[i]    <= gc_pipe[i-1];
                last_pipe[i]  <= last_pipe[i-1];
                first_pipe[i] <= first_pipe[i-1];
            end
        end
    end

    // Unified bank-update sideband: snap-latched in v1, latency-aligned in v2.
    logic [BATCH_TOK_W-1:0] upd_tok;
    logic [TILE_GC_W-1:0]   upd_gc;
    logic                   upd_last;
    logic                   upd_first;
    always_comb begin
        if (stream_mode == GEMM_SNAP_CONTINUOUS) begin
            upd_tok   = tok_pipe  [TOK_LAT-1];
            upd_gc    = gc_pipe   [TOK_LAT-1];
            upd_last  = last_pipe [TOK_LAT-1];
            upd_first = first_pipe[TOK_LAT-1];
        end else begin
            upd_tok   = tile_tok_q;
            upd_gc    = tile_gc_q;
            upd_last  = tile_last_q;
            upd_first = tile_first_touch_q;
        end
    end

    // -------------------------------------------------------------------------
    // 5+6. Output-stationary accumulator bank + drain (dense_array_bank).
    //    bank_update_now (both phys groups coherent y_valid) clocks one 32-wide
    //    partial into bank[upd_tok][upd_gc-strip]; upd_first selects load vs
    //    accumulate (BRAM path); the final upd_last triggers the per-token drain.
    //    Storage (register vs BRAM) is chosen by BATCH_T vs BANK_REG_MAX inside
    //    the submodule; for BATCH_T <= BANK_REG_MAX the behaviour is byte-identical
    //    to the original inline register bank.
    // -------------------------------------------------------------------------
    logic bank_update_now;
    assign bank_update_now = gp_y_valid[0] && gp_y_valid[1];

    dense_array_bank #(
        .ARRAY_ID     (ARRAY_ID),
        .BATCH_T      (BATCH_T),
        .BANK_REG_MAX (BANK_REG_MAX)
    ) u_bank (
        .clk          (clk),
        .rst_n        (rst_n),
        .tile_first   (tile_first),
        .upd_valid    (bank_update_now),
        .upd_tok      (upd_tok),
        .upd_gc       (upd_gc),
        .upd_last     (upd_last),
        .upd_first    (upd_first),
        .phys_strip   (phys_strip),
        .batch_n      (batch_n),
        .drain_busy   (drain_busy),
        .y_out        (y_out),
        .y_valid      (y_valid),
        .drain_active (drain_active)
    );

    // -------------------------------------------------------------------------
    // 7. Contract assertions (batch_n/upd_tok range checks live in the bank).
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    // Mutex: weight programming and stream activity should not overlap (any
    // group's stream beats are corrupted if a w_we lands during a beat).
    a_no_wwe_with_stream: assert property (
        @(posedge clk) disable iff (!rst_n)
        !(w_we && a_strm.valid && a_strm.ready)
    ) else $error("dense_array[%0d]: w_we during an activation beat", ARRAY_ID);

    // Both phys groups must co-assert y_valid (they share acc_snap).
    a_yvalid_coherent: assert property (
        @(posedge clk) disable iff (!rst_n)
        (gp_y_valid[0] || gp_y_valid[1]) |-> (gp_y_valid[0] && gp_y_valid[1])
    ) else $error("dense_array[%0d]: y_valid pulses not coherent across phys groups",
                  ARRAY_ID);

    // tile_gc must stay stable across a tile's compute window (between
    // acc_clr and acc_snap inclusive). We approximate by checking that
    // tile_gc does not change during a stream beat.
    a_tile_gc_stable_in_stream: assert property (
        @(posedge clk) disable iff (!rst_n)
        (a_strm.valid && a_strm.ready) |-> ##1 $stable(tile_gc) || tile_first
    ) else $error("dense_array[%0d]: tile_gc changed mid-tile", ARRAY_ID);
`endif

endmodule : dense_array

`default_nettype wire
`endif // ARCHBETTER_DENSE_ARRAY_SV
