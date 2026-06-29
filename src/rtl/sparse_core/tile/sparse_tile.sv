// -----------------------------------------------------------------------------
// sparse_tile.sv
//
// TLMM sparse-core tile: one activation-stationary, LUTRAM-based evaluator of
// ternary dot-products across TLMM_LANES parallel output neurons.
//
// For one compute beat, for one lane l, the tile computes
//
//    tile_partial[l] = Sigma_s ( T[l][s][pos_mask[l][s]] - T[l][s][neg_mask[l][s]] )
//
// where
//    T[l][s][m] = Sigma_{i : m[i]=1} acts[s*TLMM_SUBTILE + i]        ("subset sum")
//    pos_mask[l][s][i] = (w_tiles[l][s*TLMM_SUBTILE + i] == TERN_POS)
//    neg_mask[l][s][i] = (w_tiles[l][s*TLMM_SUBTILE + i] == TERN_NEG)
//
// Sub-tables live in per-(lane, sub-tile) distributed LUTRAM, instantiated via
// a generate block so each RAM is its own 16x14 primitive (RAM16X1D-class):
// one synchronous write, two asynchronous reads per cycle. Lane replication
// buys the read-port bandwidth each lane needs. Zero DSP48E2.
//
// Latency contract:
//   PROG    : prog_valid && prog_ready fires once. The tile then spends
//             exactly TLMM_SUBTABLE_DEPTH (=16) cycles filling all sub-tables
//             before w_ready rises.
//   COMPUTE : 2 cycles from a w_valid && w_ready handshake to the matching
//             o_valid && o_ready beat (R0 register -> comb eval -> R1 output).
//             Under backpressure on o_ready, both stages hold; the output
//             register is the one allowed skid slot, so throughput dips at
//             most one beat per stall and order is preserved.
//
// Contract assertions are on tlmm_ctrl_if itself.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_SPARSE_TILE_SV
`define ARCHBETTER_SPARSE_TILE_SV
`default_nettype none

module sparse_tile
    import types_pkg::*;
