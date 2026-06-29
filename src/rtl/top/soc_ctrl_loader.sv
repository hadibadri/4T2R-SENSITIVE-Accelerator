
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
    input  wire logic                    cfg_we,
    input  wire logic [7:0]              cfg_addr,
    input  wire logic [31:0]             cfg_wdata,
    output logic [31:0]                  cfg_rdata,
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
    input  wire logic                    program_done
);
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

    localparam int unsigned DESC_W    = $bits(csd_descriptor_t);
    localparam int unsigned DESC_HI_W = DESC_W - 32;
    initial begin : elab_checks
        if (MACRO_WORD_W > 64)
            $fatal(1, "soc_ctrl_loader: MACRO_WORD_W=%0d > 64 (two-word imem load assumes <=64)",
                   MACRO_WORD_W);
        if (DESC_W > 64)
            $fatal(1, "soc_ctrl_loader: csd_descriptor_t=%0d bits > 64 (two-word desc load assumes <=64)",
                   DESC_W);
    end
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

                    default: ;
                endcase
            end
        end
    end
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
`endif
