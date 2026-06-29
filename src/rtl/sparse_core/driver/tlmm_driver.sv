// -----------------------------------------------------------------------------
// tlmm_driver.sv
//
// Phase-5b bridge: pulls a sparse-core activation tile + one or more ternary
// weight beats from the sparse URAM ping-pong read port and hands them to the
// sparse_tile via tlmm_ctrl_if. Driven from the dispatcher's tlmm_issue_if:
//
//   * tlmm.start pulses with tlmm.busy=1; we latch k_cnt (= number of weight
//     compute beats this op).
//   * We PROG the tile once per op (one activation tile stationary for the
//     whole K sweep), then issue k_cnt COMPUTE beats, draining o_parts in
//     lockstep with o_valid.
//   * When the k_cnt^th OUT beat fires we pulse tlmm.done for one cycle.
//
// URAM layout (per 144b cascaded UltraRAM read, low bits payload + padding):
//
//   PROG beat (TLMM_TILE = 16 BFP12 mantissas = 192b):
//     word[0][ 95:  0]  = mant[ 0..  7]   (8 * 12 = 96b)
//     word[1][ 95:  0]  = mant[ 8.. 15]
//     -> PROG_WORDS = 2, PROG_BITS_PER_WORD = 96
//
//   COMPUTE beat (TLMM_LANES * TLMM_TILE * 2 = 512b ternary weights):
//     word[0][127:  0]  = w[  0.. 63]      (128b = 64 ternary)
//     word[1][127:  0]  = w[ 64..127]
//     word[2][127:  0]  = w[128..191]
//     word[3][127:  0]  = w[192..255]
//     -> COMPUTE_WORDS = 4, COMPUTE_BITS_PER_WORD = 128
//   (ternary indexing: bits [l*TLMM_TILE*2 + t*2 +: 2] -> lane l, tile pos t)
//
// We keep up to 2 URAM reads in flight (same bound as dense_act_streamer) and
// consume responses in order. When all words for the current beat have
// arrived, the assembled payload is latched and presented on tlmm_ctrl_if.
//
// Resource class:
//   * No DSP48E2.
//   * No BRAM / URAM (storage lives upstream in the pingpong).
//   * One small FSM + a 512-bit assembly register + a handful of flops.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_TLMM_DRIVER_SV
`define ARCHBETTER_TLMM_DRIVER_SV
`default_nettype none

module tlmm_driver
    import types_pkg::*;
