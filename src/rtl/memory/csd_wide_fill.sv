
`timescale 1ns/1ps
`ifndef ARCHBETTER_CSD_WIDE_FILL_SV
`define ARCHBETTER_CSD_WIDE_FILL_SV
`default_nettype none

module csd_wide_fill
    import types_pkg::*;
#(
    parameter int unsigned WIDE   = DENSE_PP_URAM_WIDE,
    parameter int unsigned LEAF_W = URAM_WIDTH_BITS,
    parameter int unsigned ADDR_W = URAM_ADDR_W
) (
    input  wire logic                    clk,
    input  wire logic                    rst_n,
    input  wire logic                    in_wr_en,
    input  wire logic [ADDR_W-1:0]       in_wr_addr,
    input  wire logic [LEAF_W-1:0]       in_wr_data,
    output logic                         out_wr_en,
    output logic [ADDR_W-1:0]            out_wr_addr,
    output logic [WIDE*LEAF_W-1:0]       out_wr_data
);

    localparam int unsigned SEL_W  = (WIDE > 1) ? $clog2(WIDE) : 1;
    localparam int unsigned WIDE_W = WIDE * LEAF_W;

    initial begin : elab_checks
        if (WIDE < 2) begin
            $fatal(1, "csd_wide_fill: WIDE=%0d must be >= 2 (use the native fill path directly for WIDE=1)", WIDE);
        end
        if (2**SEL_W != WIDE) begin
            $fatal(1, "csd_wide_fill: WIDE=%0d must be a power of two (leaf = addr[SEL_W-1:0])", WIDE);
        end
    end
    logic [SEL_W-1:0] leaf;
    assign leaf = in_wr_addr[SEL_W-1:0];
    logic [WIDE_W-1:0] acc_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_q <= '0;
        end else if (in_wr_en) begin
            acc_q[leaf*LEAF_W +: LEAF_W] <= in_wr_data;
        end
    end
    assign out_wr_en   = in_wr_en && (leaf == SEL_W'(WIDE-1));
    assign out_wr_addr = ADDR_W'(in_wr_addr >> SEL_W);

    always_comb begin
        out_wr_data = acc_q;
        out_wr_data[leaf*LEAF_W +: LEAF_W] = in_wr_data;
    end

`ifndef SYNTHESIS
    logic [ADDR_W-1:0] prev_addr_q;
    logic              seen_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            prev_addr_q <= '0;
            seen_q      <= 1'b0;
        end else if (in_wr_en) begin
            prev_addr_q <= in_wr_addr;
            seen_q      <= 1'b1;
        end
    end

    a_no_midgroup_jump: assert property (
        @(posedge clk) disable iff (!rst_n)
        (in_wr_en && (leaf != '0) && seen_q) |-> (in_wr_addr == ADDR_W'(prev_addr_q + 1'b1))
    ) else $error("csd_wide_fill: non-contiguous fill at leaf %0d (mid-group gap corrupts the wide word)", leaf);
`endif

endmodule : csd_wide_fill

`default_nettype wire
`endif
