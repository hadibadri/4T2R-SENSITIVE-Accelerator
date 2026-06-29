// -----------------------------------------------------------------------------
// archbetter_soc_top.sv  (C3 — non-OOC SoC wrapper)
//
// The thin board-facing wrapper that gets ArchBetter OFF the out-of-context
// stopgap (CLAUDE.md §11). It is the ONLY file that sees board specifics;
// everything at archbetter_core and below is untouched and portable KU5P<->VU9P.
//
// What it does:
//   1. CLOCK    — generates the compute clock from a board oscillator via an
//                 MMCME4_ADV (100 MHz in -> 250 MHz compute). SIM_CLOCK_BYPASS
//                 routes clk_in straight through for fast functional sim (the
//                 wrapper datapath is what the C3 TB verifies; the real MMCM is
//                 exercised at synth/impl, C5).
//   2. RESET    — synchronizes the async board reset into the compute domain via
//                 xpm_cdc_async_rst, held asserted until the MMCM locks (XPM
//                 only, per §6 — no ad-hoc synchronizers).
//   3. CONTROL  — collapses the wide host-control ports behind soc_ctrl_loader's
//                 narrow 32-bit cfg port (the OOC root cause — see project memory).
//                 y_out (5632 b) is DROPPED as a pin: dense results reach DRAM
//                 via OP_ST_OUT and are read back from there.
//   4. MEMORY   — adapts the accelerator's native csd_dram_if / csd_dram_wr_if to
//                 an AXI4 master seam (the C2 axi4_read/write_adapter), with the
//                 DDR4 MIG (synth) or axi4_dram_model (sim) as the swappable block
//                 behind m_axi.
//
// Boundary (pinnable): { clk_in, ext_rst_n, narrow cfg bus, program_done,
//                        m_axi (-> MIG at C5) }. The AXI is exposed as an
//                        interface for clean sim wiring; the C5 synth top flattens
//                        it to MIG ports in one place.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_SOC_TOP_SV
`define ARCHBETTER_SOC_TOP_SV
`default_nettype none

module archbetter_soc_top
    import types_pkg::*;
