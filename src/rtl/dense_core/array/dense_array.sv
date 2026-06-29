
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE_ARRAY_SV
`define ARCHBETTER_DENSE_ARRAY_SV
`default_nettype none

module dense_array
    import types_pkg::*;
#(
    parameter bit          ENABLE_NOISE_HOOKS = 1'b0,
    parameter int unsigned ARRAY_ID           = 0,
    parameter int unsigned BATCH_T            = 1,
    parameter int unsigned BANK_REG_MAX       = 8
) (
    input  wire logic clk,
    input  wire logic rst_n,
    strm_if.sink                                                   a_strm,
    input  wire logic [$clog2(DENSE_LOGICAL_TILE_ROWS)-1:0]        tile_gr,
    input  wire logic [$clog2(DENSE_LOGICAL_TILE_COLS)-1:0]        tile_gc,
    input  wire logic [BATCH_TOK_W-1:0]                           tile_tok,
    input  wire logic [BATCH_TOK_W-1:0]                           batch_n,
    input  wire logic                                             drain_busy,
    input  wire logic                                              tile_first,
    input  wire logic                                              tile_last,
    input  wire logic                                              acc_clr,
    input  wire logic                                              acc_snap,
    input  wire gemm_stream_mode_e                                 stream_mode,
    input  wire logic                                              w_we,
    input  wire logic [$clog2(DENSE_PHYS_GROUPS_COL)-1:0]          w_phys_gc,
    input  wire logic [$clog2(DENSE_PE_PER_GROUP)-1:0]             w_pe_addr,
    input  wire bfp12_mant_t [(BFP12_BLK/2)-1:0]                   w_in,
    output array_acc_t [DENSE_ARRAY_COLS-1:0]                      y_out,
    output logic                                                   y_valid,
    output logic                                                   drain_active
);

    localparam int unsigned PHYS_COLS  = DENSE_PHYS_COLS;
    localparam int unsigned TILE_GC_W  = $clog2(DENSE_LOGICAL_TILE_COLS);
    strm_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W))
        inner_strm [DENSE_PHYS_GROUPS_COL] (.clk(clk), .rst_n(rst_n));

    for (genvar PG0 = 0; PG0 < int'(DENSE_PHYS_GROUPS_COL); PG0++) begin : gen_strm_fanout
        assign inner_strm[PG0].valid = a_strm.valid;
        assign inner_strm[PG0].data  = a_strm.data;
        assign inner_strm[PG0].user  = a_strm.user;
        assign inner_strm[PG0].last  = a_strm.last;
    end

    assign a_strm.ready = 1'b1;
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
    array_acc_t [PHYS_COLS-1:0] phys_strip;
    always_comb begin
        for (int pc = 0; pc < int'(DENSE_GROUP_COLS); pc++) begin
            phys_strip[pc]                      = array_acc_t'(gp_y_out[0][pc]);
            phys_strip[DENSE_GROUP_COLS + pc]   = array_acc_t'(gp_y_out[1][pc]);
        end
    end
    logic                   tile_last_q;
    logic [TILE_GC_W-1:0]   tile_gc_q;
    logic [BATCH_TOK_W-1:0] tile_tok_q;
    logic                   tile_first_touch_q;
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
    localparam int unsigned TOK_LAT = DENSE_CONT_RESULT_LAT;
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
`ifndef SYNTHESIS
    a_no_wwe_with_stream: assert property (
        @(posedge clk) disable iff (!rst_n)
        !(w_we && a_strm.valid && a_strm.ready)
    ) else $error("dense_array[%0d]: w_we during an activation beat", ARRAY_ID);
    a_yvalid_coherent: assert property (
        @(posedge clk) disable iff (!rst_n)
        (gp_y_valid[0] || gp_y_valid[1]) |-> (gp_y_valid[0] && gp_y_valid[1])
    ) else $error("dense_array[%0d]: y_valid pulses not coherent across phys groups",
                  ARRAY_ID);
    a_tile_gc_stable_in_stream: assert property (
        @(posedge clk) disable iff (!rst_n)
        (a_strm.valid && a_strm.ready) |-> ##1 $stable(tile_gc) || tile_first
    ) else $error("dense_array[%0d]: tile_gc changed mid-tile", ARRAY_ID);
`endif

endmodule : dense_array

`default_nettype wire
`endif
