
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE_PE_SV
`define ARCHBETTER_DENSE_PE_SV
`default_nettype none

module dense_pe
    import types_pkg::*;
#(
    parameter bit          ENABLE_NOISE_HOOKS = 1'b0,
    parameter int unsigned PE_ID              = 0
) (
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire bfp12_mant_t a_in,
    input  wire logic        a_valid,
    input  wire logic        w_we,
    input  wire bfp12_mant_t w_in,
    input  wire bfp12_mant_t noise_rd_in,
    input  wire logic        acc_clr,
    input  wire logic        acc_snap,
    input  wire gemm_stream_mode_e stream_mode,
    output dense_acc_t  acc_out,
    output logic        acc_out_valid
);
    dense_acc_t cell_acc;
    logic       cell_acc_valid;

    cim_cell_4t2r #(
        .ENABLE_NOISE_HOOKS (ENABLE_NOISE_HOOKS),
        .CELL_ID            (PE_ID)
    ) u_cell (
        .clk         (clk),
        .rst_n       (rst_n),
        .a_in        (a_in),
        .a_valid     (a_valid),
        .w_we        (w_we),
        .w_in        (w_in),
        .noise_rd_in (noise_rd_in),
        .acc_clr     (acc_clr),
        .acc_out     (cell_acc),
        .acc_valid   (cell_acc_valid)
    );
    logic acc_out_valid_q;
    logic do_snap;
    always_comb begin
        do_snap = (stream_mode == GEMM_SNAP_CONTINUOUS) ? cell_acc_valid : acc_snap;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_out         <= '0;
            acc_out_valid_q <= 1'b0;
        end else begin
            acc_out_valid_q <= do_snap;
            if (do_snap) acc_out <= cell_acc;
        end
    end

    assign acc_out_valid = acc_out_valid_q;
`ifndef SYNTHESIS
    a_no_clr_and_snap: assert property (
        @(posedge clk) disable iff (!rst_n)
        !(acc_clr && acc_snap)
    ) else $error("dense_pe[%0d]: acc_clr and acc_snap asserted in the same cycle", PE_ID);
    a_valid_follows_snap: assert property (
        @(posedge clk) disable iff (!rst_n)
        acc_out_valid |-> $past(do_snap, 1)
    ) else $error("dense_pe[%0d]: acc_out_valid high without prior-cycle snap trigger", PE_ID);
    a_no_acc_snap_in_continuous: assert property (
        @(posedge clk) disable iff (!rst_n)
        (stream_mode == GEMM_SNAP_CONTINUOUS) |-> !acc_snap
    ) else $error("dense_pe[%0d]: acc_snap pulsed while in CONTINUOUS snap mode", PE_ID);
`endif

endmodule : dense_pe

`default_nettype wire
`endif