#(
    parameter int unsigned PP_DATA_W = 144  // cascaded UltraRAM pair
) (
    input  wire logic                    clk,
    input  wire logic                    rst_n,

    // URAM activation-tile base address (driven by memory_manager in
    // integration; testbenches drive directly).
    input  wire logic [URAM_ADDR_W-1:0]  base_addr,

    tlmm_issue_if.drv   tlmm,
    pingpong_if.core    pp,
    tlmm_ctrl_if.driver ctrl,

    // -- Result bus to sparse_out_collector (Phase-8) -------------------------
    // result_acc holds the per-lane whole-layer K-reduction accumulator. It is
    // final and stable on the cycle result_valid pulses (= tlmm.done): the last
    // tile-partial fold (o_fire) lands one cycle before tlmm_done_q rises, and
    // the bank is not cleared until the NEXT op's PROG_FETCH entry, so the
    // collector has a full snap window. This is the sparse analogue of the
    // dense_array's y_out / y_valid snap port.
    output tlmm_acc_vec_t result_acc,
    output logic          result_valid
);

    // -------------------------------------------------------------------------
    // Derived geometry.
    // -------------------------------------------------------------------------
    localparam int unsigned PROG_BITS_PER_WORD    = 96;
    localparam int unsigned COMPUTE_BITS_PER_WORD = 128;

    localparam int unsigned PROG_PAYLOAD_W    = TLMM_TILE * BFP12_MANT_W;      // 192
    localparam int unsigned COMPUTE_PAYLOAD_W = TLMM_LANES * TLMM_TILE * 2;    // 512

    localparam int unsigned PROG_WORDS    = (PROG_PAYLOAD_W    + PROG_BITS_PER_WORD    - 1) / PROG_BITS_PER_WORD;
    localparam int unsigned COMPUTE_WORDS = (COMPUTE_PAYLOAD_W + COMPUTE_BITS_PER_WORD - 1) / COMPUTE_BITS_PER_WORD;

    localparam int unsigned WEIGHT_BASE_OFFSET = PROG_WORDS;                    // activation tile lives before weights

    // Assembly register holds the largest payload we carry.
    localparam int unsigned ASM_W = COMPUTE_WORDS * COMPUTE_BITS_PER_WORD;      // 512

    localparam int unsigned WORDIDX_W    = $clog2(COMPUTE_WORDS + 1);            // 3
    localparam int unsigned MAX_INFLIGHT = 2;
    localparam int unsigned IFL_W        = $clog2(MAX_INFLIGHT + 1);             // 2

    // -------------------------------------------------------------------------
    // Elaboration sanity.
    // -------------------------------------------------------------------------
    initial begin : geom_check
        if (PP_DATA_W < COMPUTE_BITS_PER_WORD) begin
            $fatal(1, "tlmm_driver: PP_DATA_W=%0d must hold COMPUTE_BITS_PER_WORD=%0d",
                   PP_DATA_W, COMPUTE_BITS_PER_WORD);
        end
        if (COMPUTE_PAYLOAD_W != $bits(tern_lane_tiles_t)) begin
            $fatal(1, "tlmm_driver: COMPUTE_PAYLOAD_W=%0d != $bits(tern_lane_tiles_t)=%0d",
                   COMPUTE_PAYLOAD_W, $bits(tern_lane_tiles_t));
        end
        if (PROG_PAYLOAD_W != $bits(tlmm_tile_act_t)) begin
            $fatal(1, "tlmm_driver: PROG_PAYLOAD_W=%0d != $bits(tlmm_tile_act_t)=%0d",
                   PROG_PAYLOAD_W, $bits(tlmm_tile_act_t));
        end
    end

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE       = 3'd0,
        S_PROG_FETCH = 3'd1,  // issue/capture PROG_WORDS URAM reads
        S_PROG_PRES  = 3'd2,  // drive prog_valid, wait for prog_ready
        S_W_FETCH    = 3'd3,  // issue/capture COMPUTE_WORDS URAM reads
        S_W_PRES     = 3'd4,  // drive w_valid, wait for w_ready
        S_DRAIN      = 3'd5,  // all k_cnt compute beats accepted; wait for last OUT
        S_DONE       = 3'd6   // one-cycle tlmm.done pulse
    } state_e;

    state_e state_q, state_d;

    // Op-scoped state.
    logic [MACRO_CNT_W-1:0] k_cnt_q;
    logic [MACRO_CNT_W-1:0] beats_issued_q;   // compute beats accepted by tile
    logic [MACRO_CNT_W-1:0] beats_out_q;      // OUT beats sunk from tile

    // Per-beat fetch sub-state.
    logic [WORDIDX_W-1:0]   issue_idx_q;
    logic [WORDIDX_W-1:0]   capture_idx_q;
    logic [IFL_W-1:0]       in_flight_q;
    logic [ASM_W-1:0]       asm_q;

    // Presentation registers.
    tlmm_tile_act_t         prog_q;
    logic                   prog_valid_q;
    tern_lane_tiles_t       w_q;
    logic                   w_valid_q;
    logic                   tlmm_done_q;

    // -------------------------------------------------------------------------
    // Phase selectors.
    // -------------------------------------------------------------------------
    logic in_fetch;
    logic in_prog_fetch;
    logic in_w_fetch;
    assign in_prog_fetch = (state_q == S_PROG_FETCH);
    assign in_w_fetch    = (state_q == S_W_FETCH);
    assign in_fetch      = in_prog_fetch || in_w_fetch;

    logic [WORDIDX_W-1:0] words_needed;
    assign words_needed = in_prog_fetch ? WORDIDX_W'(PROG_WORDS)
                        : in_w_fetch    ? WORDIDX_W'(COMPUTE_WORDS)
                        :                  '0;

    logic all_captured;
    assign all_captured = (capture_idx_q == words_needed);

    // -------------------------------------------------------------------------
    // URAM read issue address.
    //   PROG  : base_addr + issue_idx
    //   W     : base_addr + WEIGHT_BASE_OFFSET + beats_issued*COMPUTE_WORDS + issue_idx
    // -------------------------------------------------------------------------
    logic [URAM_ADDR_W-1:0] base_for_phase;
    logic [URAM_ADDR_W-1:0] rd_addr_next;
    logic                   issue_now;
    logic                   capture_now;

    // drain_ack: the driver is the .core modport owner per pingpong_if, so it
    // must drive drain_ack itself. OP_PINGPONG fires only between TLMM ops
    // (after tlmm.done and busy drops), so the driver is in S_IDLE when
    // drain_req can fire. Single-cycle ack one cycle after drain_req rises,
    // matching the TB-side helper pulse used in tb_dispatcher_full.
    logic drain_ack_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            drain_ack_q <= 1'b0;
        end else begin
            drain_ack_q <= pp.drain_req && !drain_ack_q;
        end
    end

    always_comb begin
        if (in_prog_fetch) begin
            base_for_phase = base_addr;
        end else if (in_w_fetch) begin
            base_for_phase = URAM_ADDR_W'(base_addr
                           + URAM_ADDR_W'(WEIGHT_BASE_OFFSET)
                           + URAM_ADDR_W'(beats_issued_q) * URAM_ADDR_W'(COMPUTE_WORDS));
        end else begin
            base_for_phase = '0;
        end

        rd_addr_next = URAM_ADDR_W'(base_for_phase + URAM_ADDR_W'(issue_idx_q));

        issue_now = in_fetch && pp.side_valid
                 && (issue_idx_q < words_needed)
                 && (in_flight_q < IFL_W'(MAX_INFLIGHT));

        pp.rd_en     = issue_now;
        pp.rd_addr   = rd_addr_next;
        pp.drain_ack = drain_ack_q;
    end

    assign capture_now = pp.rd_valid && in_fetch;

    // -------------------------------------------------------------------------
    // ctrl outputs
    // -------------------------------------------------------------------------
    always_comb begin
        ctrl.prog_acts  = prog_q;
        ctrl.prog_valid = prog_valid_q;
        ctrl.w_tiles    = w_q;
        ctrl.w_valid    = w_valid_q;
        ctrl.o_ready    = tlmm.busy;
    end

    // -------------------------------------------------------------------------
    // Handshake fires.
    // -------------------------------------------------------------------------
    logic prog_fire;
    logic w_fire;
    logic o_fire;
    logic last_out_beat;

    assign prog_fire     = ctrl.prog_valid && ctrl.prog_ready;
    assign w_fire        = ctrl.w_valid    && ctrl.w_ready;
    assign o_fire        = ctrl.o_valid    && ctrl.o_ready;
    assign last_out_beat = o_fire && (beats_out_q == (k_cnt_q - MACRO_CNT_W'(1)));

    assign tlmm.done = tlmm_done_q;
    assign result_valid = tlmm_done_q;

    // -------------------------------------------------------------------------
    // Per-lane K-reduction accumulator for ctrl.o_parts.
    //
    // Every accepted compute beat produces a tlmm_part_vec_t (TLMM_LANES
    // tile_partials, one per output neuron lane). The whole-layer result for
    // this op is the sum of these tile_partials across all k_cnt beats - a
    // standard K-reduction in INT32 (tlmm_acc_t).
    //
    // Phase-7d note: this accumulator gives ctrl.o_parts a synthesizable load
    // (clears Synth 8-7129 on the o_parts upper bits) AND lays the groundwork
    // for the Phase-8 OUT URAM write-back. The accumulator is presented
    // unchanged across an op via tlmm_acc_q.
    //
    // Phase-8 (Stage 8d): the bank now has a real consumer — it is packed onto
    // the result_acc output and drained by sparse_out_collector on tlmm.done.
    // The former (* keep = "true" *) placeholder is therefore removed; the
    // observable output port keeps the bank live through synthesis on its own.
    // -------------------------------------------------------------------------
    tlmm_acc_t tlmm_acc_q [TLMM_LANES];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int ln = 0; ln < int'(TLMM_LANES); ln++) tlmm_acc_q[ln] <= '0;
        end else if (state_q == S_IDLE && state_d == S_PROG_FETCH) begin
            // Op start: clear all lane accumulators.
            for (int ln = 0; ln < int'(TLMM_LANES); ln++) tlmm_acc_q[ln] <= '0;
        end else if (o_fire) begin
            // Sign-extend each tile_partial (TLMM_TILE_PART_W = 17b) up to
            // tlmm_acc_t (32b) before adding into the lane accumulator.
            for (int ln = 0; ln < int'(TLMM_LANES); ln++) begin
                tlmm_acc_q[ln] <= tlmm_acc_q[ln]
                                + tlmm_acc_t'($signed(ctrl.o_parts[ln]));
            end
        end
    end

    // Pack the per-lane accumulator bank onto the result_acc output. Pure
    // combinational rename of the already-registered tlmm_acc_q (declared just
    // above, so no forward reference); result_valid is aligned to tlmm.done.
    always_comb begin
        for (int ln = 0; ln < int'(TLMM_LANES); ln++) begin
            result_acc[ln] = tlmm_acc_q[ln];
        end
    end

    // -------------------------------------------------------------------------
    // Next-state logic
    // -------------------------------------------------------------------------
    always_comb begin
        state_d = state_q;
        unique case (state_q)
            // Gate on tlmm.start (1-cycle pulse from dispatcher) rather than
            // tlmm.busy. The interface contract guarantees start |-> busy
            // (see tlmm_issue_if a_start_requires_busy), so this is semantically
            // equivalent to busy-detection but consumes start cleanly (clears
            // Synth 8-7129 unconnected-port advisory) and is more robust against
            // a stuck-busy fault path.
            S_IDLE:       if (tlmm.start)    state_d = S_PROG_FETCH;
            S_PROG_FETCH: if (all_captured)  state_d = S_PROG_PRES;
            S_PROG_PRES:  if (prog_fire)     state_d = S_W_FETCH;
            S_W_FETCH:    if (all_captured)  state_d = S_W_PRES;
            S_W_PRES:     if (w_fire) begin
                              state_d = (beats_issued_q == (k_cnt_q - MACRO_CNT_W'(1)))
                                      ? S_DRAIN : S_W_FETCH;
                          end
            S_DRAIN:      if (last_out_beat) state_d = S_DONE;
            S_DONE:                          state_d = S_IDLE;
            default:                         state_d = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Sequential state.
    // -------------------------------------------------------------------------
    logic fetch_entry;
    assign fetch_entry = ((state_q != S_PROG_FETCH) && (state_d == S_PROG_FETCH))
                      || ((state_q != S_W_FETCH)    && (state_d == S_W_FETCH));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q        <= S_IDLE;
            k_cnt_q        <= '0;
            beats_issued_q <= '0;
            beats_out_q    <= '0;
            issue_idx_q    <= '0;
            capture_idx_q  <= '0;
            in_flight_q    <= '0;
            asm_q          <= '0;
            prog_q         <= '0;
            prog_valid_q   <= 1'b0;
            w_q            <= '0;
            w_valid_q      <= 1'b0;
            tlmm_done_q    <= 1'b0;
        end else begin
            state_q <= state_d;

            // Op start: latch k_cnt and reset per-op counters.
            if (state_q == S_IDLE && state_d == S_PROG_FETCH) begin
                k_cnt_q        <= tlmm.k_cnt;
                beats_issued_q <= '0;
                beats_out_q    <= '0;
            end

            // Per-beat fetch sub-state reset on entry to a fetch phase.
            if (fetch_entry) begin
                issue_idx_q   <= '0;
                capture_idx_q <= '0;
                in_flight_q   <= '0;
            end else begin
                if (issue_now)   issue_idx_q   <= issue_idx_q   + WORDIDX_W'(1);
                if (capture_now) capture_idx_q <= capture_idx_q + WORDIDX_W'(1);
                in_flight_q <= in_flight_q
                             + (issue_now   ? IFL_W'(1) : IFL_W'(0))
                             - (capture_now ? IFL_W'(1) : IFL_W'(0));
            end

            // Fold captured URAM word into asm_q at the current capture slot.
            // Variable-base +: slice is legal SV; width is a compile-time const.
            if (capture_now) begin
                if (in_prog_fetch) begin
                    asm_q[capture_idx_q * PROG_BITS_PER_WORD +: PROG_BITS_PER_WORD]
                        <= pp.rd_data[PROG_BITS_PER_WORD-1:0];
                end else if (in_w_fetch) begin
                    asm_q[capture_idx_q * COMPUTE_BITS_PER_WORD +: COMPUTE_BITS_PER_WORD]
                        <= pp.rd_data[COMPUTE_BITS_PER_WORD-1:0];
                end
            end

            // PROG_FETCH -> PROG_PRES: latch prog payload, raise prog_valid.
            if (state_q == S_PROG_FETCH && state_d == S_PROG_PRES) begin
                for (int i = 0; i < int'(TLMM_TILE); i++) begin
                    prog_q[i] <= asm_q[i*BFP12_MANT_W +: BFP12_MANT_W];
                end
                prog_valid_q <= 1'b1;
            end

            // PROG handshake fire: drop valid.
            if (state_q == S_PROG_PRES && prog_fire) begin
                prog_valid_q <= 1'b0;
            end

            // W_FETCH -> W_PRES: latch weight payload, raise w_valid.
            if (state_q == S_W_FETCH && state_d == S_W_PRES) begin
                for (int l = 0; l < int'(TLMM_LANES); l++) begin
                    for (int t = 0; t < int'(TLMM_TILE); t++) begin
                        w_q[l][t] <= tern_weight_e'(
                            asm_q[(l*int'(TLMM_TILE) + t)*2 +: 2]
                        );
                    end
                end
                w_valid_q <= 1'b1;
            end

            // W handshake fire: drop valid, advance beats_issued.
            if (state_q == S_W_PRES && w_fire) begin
                w_valid_q      <= 1'b0;
                beats_issued_q <= beats_issued_q + MACRO_CNT_W'(1);
            end

            // Track OUT beats sunk from the tile.
            if (o_fire) begin
                beats_out_q <= beats_out_q + MACRO_CNT_W'(1);
            end

            // Done pulse: one cycle when we are entering S_DONE.
            tlmm_done_q <= (state_d == S_DONE);
        end
    end

`ifndef SYNTHESIS
    // -------------------------------------------------------------------------
    // Internal sanity assertions.
    // -------------------------------------------------------------------------
    a_in_flight_bound: assert property (
        @(posedge clk) disable iff (!rst_n) (in_flight_q <= IFL_W'(MAX_INFLIGHT))
    ) else $error("tlmm_driver: in_flight_q exceeded MAX_INFLIGHT");

    a_beats_issued_bound: assert property (
        @(posedge clk) disable iff (!rst_n)
        (state_q != S_IDLE) |-> (beats_issued_q <= k_cnt_q)
    ) else $error("tlmm_driver: beats_issued_q exceeded k_cnt_q");

    a_beats_out_bound: assert property (
        @(posedge clk) disable iff (!rst_n)
        (state_q != S_IDLE) |-> (beats_out_q <= k_cnt_q)
    ) else $error("tlmm_driver: beats_out_q exceeded k_cnt_q");

    a_done_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) tlmm.done |-> tlmm.busy
    ) else $error("tlmm_driver: done asserted while busy=0");
`endif

endmodule : tlmm_driver

`default_nettype wire
`endif // ARCHBETTER_TLMM_DRIVER_SV
