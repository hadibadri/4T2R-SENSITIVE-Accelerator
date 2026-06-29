
`timescale 1ns/1ps
`ifndef ARCHBETTER_AXI4_READ_ADAPTER_SV
`define ARCHBETTER_AXI4_READ_ADAPTER_SV
`default_nettype none

module axi4_read_adapter
    import types_pkg::*;
#(
    parameter int unsigned AXI_DATA_W = 128,
    parameter int unsigned AXI_ID_W   = 4
) (
    input  wire logic   clk,
    input  wire logic   rst_n,
    csd_dram_if.dram    rd,
    axi4_if.master_rd   axi
);
    localparam int unsigned BEAT_BYTES    = AXI_DATA_W / 8;
    localparam int unsigned AXSIZE        = $clog2(BEAT_BYTES);
    localparam int unsigned MAX_BURST     = 256;
    localparam int unsigned BOUND_BEATS   = 4096 / BEAT_BYTES;
    localparam int unsigned BLEN_W        = $clog2(MAX_BURST + 1);
    initial begin : elab_checks
        if (AXI_DATA_W < DRAM_BEAT_W)
            $fatal(1, "axi4_read_adapter: AXI_DATA_W=%0d < DRAM_BEAT_W=%0d",
                   AXI_DATA_W, DRAM_BEAT_W);
        if ((BEAT_BYTES & (BEAT_BYTES - 1)) != 0)
            $fatal(1, "axi4_read_adapter: BEAT_BYTES=%0d not a power of two", BEAT_BYTES);
        if (BOUND_BEATS == 0)
            $fatal(1, "axi4_read_adapter: BEAT_BYTES=%0d exceeds 4KB page", BEAT_BYTES);
    end
    typedef enum logic [1:0] { R_IDLE, R_AR, R_DATA } state_e;
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
    assign rd.req_ready = (state_q == R_IDLE);
    assign rd.rsp_data  = axi.rdata[DRAM_BEAT_W-1:0];
    assign rd.rsp_valid = (state_q == R_DATA) && axi.rvalid;
    assign rd.rsp_last  = (state_q == R_DATA) && (rem_q == DRAM_LEN_W'(1));
    assign axi.arid    = AXI_ID_W'(0);
    assign axi.araddr  = addr_q;
    assign axi.arlen   = 8'(this_burst - DRAM_LEN_W'(1));
    assign axi.arsize  = 3'(AXSIZE);
    assign axi.arburst = 2'b01;
    assign axi.arvalid = (state_q == R_AR);
    assign axi.rready  = (state_q == R_DATA) && rd.rsp_ready;

    logic ar_fire, r_fire;
    assign ar_fire = axi.arvalid && axi.arready;
    assign r_fire  = axi.rvalid  && axi.rready;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= R_IDLE;
            addr_q  <= '0;
            rem_q   <= '0;
            blen_q  <= '0;
        end else begin
            unique case (state_q)
                R_IDLE: begin
                    if (rd.req_valid && rd.req_ready) begin
                        addr_q  <= rd.req_addr;
                        rem_q   <= rd.req_len;
                        state_q <= R_AR;
                    end
                end
                R_AR: begin
                    if (ar_fire) begin
                        blen_q  <= BLEN_W'(this_burst);
                        addr_q  <= DRAM_ADDR_W'(addr_q
                                  + (DRAM_ADDR_W'(this_burst) << AXSIZE));
                        state_q <= R_DATA;
                    end
                end
                R_DATA: begin
                    if (r_fire) begin
                        rem_q  <= DRAM_LEN_W'(rem_q  - 1'b1);
                        blen_q <= BLEN_W'(blen_q - 1'b1);
                        if (blen_q == BLEN_W'(1)) begin
                            state_q <= (rem_q == DRAM_LEN_W'(1)) ? R_IDLE : R_AR;
                        end
                    end
                end
                default: state_q <= R_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    a_rlast_aligns: assert property (@(posedge clk) disable iff (!rst_n)
        r_fire |-> (axi.rlast == (blen_q == BLEN_W'(1))))
        else $error("axi4_read_adapter: RLAST/blen mismatch (slave burst length disagreement)");
    a_no_rem_underflow: assert property (@(posedge clk) disable iff (!rst_n)
        r_fire |-> (rem_q != DRAM_LEN_W'(0)))
        else $error("axi4_read_adapter: R beat fired with rem_q==0 (slave over-streamed)");
    a_rresp_okay: assert property (@(posedge clk) disable iff (!rst_n)
        r_fire |-> (axi.rresp == 2'b00))
        else $error("axi4_read_adapter: RRESP != OKAY");
`endif

endmodule : axi4_read_adapter

`default_nettype wire
`endif
