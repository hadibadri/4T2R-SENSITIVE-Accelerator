
`ifndef ARCHBETTER_URAM_BANK_SV
`define ARCHBETTER_URAM_BANK_SV
`default_nettype none
`timescale 1ns/1ps

module uram_bank
    import types_pkg::*;
#(
    parameter int unsigned DATA_W = URAM_WIDTH_BITS,
    parameter int unsigned DEPTH  = URAM_DEPTH,
    parameter int unsigned ADDR_W = URAM_ADDR_W,
    parameter int unsigned WIDE   = 1
) (
    input  wire logic                clk,
    input  wire logic                rst_n,
    input  wire logic                wr_en,
    input  wire logic [ADDR_W-1:0]   wr_addr,
    input  wire logic [DATA_W-1:0]   wr_data,
    input  wire logic                rd_en,
    input  wire logic [ADDR_W-1:0]   rd_addr,
    output logic                     rd_valid,
    output logic [DATA_W-1:0]        rd_data
);
    localparam int unsigned LEAF_W = DATA_W / WIDE;
    initial begin : elab_checks
        if (ADDR_W != $clog2(DEPTH)) begin
            $fatal(1, "uram_bank: ADDR_W=%0d inconsistent with DEPTH=%0d",
                   ADDR_W, DEPTH);
        end
        if (LEAF_W * WIDE != DATA_W) begin
            $fatal(1, "uram_bank: DATA_W=%0d not divisible by WIDE=%0d", DATA_W, WIDE);
        end
        if (LEAF_W > 72) begin
            $fatal(1, "uram_bank: per-leaf width %0d (DATA_W/WIDE) exceeds URAM primitive width (72)",
                   LEAF_W);
        end
    end
    logic [DATA_W-1:0] rd_data_s2;

    for (genvar l = 0; l < int'(WIDE); l++) begin : g_leaf
        (* ram_style = "ultra" *)
        logic [LEAF_W-1:0] mem [DEPTH];
        logic [LEAF_W-1:0] rd_data_s1;
        logic [LEAF_W-1:0] rd_data_leaf_s2;

        always_ff @(posedge clk) begin
            if (wr_en) begin
                mem[wr_addr] <= wr_data[l*LEAF_W +: LEAF_W];
            end
            if (rd_en) begin
                rd_data_s1 <= mem[rd_addr];
            end
            rd_data_leaf_s2 <= rd_data_s1;
        end

        assign rd_data_s2[l*LEAF_W +: LEAF_W] = rd_data_leaf_s2;
    end : g_leaf
    logic rd_valid_s1;
    logic rd_valid_s2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_valid_s1 <= 1'b0;
            rd_valid_s2 <= 1'b0;
        end else begin
            rd_valid_s1 <= rd_en;
            rd_valid_s2 <= rd_valid_s1;
        end
    end

    assign rd_valid = rd_valid_s2;
    assign rd_data  = rd_data_s2;
`ifndef SYNTHESIS
    property p_no_rw_collision;
        @(posedge clk) disable iff (!rst_n)
        (wr_en && rd_en) |-> (wr_addr != rd_addr);
    endproperty
    a_no_rw_collision: assert property (p_no_rw_collision)
        else $error("uram_bank: write and read to same address on the same cycle (undefined URAM collision)");
`endif

endmodule : uram_bank

`default_nettype wire
`endif
