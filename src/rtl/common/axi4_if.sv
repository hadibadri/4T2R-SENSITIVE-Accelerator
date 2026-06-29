// -----------------------------------------------------------------------------
// axi4_if.sv  (C2 — off-chip DRAM memory seam)
//
// AXI4 (full) interface for the ArchBetter DRAM boundary ONLY. This is the one
// place AXI is allowed: CLAUDE.md §11 mandates that archbetter_soc_top "adapts
// the accelerator's native csd_dram_if / csd_dram_wr_if to an AXI4 master seam,
// with the DDR4 MIG as a swappable block behind it." The accelerator fabric
// (NoC, ping-pong, dispatcher) remains AXI-free — see the strm_if / pingpong_if
// contracts in interfaces.sv. Do NOT use this interface inside the compute fabric.
//
// Scope / simplifications (documented, intentional for the memory seam):
//   * INCR bursts only (AWBURST/ARBURST = 2'b01). FIXED/WRAP are not used by the
//     CSD fill / drain traffic, which is always sequential.
//   * No LOCK / CACHE / PROT / QOS / REGION / USER sidebands. A real MIG ties
//     these to defaults; archbetter_soc_top supplies the constants at the C3
//     flatten boundary. Keeping them out of the contract keeps the adapters lean.
//   * AXI4 max burst is 256 beats (AxLEN is 8 bits, value = beats-1). Bursts must
//     not cross a 4 KB address boundary. The master adapters enforce both
//     (axi4_read_adapter / axi4_write_adapter); the slave/model trusts them.
//
// Parameters:
//   ADDR_W : byte address width        (= types_pkg::DRAM_ADDR_W = 32)
//   DATA_W : AXI data width in bits     (default 128 -> 16 B/beat; one padded
//            72-bit DRAM word per beat, byte-aligned and AXI-legal. A real KU5P
//            DDR4 MIG user port is typically wider; DATA_W is a parameter so the
//            C3 wrapper can match the board MIG without touching the adapters.)
//   ID_W   : transaction ID width       (default 4)
//
// Modports:
//   master    : full master (drives AW/AR/W, sinks B/R). For a single combined
//               master. ArchBetter splits read and write across two adapters, so
//               it uses master_rd + master_wr (disjoint signal sets) on ONE
//               interface instance instead — see below.
//   master_rd : read-only master view  (AR + R). Driven by axi4_read_adapter.
//   master_wr : write-only master view (AW + W + B). Driven by axi4_write_adapter.
//   slave     : full slave (sinks AW/AR/W, drives B/R). Driven by the DRAM model
//               (sim) or the MIG (C3).
//   mon       : passive monitor.
//
// master_rd and master_wr drive DISJOINT subsets of the master outputs (read
// channels vs write channels), so two adapter instances can legally co-drive a
// single axi4_if without contention. The slave drives all slave outputs.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_AXI4_IF_SV
`define ARCHBETTER_AXI4_IF_SV
`default_nettype none

