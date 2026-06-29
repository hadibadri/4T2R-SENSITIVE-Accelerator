
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
    localparam int unsigned FILL_CNT_W = TLMM_SUBTABLE_ADDR_W;

    typedef enum logic {
        ST_IDLE = 1'b0,
        ST_FILL = 1'b1
    } state_e;

    state_e                state, state_n;
    logic [FILL_CNT_W-1:0] fill_addr;
    tlmm_tile_act_t        acts_lat;
    tern_lane_tiles_t r0_w;
    logic             r0_valid;

    tlmm_part_vec_t   o_parts_q;
    logic             o_valid_q;

    logic r1_can_accept, r0_can_accept;
    assign r1_can_accept = !o_valid_q || ctrl.o_ready;
    assign r0_can_accept = !r0_valid  || r1_can_accept;
    logic w_fire, prog_fire;
    assign ctrl.w_ready    = (state == ST_IDLE) && r0_can_accept;
    assign ctrl.prog_ready = (state == ST_IDLE) && !r0_valid && !o_valid_q;
    assign w_fire          = ctrl.w_valid    && ctrl.w_ready;
    assign prog_fire       = ctrl.prog_valid && ctrl.prog_ready;
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
    always_ff @(posedge clk) begin
        if (!rst_n)         acts_lat <= '0;
        else if (prog_fire) acts_lat <= ctrl.prog_acts;
    end
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
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            r0_valid <= 1'b0;
            r0_w     <= '0;
        end else if (r0_can_accept) begin
            r0_valid <= w_fire;
            if (w_fire) r0_w <= ctrl.w_tiles;
        end
    end
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
                        default  : ;
                    endcase
                end
            end
        end
    end
    tlmm_sub_part_t sub_part [TLMM_LANES][TLMM_SUBTABLES_PER_TILE];

    for (genvar l = 0; l < int'(TLMM_LANES); l++) begin : gen_lane
        for (genvar s = 0; s < int'(TLMM_SUBTABLES_PER_TILE); s++) begin : gen_sub

            (* ram_style = "distributed" *)
            tlmm_sub_entry_t mem [TLMM_SUBTABLE_DEPTH];
            always_ff @(posedge clk) begin
                if (state == ST_FILL) mem[fill_addr] <= fill_entry[s];
            end
            tlmm_sub_entry_t pos_sum, neg_sum;
            assign pos_sum = mem[pos_mask[l][s]];
            assign neg_sum = mem[neg_mask[l][s]];
            assign sub_part[l][s] = tlmm_sub_part_t'(pos_sum)
                                  - tlmm_sub_part_t'(neg_sum);
        end
    end
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
`endif
