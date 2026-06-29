// -----------------------------------------------------------------------------
// archbetter_ku5p_top.sv  (C5 — fully-pinned, non-OOC closure top for XCKU5P)
//
// The synthesis root for the HEADLINE non-OOC closure. It wraps the portable
// archbetter_soc_top (real MMCM, NOT bypass) and instantiates the synthesizable
// axi4_bram_slave behind the AXI memory seam, so the WHOLE design routes/times
// with:
//   * a REAL clock tree (MMCME4_ADV: clk_in board osc -> 250 MHz compute),
//   * full I/O (only the narrow control boundary reaches package pins),
//   * a real memory endpoint the accelerator drives AXI traffic against,
// and therefore closes NON-OOC with publishable WNS / utilization / (SAIF) power
// — superseding the OOC fabric-only stopgap (project memory).
//
// Pinnable boundary (small — this is what fixes the OOC port explosion):
//   clk_in, ext_rst_n, cfg_{we,addr,wdata,rdata}, program_done, locked_o.
// The AXI seam and the BRAM backend are entirely INTERNAL. The DDR4 MIG swaps
// in for axi4_bram_slave at board bring-up behind the unchanged axi4_if seam;
// the published accelerator-core power boundary declares DRAM/MIG external
// (CLAUDE.md §11), so the BRAM backend is a closure endpoint, not a power source.
//
// Constraints: timing_portable.xdc + physical_ku5p.xdc (add_constraints_soc.tcl,
// device=ku5p). Functional data correctness of a full layer is proven separately
// against the behavioral model (C3, tb_archbetter_soc_top); the BRAM backend
// here aliases regions and is for closure only.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_KU5P_TOP_SV
`define ARCHBETTER_KU5P_TOP_SV
`default_nettype none

module archbetter_ku5p_top
    import types_pkg::*;
#(
    parameter int unsigned IMEM_DEPTH = 64,
    // R6.8b/closure: synthesize the LARGE-T prefill config (the one our II=1 wide
    // read + 21%-util claims target). BATCH_T>BANK_REG_MAX selects the gen_bram
    // BRAM accumulator (first-touch writes, NO 45k-flop parallel clear), which
    // removes the tile_first/reset high-fanout net that was the WNS path at 8.
    parameter int unsigned BATCH_T    = 64,
    parameter int unsigned AXI_DATA_W = 128,
    parameter int unsigned AXI_ID_W   = 4,
    parameter int unsigned MEM_DEPTH  = 2048   // BRAM-slave depth (closure endpoint)
) (
    input  wire logic        clk_in,       // board oscillator (100 MHz)
    input  wire logic        ext_rst_n,    // board reset, async, active-low

    input  wire logic        cfg_we,
    input  wire logic [7:0]  cfg_addr,
    input  wire logic [31:0] cfg_wdata,
    output logic [31:0]      cfg_rdata,
    output logic             program_done,
    output logic             locked_o
);

    // -------------------------------------------------------------------------
    // Forward declarations (declared before use to avoid use-before-decl).
    // -------------------------------------------------------------------------
    logic compute_clk_w;
    logic locked_w;
    logic slave_arst;
    logic slave_dest_arst;
    logic slave_rst_n;

    assign locked_o   = locked_w;
    assign slave_arst = ~ext_rst_n | ~locked_w;

    // Compute-domain reset for the BRAM slave — same derivation as soc_top's
    // internal rst_n (assert until board reset releases AND the MMCM locks),
    // synchronized into the compute clock via XPM (CLAUDE.md §6: XPM only).
    xpm_cdc_async_rst #(
        .DEST_SYNC_FF(4), .INIT_SYNC_FF(0), .RST_ACTIVE_HIGH(1)
    ) u_slave_rst (
        .src_arst (slave_arst),
        .dest_clk (compute_clk_w),
        .dest_arst(slave_dest_arst)
    );
    assign slave_rst_n = ~slave_dest_arst;

    // -------------------------------------------------------------------------
    // AXI4 DRAM seam — internal. Clocked in the compute domain (where the soc_top
    // adapters drive it); reset by the slave-domain reset.
    // -------------------------------------------------------------------------
    axi4_if #(.ADDR_W(DRAM_ADDR_W), .DATA_W(AXI_DATA_W), .ID_W(AXI_ID_W))
        m_axi (.clk(compute_clk_w), .rst_n(slave_rst_n));

    // -------------------------------------------------------------------------
    // The SoC wrapper — REAL MMCM (SIM_CLOCK_BYPASS = 0).
    // -------------------------------------------------------------------------
    archbetter_soc_top #(
        .IMEM_DEPTH      (IMEM_DEPTH),
        .BATCH_T         (BATCH_T),
        .AXI_DATA_W      (AXI_DATA_W),
        .AXI_ID_W        (AXI_ID_W),
        .SIM_CLOCK_BYPASS(1'b0)
    ) u_soc (
        .clk_in       (clk_in),
        .ext_rst_n    (ext_rst_n),
        .compute_clk_o(compute_clk_w),
        .locked_o     (locked_w),
        .cfg_we       (cfg_we),
        .cfg_addr     (cfg_addr),
        .cfg_wdata    (cfg_wdata),
        .cfg_rdata    (cfg_rdata),
        .program_done (program_done),
        .m_axi        (m_axi)
    );

    // -------------------------------------------------------------------------
    // Synthesizable BRAM memory backend (DDR4 MIG stand-in for closure).
    //
    // DONT_TOUCH: this BRAM endpoint is the OBSERVATION ANCHOR for the whole
    // accelerator. Its memory is written by the drained compute results and read
    // back to feed the next layer; preserving it forces synthesis to retain the
    // entire AXI write/read seam AND the upstream datapath (dense array, URAM
    // ping-pong, CSD), exactly as a real DDR4 MIG would. Without it the loopback
    // is provably dead and the accelerator is optimized away. (DRAM/MIG is still
    // declared EXTERNAL to the accelerator POWER boundary per CLAUDE.md §11 — this
    // only governs structural retention for area/timing closure.)
    // -------------------------------------------------------------------------
    (* DONT_TOUCH = "yes" *)
    axi4_bram_slave #(
        .AXI_DATA_W(AXI_DATA_W),
        .AXI_ADDR_W(DRAM_ADDR_W),
        .AXI_ID_W  (AXI_ID_W),
        .DEPTH     (MEM_DEPTH)
    ) u_mem (
        .clk  (compute_clk_w),
        .rst_n(slave_rst_n),
        .axi  (m_axi.slave)
    );

endmodule : archbetter_ku5p_top

`default_nettype wire
`endif // ARCHBETTER_KU5P_TOP_SV
