// -----------------------------------------------------------------------------
// soc_ctrl_loader.sv  (C3 — narrow control/loader for archbetter_soc_top)
//
// Collapses archbetter_core's WIDE host-control port explosion behind a single
// narrow 32-bit register-write port, so the SoC top fits the 386-package-pin
// budget (the root cause of the OOC stopgap — see project memory). A host (or
// the C3 peer TB) writes a small register map; the loader fans the values out
// to the core's imem write port, CSD descriptor table, per-layer URAM base
// addresses, and the start strobe, and reads back program_done as status.
//
// The 64-bit imem word and the 62-bit csd_descriptor_t are loaded as two 32-bit
// halves (LO then HI); writing HI commits the word (pulses the core's *_we for
// one cycle) and AUTO-INCREMENTS the target address, so a program or descriptor
// table streams as: set *_ADDR once, then repeat {LO, HI}.
//
// Register map (cfg_addr[7:0], 32-bit cfg_wdata):
//   0x00 CTRL        W  bit0 -> 1-cycle `start` pulse to the dispatcher
//   0x04 STATUS      R  bit0  = program_done
//   0x10 IMEM_ADDR   W  imem target word address (latched)
//   0x14 IMEM_LO     W  imem_wr_data[31:0]  (latched)
//   0x18 IMEM_HI     W  imem_wr_data[63:32] + COMMIT (pulse imem_we, addr++)
//   0x20 DESC_ADDR   W  descriptor table index (latched)
//   0x24 DESC_LO     W  csd_descriptor_t[31:0]  (latched)
//   0x28 DESC_HI     W  csd_descriptor_t[61:32] + COMMIT (pulse desc_we, addr++)
//   0x30 BASE_DW     W  dense_weight_base_addr
//   0x34 BASE_DA     W  dense_act_base_addr
//   0x38 BASE_TL     W  tlmm_base_addr
//   0x3C BASE_OC     W  out_collector_base_addr
//   0x40 BASE_SO     W  sparse_out_base_addr
//
// Not loaded here: kv_wr_data_i (144-bit KV write payload) — the dense/sparse
// layer flow does not use it; archbetter_soc_top ties it to 0. Add a 5-word
// KV_DATA path here if/when an attention TB needs it.
//
// Resource class: a handful of fabric flops (latches + commit pulses). No
// DSP/BRAM/URAM.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_SOC_CTRL_LOADER_SV
`define ARCHBETTER_SOC_CTRL_LOADER_SV
`default_nettype none

module soc_ctrl_loader
    import types_pkg::*;
