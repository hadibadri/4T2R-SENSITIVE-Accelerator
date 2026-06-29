
`ifndef ARCHBETTER_KV_BRAM_SV
`define ARCHBETTER_KV_BRAM_SV
`default_nettype none
`timescale 1ns/1ps

module kv_bram
    import types_pkg::*;
#(
    parameter int unsigned DATA_W = KV_DATA_W,
    parameter int unsigned DEPTH  = KV_DEPTH,
    parameter int unsigned ADDR_W = KV_ADDR_W
) (
    input  wire logic clk,
    input  wire logic rst_n,

    kv_access_if.slave kv
);
    initial begin : elab_checks
        if (ADDR_W != $clog2(DEPTH)) begin
            $fatal(1, "kv_bram: ADDR_W=%0d inconsistent with DEPTH=%0d",
                   ADDR_W, DEPTH);
        end
    end
    (* ram_style = "block" *)
    logic [DATA_W-1:0] mem [DEPTH];
    logic [DATA_W-1:0] rd_data_q;
    logic [DATA_W-1:0] rd_data_q2;
    logic              rd_valid_q;
    logic              rd_valid_q2;
    always_ff @(posedge clk) begin
        if (kv.wr_en) begin
            mem[kv.wr_addr] <= kv.wr_data;
        end
        if (kv.rd_en) begin
            rd_data_q <= mem[kv.rd_addr];
        end
        rd_data_q2 <= rd_data_q;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_valid_q  <= 1'b0;
            rd_valid_q2 <= 1'b0;
        end else begin
            rd_valid_q  <= kv.rd_en;
            rd_valid_q2 <= rd_valid_q;
        end
    end

    assign kv.rd_data  = rd_data_q2;
    assign kv.rd_valid = rd_valid_q2;
`ifndef SYNTHESIS
    property p_no_rw_collision;
        @(posedge clk) disable iff (!rst_n)
        (kv.wr_en && kv.rd_en) |-> (kv.wr_addr != kv.rd_addr);
    endproperty
    a_no_rw_collision: assert property (p_no_rw_collision)
        else $error("kv_bram: write and read targeted the same address on one cycle (undefined BRAM read-under-write)");
`endif

endmodule : kv_bram

`default_nettype wire
`endif
