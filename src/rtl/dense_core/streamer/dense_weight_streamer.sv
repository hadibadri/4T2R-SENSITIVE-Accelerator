
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE_WEIGHT_STREAMER_SV
`define ARCHBETTER_DENSE_WEIGHT_STREAMER_SV
`default_nettype none

module dense_weight_streamer
    import types_pkg::*;
#(
    parameter int unsigned PP_DATA_W = DENSE_PP_URAM_W
) (
    input  wire logic                    clk,
    input  wire logic                    rst_n,
    input  wire logic [URAM_ADDR_W-1:0]  base_addr,
    dense_sched_if.streamer              sched,
    pingpong_if.core                     pp
);
    localparam int unsigned MANT_HALF_W      = BFP12_BLK * BFP12_MANT_W / 2;
    localparam int unsigned WEIGHTS_PER_WORD = MANT_HALF_W / BFP12_MANT_W;
    localparam int unsigned TILE_PE_TOTAL    = DENSE_PHYS_GROUPS_COL * DENSE_PE_PER_GROUP;
    localparam int unsigned WORDS_PER_TILE   = TILE_PE_TOTAL / WEIGHTS_PER_WORD;
    localparam int unsigned CASC_HALF_W      = PP_DATA_W / 2;

    localparam int unsigned WORD_IDX_W = $clog2(WORDS_PER_TILE);
    localparam int unsigned SLOT_W     = $clog2(WEIGHTS_PER_WORD);
    localparam int unsigned PE_ADDR_W  = $clog2(DENSE_PE_PER_GROUP);
    localparam int unsigned PHYS_GC_W  = $clog2(DENSE_PHYS_GROUPS_COL);
    localparam int unsigned GLOBAL_W   = $clog2(TILE_PE_TOTAL);
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
    typedef enum logic [2:0] {
        S_IDLE    = 3'd0,
        S_RD      = 3'd1,
        S_RD_WAIT = 3'd2,
        S_SCAN    = 3'd3,
        S_DONE    = 3'd4
    } state_e;

    state_e state_q, state_d;
    logic [$clog2(DENSE_LOGICAL_TILE_ROWS)-1:0] tile_gr_q;
    logic [$clog2(DENSE_LOGICAL_TILE_COLS)-1:0] tile_gc_q;
    logic [URAM_ADDR_W-1:0]                     tile_base_q;
    logic [WORD_IDX_W-1:0] word_idx_q;
    logic [PP_DATA_W-1:0]  word_q;
    logic drain_ack_q;
    always_ff @(posedge clk) begin
        if (!rst_n) drain_ack_q <= 1'b0;
        else        drain_ack_q <= pp.drain_req && !drain_ack_q;
    end
    logic [GLOBAL_W-1:0] pe_base;
    assign pe_base = GLOBAL_W'({{(GLOBAL_W-WORD_IDX_W){1'b0}}, word_idx_q} << SLOT_W);

    logic scan_active;
    assign scan_active = (state_q == S_SCAN);
    logic [CASC_HALF_W-1:0] word_half;
    assign word_half = word_idx_q[0] ? word_q[CASC_HALF_W +: CASC_HALF_W]
                                     : word_q[0          +: CASC_HALF_W];

    always_comb begin
        sched.w_we      = scan_active;
        sched.w_phys_gc = pe_base[PE_ADDR_W +: PHYS_GC_W];
        sched.w_pe_addr = pe_base[PE_ADDR_W-1:0];
        for (int i = 0; i < int'(WEIGHTS_PER_WORD); i++)
            sched.w_in[i] = bfp12_mant_t'(word_half[i*BFP12_MANT_W +: BFP12_MANT_W]);
    end
    assign sched.load_done = (state_q == S_DONE);
    logic rd_fire;
    assign rd_fire = (state_q == S_RD) && pp.side_valid;

    always_comb begin
        pp.rd_en     = rd_fire;
        pp.rd_addr   = (tile_base_q + URAM_ADDR_W'(word_idx_q)) >> 1;
        pp.drain_ack = drain_ack_q;
    end
    logic last_word;
    assign last_word = (word_idx_q == WORD_IDX_W'(WORDS_PER_TILE - 1));

    always_comb begin
        state_d = state_q;
        unique case (state_q)
            S_IDLE:    state_d = sched.load_req ? S_RD : S_IDLE;
            S_RD:      state_d = rd_fire ? S_RD_WAIT : S_RD;
            S_RD_WAIT: state_d = pp.rd_valid ? S_SCAN : S_RD_WAIT;
            S_SCAN:    state_d = last_word ? S_DONE : S_RD;
            S_DONE:    state_d = S_IDLE;
            default:   state_d = S_IDLE;
        endcase
    end
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
            if (state_q == S_IDLE && sched.load_req) begin
                tile_gr_q   <= sched.tile_gr;
                tile_gc_q   <= sched.tile_gc;
                tile_base_q <= base_addr
                             + (tile_linear_w * URAM_ADDR_W'(WORDS_PER_TILE));
                word_idx_q  <= '0;
            end
            if (state_q == S_RD_WAIT && pp.rd_valid) begin
                word_q <= pp.rd_data;
            end
            if (state_q == S_SCAN && !last_word) begin
                word_idx_q <= word_idx_q + WORD_IDX_W'(1);
            end
        end
    end

`ifndef SYNTHESIS
    a_scan_only_in_scan: assert property (
        @(posedge clk) disable iff (!rst_n) sched.w_we |-> (state_q == S_SCAN)
    ) else $error("dense_weight_streamer: w_we asserted outside S_SCAN");
    a_done_after_last: assert property (
        @(posedge clk) disable iff (!rst_n) (state_q == S_DONE) |-> $past(last_word)
    ) else $error("dense_weight_streamer: S_DONE reached before the final scan write");
    a_rd_needs_side: assert property (
        @(posedge clk) disable iff (!rst_n) pp.rd_en |-> pp.side_valid
    ) else $error("dense_weight_streamer: rd_en asserted while side_valid=0");
`endif

endmodule : dense_weight_streamer

`default_nettype wire
`endif