(
    input  wire logic  clk,
    input  wire logic  rst_n,
    tlmm_ctrl_if.tile  ctrl
);

    // -------------------------------------------------------------------------
    // Local derived widths / enums
    // -------------------------------------------------------------------------
    localparam int unsigned FILL_CNT_W = TLMM_SUBTABLE_ADDR_W; // 4

    typedef enum logic {
        ST_IDLE = 1'b0,  // ready for PROG (if pipeline drained) or COMPUTE
        ST_FILL = 1'b1   // sweeping fill_addr 0..15, writing all sub-tables
    } state_e;

    state_e                state, state_n;
    logic [FILL_CNT_W-1:0] fill_addr;
    tlmm_tile_act_t        acts_lat;

    // -------------------------------------------------------------------------
    // Output-side backpressure flow control (1-deep pipeline + 1-deep output)
    // -------------------------------------------------------------------------
    tern_lane_tiles_t r0_w;
    logic             r0_valid;

    tlmm_part_vec_t   o_parts_q;
    logic             o_valid_q;

    logic r1_can_accept, r0_can_accept;
    assign r1_can_accept = !o_valid_q || ctrl.o_ready;
    assign r0_can_accept = !r0_valid  || r1_can_accept;

    // -------------------------------------------------------------------------
    // Phase-aware handshake ready signals.
    //   w_ready    : only in ST_IDLE with pipeline room.
    //   prog_ready : only in ST_IDLE AND the compute pipeline is fully empty.
    // -------------------------------------------------------------------------
    logic w_fire, prog_fire;
    assign ctrl.w_ready    = (state == ST_IDLE) && r0_can_accept;
    assign ctrl.prog_ready = (state == ST_IDLE) && !r0_valid && !o_valid_q;
    assign w_fire          = ctrl.w_valid    && ctrl.w_ready;
    assign prog_fire       = ctrl.prog_valid && ctrl.prog_ready;

    // -------------------------------------------------------------------------
    // Fill FSM
    // -------------------------------------------------------------------------
    always_comb begin
        state_n = state;
        unique case (state)
            ST_IDLE: if (prog_fire)                         state_n = ST_FILL;
            ST_FILL: if (fill_addr == {FILL_CNT_W{1'b1}})   state_n = ST_IDLE;
            default:                                         state_n = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            fill_addr <= '0;
        end else begin
            state <= state_n;
            if (state == ST_FILL) fill_addr <= fill_addr + FILL_CNT_W'(1);
            else                  fill_addr <= '0;
        end
    end

    // Latch activations on PROG handshake.
    always_ff @(posedge clk) begin
        if (!rst_n)         acts_lat <= '0;
        else if (prog_fire) acts_lat <= ctrl.prog_acts;
    end

    // -------------------------------------------------------------------------
    // Combinational subset-sum for the current fill_addr. Same sum writes to
    // every lane replica at this address for sub-table s (each sub-table sees
    // its own 4 activations).
    // -------------------------------------------------------------------------
    tlmm_sub_entry_t fill_entry [TLMM_SUBTABLES_PER_TILE];

    always_comb begin
        for (int s = 0; s < int'(TLMM_SUBTABLES_PER_TILE); s++) begin
            automatic logic signed [TLMM_SUB_ENTRY_W-1:0] acc;
            acc = '0;
            for (int i = 0; i < int'(TLMM_SUBTILE); i++) begin
                if (fill_addr[i]) begin
                    acc += tlmm_sub_entry_t'(
                        $signed(acts_lat[s * TLMM_SUBTILE + i])
                    );
                end
            end
            fill_entry[s] = acc;
        end
    end

    // -------------------------------------------------------------------------
    // Stage R0: register the incoming weight beat.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            r0_valid <= 1'b0;
            r0_w     <= '0;
        end else if (r0_can_accept) begin
            r0_valid <= w_fire;
            if (w_fire) r0_w <= ctrl.w_tiles;
        end
    end

    // -------------------------------------------------------------------------
    // Decode masks from r0_w. Pure combinational; 16x4 tiny decoders.
    //   pos_mask[l][s][i] <= (r0_w[l][s*SUBTILE+i] == TERN_POS)
    //   neg_mask[l][s][i] <= (r0_w[l][s*SUBTILE+i] == TERN_NEG)
    // -------------------------------------------------------------------------
    logic [TLMM_SUBTABLE_ADDR_W-1:0]
          pos_mask [TLMM_LANES][TLMM_SUBTABLES_PER_TILE];
    logic [TLMM_SUBTABLE_ADDR_W-1:0]
          neg_mask [TLMM_LANES][TLMM_SUBTABLES_PER_TILE];

    always_comb begin
        for (int l = 0; l < int'(TLMM_LANES); l++) begin
            for (int s = 0; s < int'(TLMM_SUBTABLES_PER_TILE); s++) begin
                pos_mask[l][s] = '0;
                neg_mask[l][s] = '0;
                for (int i = 0; i < int'(TLMM_SUBTILE); i++) begin
                    unique case (r0_w[l][s*TLMM_SUBTILE + i])
                        TERN_POS : pos_mask[l][s][i] = 1'b1;
                        TERN_NEG : neg_mask[l][s][i] = 1'b1;
                        TERN_ZERO: ;
                        default  : ; // TERN_RSVD treated as zero
                    endcase
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Sub-table bank: one 16x14 dual-port distributed RAM per (lane, sub-tile).
    //   - sync write, shared across all lanes for a given sub-tile (same addr
    //     and same data every cycle of ST_FILL);
    //   - two async reads per cycle, one at pos_mask, one at neg_mask.
    // The per-(l,s) generate keeps each RAM small and isolated, so Vivado
    // infers RAM16X1D-class LUTRAM rather than collapsing into BRAM.
    // -------------------------------------------------------------------------
    tlmm_sub_part_t sub_part [TLMM_LANES][TLMM_SUBTABLES_PER_TILE];

    for (genvar l = 0; l < int'(TLMM_LANES); l++) begin : gen_lane
        for (genvar s = 0; s < int'(TLMM_SUBTABLES_PER_TILE); s++) begin : gen_sub

            (* ram_style = "distributed" *)
            tlmm_sub_entry_t mem [TLMM_SUBTABLE_DEPTH];

            // Synchronous write; LUTRAM has no reset (contents are don't-care
            // after power-up and are fully overwritten by the first PROG before
            // any compute beat is accepted).
            always_ff @(posedge clk) begin
                if (state == ST_FILL) mem[fill_addr] <= fill_entry[s];
            end

            // Async reads
            tlmm_sub_entry_t pos_sum, neg_sum;
            assign pos_sum = mem[pos_mask[l][s]];
            assign neg_sum = mem[neg_mask[l][s]];

            // Sub-tile partial = T[+mask] - T[-mask], widened to SUB_PART_W.
            assign sub_part[l][s] = tlmm_sub_part_t'(pos_sum)
                                  - tlmm_sub_part_t'(neg_sum);
        end
    end

    // -------------------------------------------------------------------------
    // 4-way adder tree per lane (LUT-only; no DSP inference).
    // -------------------------------------------------------------------------
    tlmm_part_vec_t tile_partials;

    (* use_dsp = "no" *)
    always_comb begin
        for (int l = 0; l < int'(TLMM_LANES); l++) begin
            automatic tlmm_tile_part_t acc;
            acc = '0;
            for (int s = 0; s < int'(TLMM_SUBTABLES_PER_TILE); s++) begin
                acc += tlmm_tile_part_t'(sub_part[l][s]);
            end
            tile_partials[l] = acc;
        end
    end

    // -------------------------------------------------------------------------
    // Stage R1 (output): register tile_partials. Honors downstream backpressure.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            o_valid_q <= 1'b0;
            o_parts_q <= '0;
        end else if (r1_can_accept) begin
            o_valid_q <= r0_valid;
            if (r0_valid) o_parts_q <= tile_partials;
        end
    end

    assign ctrl.o_valid = o_valid_q;
    assign ctrl.o_parts = o_parts_q;

endmodule : sparse_tile

`default_nettype wire
`endif // ARCHBETTER_SPARSE_TILE_SV