#(
    parameter int unsigned IMEM_DEPTH  = 64,
    parameter int unsigned IMEM_ADDR_W = $clog2(IMEM_DEPTH)
) (
    input  wire logic                    clk,
    input  wire logic                    rst_n,

    // Narrow host config port.
    input  wire logic                    cfg_we,
    input  wire logic [7:0]              cfg_addr,
    input  wire logic [31:0]             cfg_wdata,
    output logic [31:0]                  cfg_rdata,

    // Wide control fan-out to archbetter_core.
    output logic                         start,
    output logic                         imem_we,
    output logic [IMEM_ADDR_W-1:0]       imem_wr_addr,
    output logic [MACRO_WORD_W-1:0]      imem_wr_data,
    output logic                         desc_we,
    output logic [7:0]                   desc_wr_addr,
    output csd_descriptor_t              desc_wr_data,
    output logic [URAM_ADDR_W-1:0]       dense_weight_base_addr,
    output logic [URAM_ADDR_W-1:0]       dense_act_base_addr,
    output logic [URAM_ADDR_W-1:0]       tlmm_base_addr,
    output logic [URAM_ADDR_W-1:0]       out_collector_base_addr,
    output logic [URAM_ADDR_W-1:0]       sparse_out_base_addr,

    // Status in.
    input  wire logic                    program_done
);

    // -------------------------------------------------------------------------
    // Register map.
    // -------------------------------------------------------------------------
    localparam logic [7:0] ADDR_CTRL      = 8'h00;
    localparam logic [7:0] ADDR_STATUS    = 8'h04;
    localparam logic [7:0] ADDR_IMEM_ADDR = 8'h10;
    localparam logic [7:0] ADDR_IMEM_LO   = 8'h14;
    localparam logic [7:0] ADDR_IMEM_HI   = 8'h18;
    localparam logic [7:0] ADDR_DESC_ADDR = 8'h20;
    localparam logic [7:0] ADDR_DESC_LO   = 8'h24;
    localparam logic [7:0] ADDR_DESC_HI   = 8'h28;
    localparam logic [7:0] ADDR_BASE_DW   = 8'h30;
    localparam logic [7:0] ADDR_BASE_DA   = 8'h34;
    localparam logic [7:0] ADDR_BASE_TL   = 8'h38;
    localparam logic [7:0] ADDR_BASE_OC   = 8'h3C;
    localparam logic [7:0] ADDR_BASE_SO   = 8'h40;

    localparam int unsigned DESC_W    = $bits(csd_descriptor_t);   // 62
    localparam int unsigned DESC_HI_W = DESC_W - 32;               // 30

    // -------------------------------------------------------------------------
    // Elaboration sanity: both wide payloads must fit two 32-bit halves.
    // -------------------------------------------------------------------------
    initial begin : elab_checks
        if (MACRO_WORD_W > 64)
            $fatal(1, "soc_ctrl_loader: MACRO_WORD_W=%0d > 64 (two-word imem load assumes <=64)",
                   MACRO_WORD_W);
        if (DESC_W > 64)
            $fatal(1, "soc_ctrl_loader: csd_descriptor_t=%0d bits > 64 (two-word desc load assumes <=64)",
                   DESC_W);
    end

    // -------------------------------------------------------------------------
    // Latches + commit pulses.
    // -------------------------------------------------------------------------
    logic [IMEM_ADDR_W-1:0]  imem_addr_q;
    logic [31:0]             imem_lo_q;
    logic [7:0]              desc_addr_q;
    logic [31:0]             desc_lo_q;

    logic                    start_q, imem_we_q, desc_we_q;
    logic [IMEM_ADDR_W-1:0]  imem_wr_addr_q;
    logic [MACRO_WORD_W-1:0] imem_wr_data_q;
    logic [7:0]              desc_wr_addr_q;
    csd_descriptor_t         desc_wr_data_q;
    logic [URAM_ADDR_W-1:0]  base_dw_q, base_da_q, base_tl_q, base_oc_q, base_so_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            imem_addr_q    <= '0;
            imem_lo_q      <= '0;
            desc_addr_q    <= '0;
            desc_lo_q      <= '0;
            start_q        <= 1'b0;
            imem_we_q      <= 1'b0;
            desc_we_q      <= 1'b0;
            imem_wr_addr_q <= '0;
            imem_wr_data_q <= '0;
            desc_wr_addr_q <= '0;
            desc_wr_data_q <= '0;
            base_dw_q      <= '0;
            base_da_q      <= '0;
            base_tl_q      <= '0;
            base_oc_q      <= '0;
            base_so_q      <= '0;
        end else begin
            // Commit pulses are one cycle.
            start_q   <= 1'b0;
            imem_we_q <= 1'b0;
            desc_we_q <= 1'b0;

            if (cfg_we) begin
                unique case (cfg_addr)
                    ADDR_CTRL: start_q <= cfg_wdata[0];

                    ADDR_IMEM_ADDR: imem_addr_q <= cfg_wdata[IMEM_ADDR_W-1:0];
                    ADDR_IMEM_LO:   imem_lo_q   <= cfg_wdata;
                    ADDR_IMEM_HI: begin
                        imem_we_q      <= 1'b1;
                        imem_wr_addr_q <= imem_addr_q;
                        imem_wr_data_q <= { cfg_wdata, imem_lo_q };
                        imem_addr_q    <= IMEM_ADDR_W'(imem_addr_q + 1'b1);
                    end

                    ADDR_DESC_ADDR: desc_addr_q <= cfg_wdata[7:0];
                    ADDR_DESC_LO:   desc_lo_q   <= cfg_wdata;
                    ADDR_DESC_HI: begin
                        desc_we_q      <= 1'b1;
                        desc_wr_addr_q <= desc_addr_q;
                        desc_wr_data_q <= csd_descriptor_t'(
                                            { cfg_wdata[DESC_HI_W-1:0], desc_lo_q });
                        desc_addr_q    <= 8'(desc_addr_q + 1'b1);
                    end

                    ADDR_BASE_DW: base_dw_q <= cfg_wdata[URAM_ADDR_W-1:0];
                    ADDR_BASE_DA: base_da_q <= cfg_wdata[URAM_ADDR_W-1:0];
                    ADDR_BASE_TL: base_tl_q <= cfg_wdata[URAM_ADDR_W-1:0];
                    ADDR_BASE_OC: base_oc_q <= cfg_wdata[URAM_ADDR_W-1:0];
                    ADDR_BASE_SO: base_so_q <= cfg_wdata[URAM_ADDR_W-1:0];

                    default: ; // unmapped address -> no-op
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // Outputs.
    // -------------------------------------------------------------------------
    assign start                   = start_q;
    assign imem_we                 = imem_we_q;
    assign imem_wr_addr            = imem_wr_addr_q;
    assign imem_wr_data            = imem_wr_data_q;
    assign desc_we                 = desc_we_q;
    assign desc_wr_addr            = desc_wr_addr_q;
    assign desc_wr_data            = desc_wr_data_q;
    assign dense_weight_base_addr  = base_dw_q;
    assign dense_act_base_addr     = base_da_q;
    assign tlmm_base_addr          = base_tl_q;
    assign out_collector_base_addr = base_oc_q;
    assign sparse_out_base_addr    = base_so_q;

    always_comb begin
        cfg_rdata = 32'b0;
        if (cfg_addr == ADDR_STATUS) cfg_rdata = { 31'b0, program_done };
    end

endmodule : soc_ctrl_loader

`default_nettype wire
`endif // ARCHBETTER_SOC_CTRL_LOADER_SV
