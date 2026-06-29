
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE2SPARSE_FIFO_SV
`define ARCHBETTER_DENSE2SPARSE_FIFO_SV
`default_nettype none

module dense2sparse_fifo
    import types_pkg::*;
#(
    parameter int unsigned DATA_W             = NOC_DATA_W,
    parameter int unsigned USER_W             = NOC_USER_W,
    parameter int unsigned FIFO_DEPTH         = 64,
    parameter int unsigned ALMOST_FULL_THRESH = FIFO_DEPTH - 8
) (
    input  wire logic clk,
    input  wire logic rst_n,

    dense2sparse_if.sparse in_d2s,
    dense2sparse_if.dense  out_d2s
);
    initial begin : elab_checks
        if (FIFO_DEPTH < 16) begin
            $fatal(1, "dense2sparse_fifo: FIFO_DEPTH=%0d below xpm_fifo_sync minimum (16)",
                   FIFO_DEPTH);
        end
        if ((FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin
            $fatal(1, "dense2sparse_fifo: FIFO_DEPTH=%0d must be a power of two",
                   FIFO_DEPTH);
        end
        if (ALMOST_FULL_THRESH < 4 || ALMOST_FULL_THRESH >= FIFO_DEPTH) begin
            $fatal(1, "dense2sparse_fifo: ALMOST_FULL_THRESH=%0d outside [4, FIFO_DEPTH-1)=%0d",
                   ALMOST_FULL_THRESH, FIFO_DEPTH - 1);
        end
    end

    localparam int unsigned PACK_W       = 1 + USER_W + DATA_W;
    localparam int unsigned WD_COUNT_W   = $clog2(FIFO_DEPTH) + 1;
    logic              fifo_full;
    logic              fifo_empty;
    logic              fifo_prog_full;
    logic [PACK_W-1:0] fifo_din;
    logic [PACK_W-1:0] fifo_dout;
    logic              fifo_wr_en;
    logic              fifo_rd_en;
    logic              fifo_rst;
    logic              fifo_wr_rst_busy;
    logic              fifo_rd_rst_busy;

    assign fifo_din   = { in_d2s.last, in_d2s.user, in_d2s.data };
    assign fifo_wr_en = in_d2s.valid && in_d2s.ready;

    assign in_d2s.ready       = !fifo_full && !fifo_wr_rst_busy;
    assign in_d2s.almost_full = fifo_prog_full;
    assign fifo_rd_en   = out_d2s.valid && out_d2s.ready;
    assign out_d2s.valid = !fifo_empty && !fifo_rd_rst_busy;
    assign out_d2s.data  = fifo_dout[0 +: DATA_W];
    assign out_d2s.user  = fifo_dout[DATA_W +: USER_W];
    assign out_d2s.last  = fifo_dout[DATA_W + USER_W];
    assign fifo_rst = !rst_n;

    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE   ("auto"),
        .FIFO_WRITE_DEPTH   (FIFO_DEPTH),
        .WRITE_DATA_WIDTH   (PACK_W),
        .READ_DATA_WIDTH    (PACK_W),
        .READ_MODE          ("fwft"),
        .USE_ADV_FEATURES   ("0002"),
        .PROG_FULL_THRESH   (ALMOST_FULL_THRESH),
        .FIFO_READ_LATENCY  (0),
        .FULL_RESET_VALUE   (0),
        .DOUT_RESET_VALUE   ("0"),
        .ECC_MODE           ("no_ecc"),
        .WAKEUP_TIME        (0),
        .WR_DATA_COUNT_WIDTH(WD_COUNT_W),
        .RD_DATA_COUNT_WIDTH(WD_COUNT_W)
    ) u_fifo (
        .rst           (fifo_rst),
        .wr_clk        (clk),
        .wr_en         (fifo_wr_en),
        .din           (fifo_din),
        .full          (fifo_full),
        .prog_full     (fifo_prog_full),
        .wr_data_count (),
        .overflow      (),
        .wr_rst_busy   (fifo_wr_rst_busy),
        .almost_full   (),
        .wr_ack        (),
        .rd_en         (fifo_rd_en),
        .dout          (fifo_dout),
        .empty         (fifo_empty),
        .prog_empty    (),
        .rd_data_count (),
        .underflow     (),
        .rd_rst_busy   (fifo_rd_rst_busy),
        .almost_empty  (),
        .data_valid    (),
        .sleep         (1'b0),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0),
        .sbiterr       (),
        .dbiterr       ()
    );
`ifndef SYNTHESIS
    a_no_write_when_full: assert property (
        @(posedge clk) disable iff (!rst_n)
        fifo_wr_en |-> !fifo_full
    ) else $error("dense2sparse_fifo: wr_en fired into a full FIFO");

    a_no_read_when_empty: assert property (
        @(posedge clk) disable iff (!rst_n)
        fifo_rd_en |-> !fifo_empty
    ) else $error("dense2sparse_fifo: rd_en fired on an empty FIFO");
`endif

endmodule : dense2sparse_fifo

`default_nettype wire
`endif
