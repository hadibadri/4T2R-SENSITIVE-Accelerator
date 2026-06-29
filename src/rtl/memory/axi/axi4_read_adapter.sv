// -----------------------------------------------------------------------------
// axi4_read_adapter.sv  (C2 — DRAM read seam)
//
// Translates the accelerator's native read DRAM interface (csd_dram_if, driven
// by csd_engine) into AXI4 read transactions (AR / R) toward an off-chip DRAM
// (the behavioral axi4_dram_model in sim; a DDR4 MIG at C3). The adapter is the
// .dram (slave) side of csd_dram_if and the read-only (.master_rd) side of axi4_if.
//
// Address semantics (the seam contract):
//   * csd_dram_if.req_addr is a BYTE address. Beat i of the request lives at
//     req_addr + i*BEAT_BYTES, where BEAT_BYTES = AXI_DATA_W/8. One DRAM beat
//     (DRAM_BEAT_W = 72 bits) occupies the low bits of one AXI beat; the upper
//     AXI_DATA_W-72 bits are unused (zero on the way out, ignored on the way in).
//   * req_len is the beat count for the WHOLE descriptor (up to 2^DRAM_LEN_W).
//
// Burst splitting (mandatory for AXI4 legality and C3 MIG compatibility):
//   A single descriptor of up to 65535 beats is split into AXI bursts each
//   bounded by BOTH (a) the 256-beat AXI4 maximum (ARLEN is 8 bits) and (b) the
//   4 KB address-boundary rule (a burst may not cross a 4 KB page). With the
//   default 16 B/beat the two limits coincide at 256 beats/page, but the logic
//   handles any power-of-two BEAT_BYTES.
//
// rsp_last:
//   Asserted on the FINAL beat of the descriptor (rem == 1), NOT on each AXI
//   burst's RLAST. The downstream csd_engine counts beats against n_beats; this
//   keeps that contract intact regardless of how many AXI bursts the split used.
//
// Outstanding: single descriptor, single AXI burst in flight at a time (parity
// with csd_engine / csd_dram_if, which serialize one descriptor). A later
// revision can pipeline AR issue ahead of R drain.
//
// Resource class: a small FSM + addr/len/burst counters. No DSP/BRAM/URAM.
// -----------------------------------------------------------------------------
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

    // Accelerator side: adapter presents the DRAM (slave) face of csd_dram_if.
    csd_dram_if.dram    rd,

    // DRAM side: adapter is the read-only AXI4 master.
    axi4_if.master_rd   axi
);

    // -------------------------------------------------------------------------
    // Derived AXI geometry.
    // -------------------------------------------------------------------------
    localparam int unsigned BEAT_BYTES    = AXI_DATA_W / 8;                 // 16
    localparam int unsigned AXSIZE        = $clog2(BEAT_BYTES);             // 4
    localparam int unsigned MAX_BURST     = 256;                           // AXI4
    localparam int unsigned BOUND_BEATS   = 4096 / BEAT_BYTES;             // 256
    // Burst-length counter must hold 1..MAX_BURST.
    localparam int unsigned BLEN_W        = $clog2(MAX_BURST + 1);          // 9

    // -------------------------------------------------------------------------
    // Elaboration sanity.
    // -------------------------------------------------------------------------
    initial begin : elab_checks
        if (AXI_DATA_W < DRAM_BEAT_W)
            $fatal(1, "axi4_read_adapter: AXI_DATA_W=%0d < DRAM_BEAT_W=%0d",
                   AXI_DATA_W, DRAM_BEAT_W);
        if ((BEAT_BYTES & (BEAT_BYTES - 1)) != 0)
            $fatal(1, "axi4_read_adapter: BEAT_BYTES=%0d not a power of two", BEAT_BYTES);
        if (BOUND_BEATS == 0)
            $fatal(1, "axi4_read_adapter: BEAT_BYTES=%0d exceeds 4KB page", BEAT_BYTES);
    end

    // -------------------------------------------------------------------------
    // FSM.
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] { R_IDLE, R_AR, R_DATA } state_e;
    state_e state_q;

    logic [DRAM_ADDR_W-1:0] addr_q;   // byte address of the next burst
    logic [DRAM_LEN_W-1:0]  rem_q;    // beats remaining in the whole descriptor
    logic [BLEN_W-1:0]      blen_q;   // beats remaining in the current AXI burst

    // -------------------------------------------------------------------------
    // Combinational next-burst length from the current addr_q / rem_q.
    //   bound_left = beats from addr_q to the next 4KB boundary.
    //   this_burst = min(rem_q, bound_left, MAX_BURST).
    //
    // Computed in the descriptor (DRAM_LEN_W) domain so the up-to-65535-beat
    // rem_q is NEVER truncated before the min — a narrower domain would alias a
    // large rem_q down (e.g. 2048 -> 0) and emit a zero-length burst. The result
    // is always <= MAX_BURST (256) because bound_left <= 256 and the cap applies.
    // -------------------------------------------------------------------------
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
    // csd_dram_if (slave face)
    assign rd.req_ready = (state_q == R_IDLE);
    assign rd.rsp_data  = axi.rdata[DRAM_BEAT_W-1:0];
    assign rd.rsp_valid = (state_q == R_DATA) && axi.rvalid;
    assign rd.rsp_last  = (state_q == R_DATA) && (rem_q == DRAM_LEN_W'(1));

    // AXI AR channel
    assign axi.arid    = AXI_ID_W'(0);
    assign axi.araddr  = addr_q;
    assign axi.arlen   = 8'(this_burst - DRAM_LEN_W'(1));
    assign axi.arsize  = 3'(AXSIZE);
    assign axi.arburst = 2'b01; // INCR
    assign axi.arvalid = (state_q == R_AR);

    // AXI R channel
    assign axi.rready  = (state_q == R_DATA) && rd.rsp_ready;

    logic ar_fire, r_fire;
    assign ar_fire = axi.arvalid && axi.arready;
    assign r_fire  = axi.rvalid  && axi.rready;

    // -------------------------------------------------------------------------
    // Sequential.
    // -------------------------------------------------------------------------
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
                        // Latch this burst's beat count; advance the byte address
                        // past this burst for the next AR.
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
                            // Last beat of this AXI burst.
                            state_q <= (rem_q == DRAM_LEN_W'(1)) ? R_IDLE : R_AR;
                        end
                    end
                end
                default: state_q <= R_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    // The AXI slave's RLAST must coincide with this adapter's per-burst last
    // beat (blen_q == 1). If they disagree, the slave returned a different burst
    // length than we requested.
    a_rlast_aligns: assert property (@(posedge clk) disable iff (!rst_n)
        r_fire |-> (axi.rlast == (blen_q == BLEN_W'(1))))
        else $error("axi4_read_adapter: RLAST/blen mismatch (slave burst length disagreement)");

    // rem must never underflow (a beat fired with rem already 0).
    a_no_rem_underflow: assert property (@(posedge clk) disable iff (!rst_n)
        r_fire |-> (rem_q != DRAM_LEN_W'(0)))
        else $error("axi4_read_adapter: R beat fired with rem_q==0 (slave over-streamed)");

    // OKAY response expected from the model (no error injection in C2).
    a_rresp_okay: assert property (@(posedge clk) disable iff (!rst_n)
        r_fire |-> (axi.rresp == 2'b00))
        else $error("axi4_read_adapter: RRESP != OKAY");
`endif

endmodule : axi4_read_adapter

`default_nettype wire
`endif // ARCHBETTER_AXI4_READ_ADAPTER_SV
