
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE_GROUP_SV
`define ARCHBETTER_DENSE_GROUP_SV
`default_nettype none

module dense_group
    import types_pkg::*;
#(
    parameter bit          ENABLE_NOISE_HOOKS = 1'b0,
    parameter int unsigned GROUP_ID           = 0
) (
    input  wire logic                                   clk,
    input  wire logic                                   rst_n,
    strm_if.sink                                        a_strm,
    input  wire logic                                   acc_clr,
    input  wire logic                                   acc_snap,
    input  wire gemm_stream_mode_e                      stream_mode,
    input  wire logic                                   w_we,
    input  wire logic [$clog2(DENSE_PE_PER_GROUP)-1:0]  w_addr,
    input  wire bfp12_mant_t [(BFP12_BLK/2)-1:0]        w_in,
    output group_acc_t [DENSE_GROUP_COLS-1:0]      y_out,
    output logic                                   y_valid
);

    localparam int unsigned PE_ADDR_W = $clog2(DENSE_PE_PER_GROUP);
    localparam int unsigned WSCAN     = BFP12_BLK / 2;
    localparam int unsigned SLOT_W    = $clog2(WSCAN);
    localparam int unsigned WGRP_W    = PE_ADDR_W - SLOT_W;
    assign a_strm.ready = 1'b1;

    logic a_fire;
    assign a_fire = a_strm.valid && a_strm.ready;
    bfp12_mant_t [DENSE_GROUP_ROWS-1:0] a_vec;
    for (genvar r = 0; r < int'(DENSE_GROUP_ROWS); r++) begin : g_unpack
        assign a_vec[r] = a_strm.data[r*BFP12_MANT_W +: BFP12_MANT_W];
    end
    dense_acc_t [DENSE_GROUP_ROWS-1:0][DENSE_GROUP_COLS-1:0] pe_acc_out;
    logic       [DENSE_GROUP_ROWS-1:0][DENSE_GROUP_COLS-1:0] pe_acc_valid;

    for (genvar r = 0; r < int'(DENSE_GROUP_ROWS); r++) begin : g_row
        for (genvar c = 0; c < int'(DENSE_GROUP_COLS); c++) begin : g_col
            localparam int unsigned LOCAL_PE_IDX =
                r * DENSE_GROUP_COLS + c;

            localparam int unsigned PE_WORD = LOCAL_PE_IDX / WSCAN;
            localparam int unsigned PE_SLOT = LOCAL_PE_IDX % WSCAN;

            logic pe_w_we;
            assign pe_w_we = w_we &&
                (w_addr[PE_ADDR_W-1:SLOT_W] == WGRP_W'(PE_WORD));

            dense_pe #(
                .ENABLE_NOISE_HOOKS (ENABLE_NOISE_HOOKS),
                .PE_ID              (GROUP_ID * DENSE_PE_PER_GROUP + LOCAL_PE_IDX)
            ) u_pe (
                .clk           (clk),
                .rst_n         (rst_n),
                .a_in          (a_vec[r]),
                .a_valid       (a_fire),
                .w_we          (pe_w_we),
                .w_in          (w_in[PE_SLOT]),
                .noise_rd_in   ('0),
                .acc_clr       (acc_clr && a_fire),
                .acc_snap      (acc_snap),
                .stream_mode   (stream_mode),
                .acc_out       (pe_acc_out[r][c]),
                .acc_out_valid (pe_acc_valid[r][c])
            );
        end
    end
    group_acc_t [DENSE_GROUP_COLS-1:0] col_sum;
    always_comb begin
        for (int c = 0; c < int'(DENSE_GROUP_COLS); c++) begin
            group_acc_t s;
            s = '0;
            for (int rr = 0; rr < int'(DENSE_GROUP_ROWS); rr++) begin
                s += group_acc_t'(pe_acc_out[rr][c]);
            end
            col_sum[c] = s;
        end
    end
    logic any_pe_valid;
    assign any_pe_valid = pe_acc_valid[0][0];

    logic y_valid_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            y_out     <= '0;
            y_valid_q <= 1'b0;
        end else begin
            y_valid_q <= any_pe_valid;
            if (any_pe_valid) y_out <= col_sum;
        end
    end

    assign y_valid = y_valid_q;
`ifndef SYNTHESIS
    a_no_wwe_with_afire: assert property (
        @(posedge clk) disable iff (!rst_n)
        !(w_we && a_fire)
    ) else $error("dense_group[%0d]: w_we during an activation beat", GROUP_ID);

    a_clr_requires_fire: assert property (
        @(posedge clk) disable iff (!rst_n)
        acc_clr |-> a_fire
    ) else $error("dense_group[%0d]: acc_clr without an accepted beat", GROUP_ID);

    a_no_snap_with_fire: assert property (
        @(posedge clk) disable iff (!rst_n)
        !(acc_snap && a_fire)
    ) else $error("dense_group[%0d]: acc_snap co-fired with an activation beat", GROUP_ID);
`endif

endmodule : dense_group

`default_nettype wire
`endif
