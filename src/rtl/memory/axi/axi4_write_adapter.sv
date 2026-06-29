// -----------------------------------------------------------------------------
// axi4_write_adapter.sv  (C2 — DRAM write seam)
//
// Translates the accelerator's native write DRAM interface (csd_dram_wr_if,
// driven by csd_drain_engine on OP_ST_OUT) into AXI4 write transactions
// (AW / W / B) toward off-chip DRAM. The adapter is the .dram (slave) side of
// csd_dram_wr_if and the write-only (.master_wr) side of axi4_if.
//
// Address / burst semantics: identical to axi4_read_adapter (byte addresses,
// one padded 72-bit DRAM word per AXI beat, INCR bursts split at the 256-beat
// AXI4 max and the 4 KB page boundary). See that file's header.
//
// W-channel wlast vs csd_dram_wr_if.wd_last:
//   The accelerator's wd_last marks the final beat of the WHOLE descriptor. AXI
//   requires WLAST on the final beat of EACH burst. The adapter therefore
//   generates its own per-burst wlast from blen_q and does NOT forward wd_last;
//   it cross-checks (assertion) that wd_last coincides with the descriptor's
//   final beat (rem_q == 1).
//
// Ordering / outstanding: one burst at a time — AW, stream the burst's W beats,
// wait for B, then the next AW. This matches the single-outstanding contract of
// csd_dram_wr_if and the drain engine's 2-deep skid (which paces W beats).
//
// wstrb: all lanes asserted. The upper AXI_DATA_W-72 bits of wdata are zero
// padding; writing them as zero is harmless (the read side only consumes the
// low 72 bits). A real ECC/narrow DRAM would narrow wstrb; not needed on the seam.
//
// Resource class: a small FSM + addr/len/burst counters. No DSP/BRAM/URAM.
// -----------------------------------------------------------------------------
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

    // Accelerator side: adapter presents the DRAM (slave) face of csd_dram_wr_if.
    csd_dram_wr_if.dram wr,

    // DRAM side: adapter is the write-only AXI4 master.
    axi4_if.master_wr   axi
);

    // -------------------------------------------------------------------------
    // Derived AXI geometry (mirrors axi4_read_adapter).
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // FSM.
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] { W_IDLE, W_AW, W_DATA, W_B } state_e;
    state_e state_q;

    logic [DRAM_ADDR_W-1:0] addr_q;
    logic [DRAM_LEN_W-1:0]  rem_q;
    logic [BLEN_W-1:0]      blen_q;

    // Next-burst length (identical computation to the read adapter): done in the
    // DRAM_LEN_W domain so the up-to-65535-beat rem_q is never truncated. Result
    // is always <= MAX_BURST.
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

    // -------------------------------------------------------------------------
    // Output drive.
    // -------------------------------------------------------------------------
    // csd_dram_wr_if (slave face)
    assign wr.req_ready = (state_q == W_IDLE);
    assign wr.wd_ready  = (state_q == W_DATA) && axi.wready;

    // AXI AW channel
    assign axi.awid    = AXI_ID_W'(0);
    assign axi.awaddr  = addr_q;
    assign axi.awlen   = 8'(this_burst - DRAM_LEN_W'(1));
    assign axi.awsize  = 3'(AXSIZE);
    assign axi.awburst = 2'b01; // INCR
    assign axi.awvalid = (state_q == W_AW);

    // AXI W channel
    assign axi.wdata  = { {(AXI_DATA_W-DRAM_BEAT_W){1'b0}}, wr.wd_data };
    assign axi.wstrb  = {STRB_W{1'b1}};
    assign axi.wlast  = (state_q == W_DATA) && (blen_q == BLEN_W'(1));
    assign axi.wvalid = (state_q == W_DATA) && wr.wd_valid;

    // AXI B channel
    assign axi.bready = (state_q == W_B);

    logic aw_fire, w_fire, b_fire;
    assign aw_fire = axi.awvalid && axi.awready;
    assign w_fire  = axi.wvalid  && axi.wready;
    assign b_fire  = axi.bvalid  && axi.bready;

    // -------------------------------------------------------------------------
    // Sequential.
    // -------------------------------------------------------------------------
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
    // The accelerator's wd_last must mark the descriptor's final beat: the beat
    // where rem_q reaches 0 (rem_q == 1 at fire time) must carry wd_last, and
    // wd_last must not appear early.
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
`endif // ARCHBETTER_AXI4_WRITE_ADAPTER_SV
