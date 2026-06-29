// -----------------------------------------------------------------------------
// dense_weight_streamer.sv  (Phase-8, Stage 8b)
//
// Per-tile weight loader: on a dense_sched_if load_req for logical tile
// (tile_gr, tile_gc), reads that tile's 512 BFP12 weight mantissas from the
// dense URAM ping-pong and scans them into the two physical dense_group PE
// register files over the w_* scan bus. This is the URAM->PE weight path that
// the Phase-7 harness drove from host ports (w_we / w_phys_gc / w_pe_addr /
// w_in) — internalizing it is what closes the dense loop for OOC (the dangling
// host scan port was a primary pruning cause; see CLAUDE.md sec 2.2 dataflow,
// step 1: "Weights ... are streamed from the dense URAM ping-pong into the
// physical kernel's PE registers").
//
// Mirror of dense_act_streamer's URAM-read idiom, but:
//   * data flows OUT to the array scan port (not onto a NoC source),
//   * the handshake is the dense_sched_if load_req/load_busy/load_done channel
//     (walker drives req+busy, this module drives done), not gemm_issue_if.
//
// Weight storage layout in the dense URAM (per tile, WORDS_PER_TILE = 64
// consecutive cascaded words starting at the tile base):
//
//   word[w][ 11:  0] = weight mantissa for PE (8*w + 0)
//   word[w][ 23: 12] = weight mantissa for PE (8*w + 1)
//   ...
//   word[w][ 95: 84] = weight mantissa for PE (8*w + 7)   (8 * 12 = 96b)
//   word[w][143: 96] = unused                              (48b padding)
//
// The global PE index pe_global = 8*w + slot runs 0..511; it maps to the scan
// port as:
//   w_phys_gc = pe_global[8]      (0 => physical group 0, 1 => group 1)
//   w_pe_addr = pe_global[7:0]    (PE index within the 256-PE group)
// The data-prep / golden image is responsible for laying weights out in this
// {phys_gc, pe_addr} raster order; this module is a pure transport.
//
// Tile base address:
//   tile_linear = tile_gr * DENSE_LOGICAL_TILE_COLS + tile_gc   (0..31)
//   tile_word_base = base_addr + tile_linear * WORDS_PER_TILE
//
// Latency contract:
//   load_req (with load_busy) -> ... -> load_done is a 1-cycle pulse after the
//   final scan write. Worst case ~ WORDS_PER_TILE * (rd_latency + 8) cycles;
//   the scan is dispatcher-paced and hidden under the URAM ping-pong fill, so
//   no continuous-throughput requirement applies (unlike the activation path).
//
// Note (Stage 8e): the dense URAM read port is SHARED with dense_act_streamer.
// Weight-load (this module) and activation-stream are TEMPORALLY EXCLUSIVE per
// the tile flow (load weights, then stream activations), so the top muxes the
// single pingpong_if.core read port between the two phases. In isolation (this
// module + its TB) the streamer simply owns a pingpong_if.core.
//
// Resource class:
//   * No DSP48E2.
//   * No BRAM/URAM (storage lives in the upstream pingpong).
//   * One small FSM + a 144b word register + a few counters.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE_WEIGHT_STREAMER_SV
`define ARCHBETTER_DENSE_WEIGHT_STREAMER_SV
`default_nettype none

module dense_weight_streamer
    import types_pkg::*;