#(
    parameter int unsigned IMEM_DEPTH       = 64,
    parameter int unsigned IMEM_ADDR_W      = $clog2(IMEM_DEPTH),
    parameter int unsigned BATCH_T          = 8,
    parameter int unsigned AXI_DATA_W       = 128,
    parameter int unsigned AXI_ID_W         = 4,
    // Functional-sim clock bypass (1 = clk_in straight through, no MMCM lock wait).
    parameter bit          SIM_CLOCK_BYPASS = 1'b0
) (
    // ---- Board ----
    input  wire logic            clk_in,       // board oscillator (e.g. 100 MHz)
    input  wire logic            ext_rst_n,    // board reset, async, active-low
    output logic                 compute_clk_o,// observability
    output logic                 locked_o,     // MMCM locked

    // ---- Narrow host control/loader port ----
    input  wire logic            cfg_we,
    input  wire logic [7:0]      cfg_addr,
    input  wire logic [31:0]     cfg_wdata,
    output logic [31:0]          cfg_rdata,
    output logic                 program_done,

    // ---- AXI4 master to off-chip DRAM (MIG in synth / model in sim) ----
    axi4_if                      m_axi
);

    // The m_axi interface instance (created by the parent) must be parameterized
    // with DATA_W=AXI_DATA_W and ID_W=AXI_ID_W to match the adapters below; this
    // is a wiring contract on the instantiator (the C3 TB / C5 synth wrapper).

    // =========================================================================
    // 1. Clock generation.
    // =========================================================================
    logic compute_clk;
    logic locked;

    generate
    if (SIM_CLOCK_BYPASS) begin : g_clk_bypass
        // Functional sim: route the board clock straight through. `locked` rises
        // a few cycles after reset deasserts (models the MMCM lock handshake).
        // The async-reset flop here is the legitimate §6 exception: a reset/clock
        // management circuit driven by the external async board reset pin.
        assign compute_clk = clk_in;
        logic [3:0] lock_sr;
        always_ff @(posedge clk_in or negedge ext_rst_n) begin
            if (!ext_rst_n) lock_sr <= '0;
            else            lock_sr <= { lock_sr[2:0], 1'b1 };
        end
        assign locked = lock_sr[3];
    end else begin : g_mmcm
        // Synth/impl: real MMCME4_ADV, 100 MHz -> VCO 900 MHz -> 225 MHz.
        // (Validated at synth; the functional sim uses the bypass branch.)
        //
        // FREQUENCY: 225 MHz (4.444 ns), NOT 250. Rationale (C5 closure, 2026-06-16):
        // at 250 MHz the routed WNS was only +0.025-0.031 ns (~0.7% slack) with
        // congestion level 5 — meets timing but fails the §8 >=10%-headroom bar and
        // is fragile to run-to-run variance. 225 MHz buys ~10.6% predicted slack.
        // It is also EXACTLY FlightLLM's U280 clock and just under TeLLMe's 250 MHz
        // (KV260) — squarely in the edge-FPGA cohort, not slow. The headline
        // throughput is utilization-bound (dense-array residency), not frequency-
        // bound, so achieved tokens/s barely moves; energy-efficiency improves.
        // The DSP/BRAM OREG cannot merge into the dont_touch'd BRAM endpoint
        // (dont_touch forbids register absorption — the hollow-shell DCE fix), so
        // the un-pipelined BRAM->fabric hop is part of what 250 MHz could not absorb.
        // To slow further (if post-route WNS < ~0.44 ns), set MULT_F=8.800 -> 220 MHz.
        // The board-osc create_clock (timing_portable.xdc) stays 100 MHz; Vivado
        // AUTO-DERIVES the 225 MHz generated clock from CLKOUT0 — do not hand-write it.
        logic clkfb, clkfb_buf, clkout0, mmcm_locked;
        MMCME4_ADV #(
            .BANDWIDTH          ("OPTIMIZED"),
            .CLKFBOUT_MULT_F    (9.000),    // 100 MHz x 9 / 1 = VCO 900 MHz (in -3 range)
            .CLKFBOUT_PHASE     (0.000),
            .CLKIN1_PERIOD      (10.000),
            .CLKOUT0_DIVIDE_F   (4.000),    // VCO 900 / 4 = 225 MHz compute clock
            .CLKOUT0_DUTY_CYCLE (0.500),
            .CLKOUT0_PHASE      (0.000),
            .DIVCLK_DIVIDE      (1),
            .REF_JITTER1        (0.010),
            .STARTUP_WAIT       ("FALSE")
        ) u_mmcm (
            .CLKIN1   (clk_in),
            .CLKIN2   (1'b0),
            .CLKINSEL (1'b1),
            .CLKFBIN  (clkfb_buf),
            .CLKFBOUT (clkfb),
            .CLKFBOUTB(),
            .CLKOUT0  (clkout0),
            .CLKOUT0B (),
            .CLKOUT1  (), .CLKOUT1B(),
            .CLKOUT2  (), .CLKOUT2B(),
            .CLKOUT3  (), .CLKOUT3B(),
            .CLKOUT4  (),
            .CLKOUT5  (),
            .CLKOUT6  (),
            .LOCKED   (mmcm_locked),
            .RST      (~ext_rst_n),
            .PWRDWN   (1'b0),
            // Dynamic reconfig (unused).
            .DADDR(7'b0), .DCLK(1'b0), .DEN(1'b0), .DI(16'b0), .DWE(1'b0),
            .DO(), .DRDY(),
            // Phase shift (unused).
            .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(),
            // Clock-stop / cddc (unused).
            .CLKINSTOPPED(), .CLKFBSTOPPED(),
            .CDDCREQ(1'b0), .CDDCDONE()
        );
        BUFG u_bufg_fb  (.I(clkfb),   .O(clkfb_buf));
        BUFG u_bufg_out (.I(clkout0), .O(compute_clk));
        assign locked = mmcm_locked;
    end
    endgenerate

    assign compute_clk_o = compute_clk;
    assign locked_o      = locked;

    // =========================================================================
    // 2. Reset synchronizer (XPM, gated on lock).
    // =========================================================================
    logic arst_assert;   // async assert: board reset low OR MMCM unlocked
    logic dest_arst;
    logic rst_n;

    assign arst_assert = ~ext_rst_n | ~locked;

    xpm_cdc_async_rst #(
        .DEST_SYNC_FF   (4),
        .INIT_SYNC_FF   (0),
        .RST_ACTIVE_HIGH(1)
    ) u_rst_sync (
        .src_arst (arst_assert),
        .dest_clk (compute_clk),
        .dest_arst(dest_arst)
    );

    assign rst_n = ~dest_arst;

    // =========================================================================
    // 3. Narrow control loader -> wide core control.
    // =========================================================================
    logic                    ld_start;
    logic                    ld_imem_we;
    logic [IMEM_ADDR_W-1:0]  ld_imem_addr;
    logic [MACRO_WORD_W-1:0] ld_imem_data;
    logic                    ld_desc_we;
    logic [7:0]              ld_desc_addr;
    csd_descriptor_t         ld_desc_data;
    logic [URAM_ADDR_W-1:0]  ld_base_dw, ld_base_da, ld_base_tl, ld_base_oc, ld_base_so;
    logic                    prog_done_w;

    assign program_done = prog_done_w;

    soc_ctrl_loader #(.IMEM_DEPTH(IMEM_DEPTH)) u_loader (
        .clk(compute_clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .cfg_rdata(cfg_rdata),
        .start(ld_start),
        .imem_we(ld_imem_we), .imem_wr_addr(ld_imem_addr), .imem_wr_data(ld_imem_data),
        .desc_we(ld_desc_we), .desc_wr_addr(ld_desc_addr), .desc_wr_data(ld_desc_data),
        .dense_weight_base_addr(ld_base_dw), .dense_act_base_addr(ld_base_da),
        .tlmm_base_addr(ld_base_tl), .out_collector_base_addr(ld_base_oc),
        .sparse_out_base_addr(ld_base_so),
        .program_done(prog_done_w)
    );

    // =========================================================================
    // 4. Memory seam: native DRAM interfaces -> AXI4 adapters -> m_axi.
    // =========================================================================
    csd_dram_if    rd_if (.clk(compute_clk), .rst_n(rst_n));
    csd_dram_wr_if wr_if (.clk(compute_clk), .rst_n(rst_n));

    axi4_read_adapter #(.AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W))
        u_axi_rd (.clk(compute_clk), .rst_n(rst_n), .rd(rd_if.dram), .axi(m_axi.master_rd));

    axi4_write_adapter #(.AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W))
        u_axi_wr (.clk(compute_clk), .rst_n(rst_n), .wr(wr_if.dram), .axi(m_axi.master_wr));

    // =========================================================================
    // 5. The accelerator core. Wide host control comes from the loader; the
    //    flat DRAM ports bind directly to the native interfaces (the core is the
    //    .mgr, the adapters the .dram). Observability outputs (y_out, sparse_out,
    //    d2s, kv) are intentionally left open — results exit via DRAM (ST_OUT).
    //
    //    DONT_TOUCH (CRITICAL for non-OOC closure): in the closed SoC the core's
    //    results leave only through the AXI write seam to DRAM. In the REAL product
    //    that AXI lands on the DDR4 MIG driving package pins, so the datapath is
    //    observable and retained. In a board-less synth the DRAM is an on-chip
    //    stand-in (axi4_bram_slave), so without this attribute synthesis proves the
    //    whole write->compute->read loop is unobservable and DELETES the entire
    //    accelerator (0 DSP / 0 URAM / 0 BRAM — a hollow shell). DONT_TOUCH makes
    //    the synth context match real deployment and preserves the full 512-DSP /
    //    5-URAM datapath. Harmless in sim (SIM_CLOCK_BYPASS path) and when a real
    //    MIG is present. Pairs with DONT_TOUCH on the BRAM endpoint in the synth top.
    // =========================================================================
    (* DONT_TOUCH = "yes" *)
    archbetter_core #(
        .IMEM_DEPTH    (IMEM_DEPTH),
        .N_NOC_SOURCES (1),
        .BATCH_T       (BATCH_T),
        .D2S_FIFO_DEPTH(64)
    ) u_core (
        .clk                    (compute_clk),
        .rst_n                  (rst_n),
        .start                  (ld_start),
        .program_done           (prog_done_w),
        .imem_we                (ld_imem_we),
        .imem_wr_addr           (ld_imem_addr),
        .imem_wr_data           (ld_imem_data),
        .desc_we                (ld_desc_we),
        .desc_wr_addr           (ld_desc_addr),
        .desc_wr_data           (ld_desc_data),
        .dense_weight_base_addr (ld_base_dw),
        .dense_act_base_addr    (ld_base_da),
        .tlmm_base_addr         (ld_base_tl),
        .out_collector_base_addr(ld_base_oc),
        .sparse_out_base_addr   (ld_base_so),
        .kv_wr_data_i           ('0),
        .kv_rd_data_o           (/* open */),
        .kv_rd_valid_o          (/* open */),
        .y_out                  (/* open — dropped pin, results go to DRAM */),
        .y_valid                (/* open */),
        .sparse_out_wr_en       (/* open */),
        .sparse_out_wr_addr     (/* open */),
        .sparse_out_wr_data     (/* open */),
        .d2s_data_o             (/* open */),
        .d2s_user_o             (/* open */),
        .d2s_valid_o            (/* open */),
        .d2s_ready_i            (1'b1),
        .d2s_last_o             (/* open */),
        .d2s_almost_full_i      (1'b0),
        // DRAM read master -> rd_if (-> axi4_read_adapter -> m_axi)
        .dram_req_addr          (rd_if.req_addr),
        .dram_req_len           (rd_if.req_len),
        .dram_req_valid         (rd_if.req_valid),
        .dram_req_ready         (rd_if.req_ready),
        .dram_rsp_data          (rd_if.rsp_data),
        .dram_rsp_valid         (rd_if.rsp_valid),
        .dram_rsp_ready         (rd_if.rsp_ready),
        .dram_rsp_last          (rd_if.rsp_last),
        // DRAM write master -> wr_if (-> axi4_write_adapter -> m_axi)
        .dram_wr_req_addr       (wr_if.req_addr),
        .dram_wr_req_len        (wr_if.req_len),
        .dram_wr_req_valid      (wr_if.req_valid),
        .dram_wr_req_ready      (wr_if.req_ready),
        .dram_wr_wd_data        (wr_if.wd_data),
        .dram_wr_wd_valid       (wr_if.wd_valid),
        .dram_wr_wd_ready       (wr_if.wd_ready),
        .dram_wr_wd_last        (wr_if.wd_last)
    );

endmodule : archbetter_soc_top

`default_nettype wire
`endif // ARCHBETTER_SOC_TOP_SV
