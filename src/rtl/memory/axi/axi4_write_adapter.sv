
`timescale 1ns/1ps
`ifndef ARCHBETTER_AXI4_WRITE_ADAPTER_SV
`define ARCHBETTER_AXI4_WRITE_ADAPTER_SV
`default_nettype none

module axi4_write_adapter
    import types_pkg::*;
#(
    parameter int unsigned AXI_DATA_W = 128,
    parameter int unsigned AXI_ID_W   = 4
) (
    input  wire logic   clk,
    input  wire logic   rst_n,
    csd_dram_wr_if.dram wr,
    axi4_if.master_wr   axi
);
    localparam int unsigned BEAT_BYTES  = AXI_DATA_W / 8;
    localparam int unsigned AXSIZE      = $clog2(BEAT_BYTES);
    localparam int unsigned MAX_BURST   = 256;
    localparam int unsigned BOUND_BEATS = 4096 / BEAT_BYTES;
    localparam int unsigned BLEN_W      = $clog2(MAX_BURST + 1);
    localparam int unsigned STRB_W      = AXI_DATA_W / 8;

    initial begin : elab_checks
        if (AXI_DATA_W < DRAM_BEAT_W)
            $fatal(1, "axi4_write_adapter: AXI_DATA_W=%0d < DRAM_BEAT_W=%0d",
                   AXI_DATA_W, DRAM_BEAT_W);
        if ((BEAT_BYTES & (BEAT_BYTES - 1)) != 0)
            $fatal(1, "axi4_write_adapter: BEAT_BYTES=%0d not a power of two", BEAT_BYTES);
        if (BOUND_BEATS == 0)
            $fatal(1, "axi4_write_adapter: BEAT_BYTES=%0d exceeds 4KB page", BEAT_BYTES);
    end
    typedef enum logic [1:0] { W_IDLE, W_AW, W_DATA, W_B } state_e;
    state_e state_q;

    logic [DRAM_ADDR_W-1:0] addr_q;
    logic [DRAM_LEN_W-1:0]  rem_q;
    logic [BLEN_W-1:0]      blen_q;
    logic [DRAM_LEN_W-1:0] beat_in_page;
    logic [DRAM_LEN_W-1:0] bound_left;
    logic [DRAM_LEN_W-1:0] this_burst;

    always_comb begin
        beat_in_page = DRAM_LEN_W'((addr_q >> AXSIZE) & DRAM_ADDR_W'(BOUND_BEATS - 1));
        bound_left   = DRAM_LEN_W'(BOUND_BEATS) - beat_in_page;
        this_burst   = (rem_q < bound_left) ? rem_q : bound_left;
        if (this_burst > DRAM_LEN_W'(MAX_BURST))
            this_burst = DRAM_LEN_W'(MAX_BURST);
    end
    assign wr.req_ready = (state_q == W_IDLE);
    assign wr.wd_ready  = (state_q == W_DATA) && axi.wready;
    assign axi.awid    = AXI_ID_W'(0);
    assign axi.awaddr  = addr_q;
    assign axi.awlen   = 8'(this_burst - DRAM_LEN_W'(1));
    assign axi.awsize  = 3'(AXSIZE);
    assign axi.awburst = 2'b01;
    assign axi.awvalid = (state_q == W_AW);
    assign axi.wdata  = { {(AXI_DATA_W-DRAM_BEAT_W){1'b0}}, wr.wd_data };
    assign axi.wstrb  = {STRB_W{1'b1}};
    assign axi.wlast  = (state_q == W_DATA) && (blen_q == BLEN_W'(1));
    assign axi.wvalid = (state_q == W_DATA) && wr.wd_valid;
    assign axi.bready = (state_q == W_B);

    logic aw_fire, w_fire, b_fire;
    assign aw_fire = axi.awvalid && axi.awready;
    assign w_fire  = axi.wvalid  && axi.wready;
    assign b_fire  = axi.bvalid  && axi.bready;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= W_IDLE;
            addr_q  <= '0;
            rem_q   <= '0;
            blen_q  <= '0;
        end else begin
            unique case (state_q)
                W_IDLE: begin
                    if (wr.req_valid && wr.req_ready) begin
                        addr_q  <= wr.req_addr;
                        rem_q   <= wr.req_len;
                        state_q <= W_AW;
                    end
                end
                W_AW: begin
                    if (aw_fire) begin
                        blen_q  <= BLEN_W'(this_burst);
                        addr_q  <= DRAM_ADDR_W'(addr_q
                                  + (DRAM_ADDR_W'(this_burst) << AXSIZE));
                        state_q <= W_DATA;
                    end
                end
                W_DATA: begin
                    if (w_fire) begin
                        rem_q  <= DRAM_LEN_W'(rem_q  - 1'b1);
                        blen_q <= BLEN_W'(blen_q - 1'b1);
                        if (blen_q == BLEN_W'(1)) state_q <= W_B;
                    end
                end
                W_B: begin
                    if (b_fire) state_q <= (rem_q == DRAM_LEN_W'(0)) ? W_IDLE : W_AW;
                end
                default: state_q <= W_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    a_wdlast_at_final: assert property (@(posedge clk) disable iff (!rst_n)
        w_fire |-> (wr.wd_last == (rem_q == DRAM_LEN_W'(1))))
        else $error("axi4_write_adapter: wd_last not aligned with the descriptor's final beat");

    a_no_rem_underflow: assert property (@(posedge clk) disable iff (!rst_n)
        w_fire |-> (rem_q != DRAM_LEN_W'(0)))
        else $error("axi4_write_adapter: W beat fired with rem_q==0 (over-streamed)");

    a_bresp_okay: assert property (@(posedge clk) disable iff (!rst_n)
        b_fire |-> (axi.bresp == 2'b00))
        else $error("axi4_write_adapter: BRESP != OKAY");
`endif

endmodule : axi4_write_adapter

`default_nettype wire
`endif