#(
    parameter int unsigned PP_DATA_W = DENSE_PP_URAM_W  // 288: WIDE dense pp word
) (
    input  wire logic                    clk,
    input  wire logic                    rst_n,

    // Dense URAM weight base address for the current layer (driven by the
    // layer descriptor in integration; testbenches drive directly).
    input  wire logic [URAM_ADDR_W-1:0]  base_addr,

    // Walker <-> streamer schedule + scan bus.
    dense_sched_if.streamer              sched,

    // Dense URAM ping-pong read port.
    pingpong_if.core                     pp
);

    // -------------------------------------------------------------------------
    // Derived geometry.
    // -------------------------------------------------------------------------
    localparam int unsigned MANT_HALF_W      = BFP12_BLK * BFP12_MANT_W / 2;            // 96
    localparam int unsigned WEIGHTS_PER_WORD = MANT_HALF_W / BFP12_MANT_W;              //  8
    localparam int unsigned TILE_PE_TOTAL    = DENSE_PHYS_GROUPS_COL * DENSE_PE_PER_GROUP; // 512
    localparam int unsigned WORDS_PER_TILE   = TILE_PE_TOTAL / WEIGHTS_PER_WORD;        // 64

    // R6.8b.3: the dense pp is WIDE (288b) and holds TWO cascade words per wide
    // word. The weight scan still walks 64 cascade words/tile, but each maps to a
    // wide read at cascade_addr>>1 with the 144b half chosen by word_idx[0] (the
    // scan is dispatcher-paced and hidden, so reading each wide word twice is fine).
    localparam int unsigned CASC_HALF_W      = PP_DATA_W / 2;                           // 144

    localparam int unsigned WORD_IDX_W = $clog2(WORDS_PER_TILE);                        //  6
    localparam int unsigned SLOT_W     = $clog2(WEIGHTS_PER_WORD);                      //  3
    localparam int unsigned PE_ADDR_W  = $clog2(DENSE_PE_PER_GROUP);                    //  8
    localparam int unsigned PHYS_GC_W  = $clog2(DENSE_PHYS_GROUPS_COL);                 //  1
    localparam int unsigned GLOBAL_W   = $clog2(TILE_PE_TOTAL);                         //  9

    // -------------------------------------------------------------------------
    // Elaboration-time sanity checks.
    // -------------------------------------------------------------------------
    initial begin : geometry_check
        if (CASC_HALF_W < MANT_HALF_W) begin
            $error("dense_weight_streamer: cascade half %0d cannot hold %0d weight mantissas",
                   CASC_HALF_W, WEIGHTS_PER_WORD);
        end
        if (WORDS_PER_TILE * WEIGHTS_PER_WORD != TILE_PE_TOTAL) begin
            $error("dense_weight_streamer: tile weight count %0d not divisible by %0d/word",
                   TILE_PE_TOTAL, WEIGHTS_PER_WORD);
        end
        if (GLOBAL_W != PE_ADDR_W + PHYS_GC_W) begin
            $error("dense_weight_streamer: pe_global width %0d != pe_addr %0d + phys_gc %0d",
                   GLOBAL_W, PE_ADDR_W, PHYS_GC_W);
        end
    end

    // -------------------------------------------------------------------------
    // FSM.
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE    = 3'd0,
        S_RD      = 3'd1,  // issue one URAM read for the current word
        S_RD_WAIT = 3'd2,  // await rd_valid, capture word
        S_SCAN    = 3'd3,  // drive 8 scan writes (slot 0..7)
        S_DONE    = 3'd4   // 1-cycle load_done pulse, return to idle
    } state_e;

    state_e state_q, state_d;

    // Latched op coordinates and computed tile base.
    logic [$clog2(DENSE_LOGICAL_TILE_ROWS)-1:0] tile_gr_q;
    logic [$clog2(DENSE_LOGICAL_TILE_COLS)-1:0] tile_gc_q;
    logic [URAM_ADDR_W-1:0]                     tile_base_q;

    // Word walk (one word per scan beat, 8 PEs written in parallel).
    logic [WORD_IDX_W-1:0] word_idx_q;
    logic [PP_DATA_W-1:0]  word_q;

    // drain_ack: this module owns the pingpong .core modport, so it must drive
    // drain_ack. Weight-loads only occur between ops (never mid-load can a swap
    // be requested), so the same 1-cycle-ack-after-drain_req shape as
    // dense_act_streamer is safe.
    logic drain_ack_q;
    always_ff @(posedge clk) begin
        if (!rst_n) drain_ack_q <= 1'b0;
        else        drain_ack_q <= pp.drain_req && !drain_ack_q;
    end

    // -------------------------------------------------------------------------
    // Combinational global PE index and scan-bus drive.
    // -------------------------------------------------------------------------
    // Base global PE index for this word = word_idx * WEIGHTS_PER_WORD (8). The
    // 8 PEs of one word share the upper address bits (same phys group, same
    // local row, 8 consecutive cols), so one beat writes all 8 in parallel.
    logic [GLOBAL_W-1:0] pe_base;
    assign pe_base = GLOBAL_W'({{(GLOBAL_W-WORD_IDX_W){1'b0}}, word_idx_q} << SLOT_W);

    logic scan_active;
    assign scan_active = (state_q == S_SCAN);

    // Select the 144b cascade half of the captured wide word: even cascade words
    // (word_idx[0]==0) live in the low half, odd words in the high half.
    logic [CASC_HALF_W-1:0] word_half;
    assign word_half = word_idx_q[0] ? word_q[CASC_HALF_W +: CASC_HALF_W]
                                     : word_q[0          +: CASC_HALF_W];

    always_comb begin
        sched.w_we      = scan_active;
        sched.w_phys_gc = pe_base[PE_ADDR_W +: PHYS_GC_W];
        sched.w_pe_addr = pe_base[PE_ADDR_W-1:0];   // multiple of WEIGHTS_PER_WORD
        for (int i = 0; i < int'(WEIGHTS_PER_WORD); i++)
            sched.w_in[i] = bfp12_mant_t'(word_half[i*BFP12_MANT_W +: BFP12_MANT_W]);
    end

    // load_done is a 1-cycle pulse in S_DONE.
    assign sched.load_done = (state_q == S_DONE);

    // -------------------------------------------------------------------------
    // Ping-pong read drive. rd_en is a 1-cycle pulse in S_RD (gated on
    // side_valid, like dense_act_streamer).
    // -------------------------------------------------------------------------
    logic rd_fire;
    assign rd_fire = (state_q == S_RD) && pp.side_valid;

    always_comb begin
        pp.rd_en     = rd_fire;
        // WIDE read: cascade word (tile_base + word_idx) lives in wide word
        // (tile_base + word_idx) >> 1; the half is picked by word_idx[0] above.
        pp.rd_addr   = (tile_base_q + URAM_ADDR_W'(word_idx_q)) >> 1;
        pp.drain_ack = drain_ack_q;
    end

    // -------------------------------------------------------------------------
    // Next-state logic.
    // -------------------------------------------------------------------------
    logic last_word;
    assign last_word = (word_idx_q == WORD_IDX_W'(WORDS_PER_TILE - 1));

    always_comb begin
        state_d = state_q;
        unique case (state_q)
            S_IDLE:    state_d = sched.load_req ? S_RD : S_IDLE;
            S_RD:      state_d = rd_fire ? S_RD_WAIT : S_RD;
            S_RD_WAIT: state_d = pp.rd_valid ? S_SCAN : S_RD_WAIT;
            // One cycle writes the whole word's 8 PEs in parallel.
            S_SCAN:    state_d = last_word ? S_DONE : S_RD;
            S_DONE:    state_d = S_IDLE;
            default:   state_d = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Sequential state.
    // -------------------------------------------------------------------------
    // tile_linear = tile_gr * DENSE_LOGICAL_TILE_COLS + tile_gc (0..31).
    logic [URAM_ADDR_W-1:0] tile_linear_w;
    assign tile_linear_w =
        (URAM_ADDR_W'(sched.tile_gr) * URAM_ADDR_W'(DENSE_LOGICAL_TILE_COLS))
        + URAM_ADDR_W'(sched.tile_gc);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q     <= S_IDLE;
            tile_gr_q   <= '0;
            tile_gc_q   <= '0;
            tile_base_q <= '0;
            word_idx_q  <= '0;
            word_q      <= '0;
        end else begin
            state_q <= state_d;

            // Op start: latch coords, compute tile base, reset the walk.
            if (state_q == S_IDLE && sched.load_req) begin
                tile_gr_q   <= sched.tile_gr;
                tile_gc_q   <= sched.tile_gc;
                tile_base_q <= base_addr
                             + (tile_linear_w * URAM_ADDR_W'(WORDS_PER_TILE));
                word_idx_q  <= '0;
            end

            // Capture the fetched word.
            if (state_q == S_RD_WAIT && pp.rd_valid) begin
                word_q <= pp.rd_data;
            end

            // Advance to the next word after its single-cycle parallel scan.
            if (state_q == S_SCAN && !last_word) begin
                word_idx_q <= word_idx_q + WORD_IDX_W'(1);
            end
        end
    end

`ifndef SYNTHESIS
    // -------------------------------------------------------------------------
    // Internal sanity assertions.
    // -------------------------------------------------------------------------
    // A scan write only happens in S_SCAN, and only while the walker holds the
    // load busy (the dense_sched_if a_scan_within_load assertion cross-checks
    // load_busy; this one is the module-local view).
    a_scan_only_in_scan: assert property (
        @(posedge clk) disable iff (!rst_n) sched.w_we |-> (state_q == S_SCAN)
    ) else $error("dense_weight_streamer: w_we asserted outside S_SCAN");

    // load_done implies we just finished the final word's final slot.
    a_done_after_last: assert property (
        @(posedge clk) disable iff (!rst_n) (state_q == S_DONE) |-> $past(last_word)
    ) else $error("dense_weight_streamer: S_DONE reached before the final scan write");

    // rd_en requires side_valid (mirrors pingpong_if contract; caught here too).
    a_rd_needs_side: assert property (
        @(posedge clk) disable iff (!rst_n) pp.rd_en |-> pp.side_valid
    ) else $error("dense_weight_streamer: rd_en asserted while side_valid=0");
`endif

endmodule : dense_weight_streamer

`default_nettype wire
`endif // ARCHBETTER_DENSE_WEIGHT_STREAMER_SV
