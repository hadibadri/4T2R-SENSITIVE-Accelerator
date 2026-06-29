
`timescale 1ns/1ps
`ifndef ARCHBETTER_KU5P_TOP_SV
`define ARCHBETTER_KU5P_TOP_SV
`default_nettype none

module archbetter_ku5p_top
    import types_pkg::*;
#(
    parameter int unsigned IMEM_DEPTH = 64,
    parameter int unsigned BATCH_T    = 64,
    parameter int unsigned AXI_DATA_W = 128,
    parameter int unsigned AXI_ID_W   = 4,
    parameter int unsigned MEM_DEPTH  = 2048
) (
    input  wire logic        clk_in,
    input  wire logic        ext_rst_n,

    input  wire logic        cfg_we,
    input  wire logic [7:0]  cfg_addr,
    input  wire logic [31:0] cfg_wdata,
    output logic [31:0]      cfg_rdata,
    output logic             program_done,
    output logic             locked_o
);
    logic compute_clk_w;
    logic locked_w;
    logic slave_arst;
    logic slave_dest_arst;
    logic slave_rst_n;

    assign locked_o   = locked_w;
    assign slave_arst = ~ext_rst_n | ~locked_w;
    xpm_cdc_async_rst #(
        .DEST_SYNC_FF(4), .INIT_SYNC_FF(0), .RST_ACTIVE_HIGH(1)
    ) u_slave_rst (
        .src_arst (slave_arst),
        .dest_clk (compute_clk_w),
        .dest_arst(slave_dest_arst)
    );
    assign slave_rst_n = ~slave_dest_arst;
    axi4_if #(.ADDR_W(DRAM_ADDR_W), .DATA_W(AXI_DATA_W), .ID_W(AXI_ID_W))
        m_axi (.clk(compute_clk_w), .rst_n(slave_rst_n));
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
`endif