interface axi4_if #(
    parameter int unsigned ADDR_W = 32,
    parameter int unsigned DATA_W = 128,
    parameter int unsigned ID_W   = 4
) (
    input  wire logic clk,
    input  wire logic rst_n
);

    localparam int unsigned STRB_W = DATA_W / 8;

    // -- Write address channel (AW) -------------------------------------------
    logic [ID_W-1:0]   awid;
    logic [ADDR_W-1:0] awaddr;
    logic [7:0]        awlen;     // beats - 1
    logic [2:0]        awsize;    // log2(bytes/beat)
    logic [1:0]        awburst;   // 2'b01 = INCR
    logic              awvalid;
    logic              awready;

    // -- Write data channel (W) -----------------------------------------------
    logic [DATA_W-1:0] wdata;
    logic [STRB_W-1:0] wstrb;
    logic              wlast;
    logic              wvalid;
    logic              wready;

    // -- Write response channel (B) -------------------------------------------
    logic [ID_W-1:0]   bid;
    logic [1:0]        bresp;     // 2'b00 = OKAY
    logic              bvalid;
    logic              bready;

    // -- Read address channel (AR) --------------------------------------------
    logic [ID_W-1:0]   arid;
    logic [ADDR_W-1:0] araddr;
    logic [7:0]        arlen;
    logic [2:0]        arsize;
    logic [1:0]        arburst;
    logic              arvalid;
    logic              arready;

    // -- Read data channel (R) ------------------------------------------------
    logic [ID_W-1:0]   rid;
    logic [DATA_W-1:0] rdata;
    logic [1:0]        rresp;
    logic              rlast;
    logic              rvalid;
    logic              rready;

    // -------------------------------------------------------------------------
    // Modports.
    // -------------------------------------------------------------------------
    modport master (
        output awid, awaddr, awlen, awsize, awburst, awvalid, input awready,
        output wdata, wstrb, wlast, wvalid, input wready,
        input  bid, bresp, bvalid, output bready,
        output arid, araddr, arlen, arsize, arburst, arvalid, input arready,
        input  rid, rdata, rresp, rlast, rvalid, output rready
    );

    modport master_rd (
        output arid, araddr, arlen, arsize, arburst, arvalid, input arready,
        input  rid, rdata, rresp, rlast, rvalid, output rready
    );

    modport master_wr (
        output awid, awaddr, awlen, awsize, awburst, awvalid, input awready,
        output wdata, wstrb, wlast, wvalid, input wready,
        input  bid, bresp, bvalid, output bready
    );

    modport slave (
        input  awid, awaddr, awlen, awsize, awburst, awvalid, output awready,
        input  wdata, wstrb, wlast, wvalid, output wready,
        output bid, bresp, bvalid, input bready,
        input  arid, araddr, arlen, arsize, arburst, arvalid, output arready,
        output rid, rdata, rresp, rlast, rvalid, input rready
    );

    modport mon (
        input awid, awaddr, awlen, awsize, awburst, awvalid, awready,
        input wdata, wstrb, wlast, wvalid, wready,
        input bid, bresp, bvalid, bready,
        input arid, araddr, arlen, arsize, arburst, arvalid, arready,
        input rid, rdata, rresp, rlast, rvalid, rready
    );

`ifndef SYNTHESIS
    // -- Handshake stability (hold-on-backpressure) on each channel. ----------
    property p_aw_stable;
        @(posedge clk) disable iff (!rst_n)
        (awvalid && !awready) |=> (awvalid && $stable(awaddr) && $stable(awlen)
                                            && $stable(awsize) && $stable(awburst));
    endproperty
    a_aw_stable: assert property (p_aw_stable)
        else $error("axi4_if: AW payload changed while awvalid && !awready");

    property p_w_stable;
        @(posedge clk) disable iff (!rst_n)
        (wvalid && !wready) |=> (wvalid && $stable(wdata) && $stable(wstrb)
                                          && $stable(wlast));
    endproperty
    a_w_stable: assert property (p_w_stable)
        else $error("axi4_if: W payload changed while wvalid && !wready");

    property p_ar_stable;
        @(posedge clk) disable iff (!rst_n)
        (arvalid && !arready) |=> (arvalid && $stable(araddr) && $stable(arlen)
                                            && $stable(arsize) && $stable(arburst));
    endproperty
    a_ar_stable: assert property (p_ar_stable)
        else $error("axi4_if: AR payload changed while arvalid && !arready");

    // INCR-only contract on the seam.
    a_aw_incr: assert property (@(posedge clk) disable iff (!rst_n)
        awvalid |-> (awburst == 2'b01))
        else $error("axi4_if: AWBURST != INCR (memory seam is INCR-only)");
    a_ar_incr: assert property (@(posedge clk) disable iff (!rst_n)
        arvalid |-> (arburst == 2'b01))
        else $error("axi4_if: ARBURST != INCR (memory seam is INCR-only)");
`endif

endinterface : axi4_if

`default_nettype wire
`endif // ARCHBETTER_AXI4_IF_SV
