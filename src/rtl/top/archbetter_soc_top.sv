
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
    parameter bit          SIM_CLOCK_BYPASS = 1'b0
) (
    input  wire logic            clk_in,
    input  wire logic            ext_rst_n,
    output logic                 compute_clk_o,
    output logic                 locked_o,
    input  wire logic            cfg_we,
    input  wire logic [7:0]      cfg_addr,
    input  wire logic [31:0]     cfg_wdata,
    output logic [31:0]          cfg_rdata,
    output logic                 program_done,
    axi4_if                      m_axi
);
    logic compute_clk;
    logic locked;

    generate
    if (SIM_CLOCK_BYPASS) begin : g_clk_bypass
        assign compute_clk = clk_in;
        logic [3:0] lock_sr;
        always_ff @(posedge clk_in or negedge ext_rst_n) begin
            if (!ext_rst_n) lock_sr <= '0;
            else            lock_sr <= { lock_sr[2:0], 1'b1 };
        end
        assign locked = lock_sr[3];
    end else begin : g_mmcm
        logic clkfb, clkfb_buf, clkout0, mmcm_locked;
        MMCME4_ADV #(
            .BANDWIDTH          ("OPTIMIZED"),
            .CLKFBOUT_MULT_F    (9.000),
            .CLKFBOUT_PHASE     (0.000),
            .CLKIN1_PERIOD      (10.000),
            .CLKOUT0_DIVIDE_F   (4.000),
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
            .DADDR(7'b0), .DCLK(1'b0), .DEN(1'b0), .DI(16'b0), .DWE(1'b0),
            .DO(), .DRDY(),
            .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(),
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
    logic arst_assert;
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
    csd_dram_if    rd_if (.clk(compute_clk), .rst_n(rst_n));
    csd_dram_wr_if wr_if (.clk(compute_clk), .rst_n(rst_n));

    axi4_read_adapter #(.AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W))
        u_axi_rd (.clk(compute_clk), .rst_n(rst_n), .rd(rd_if.dram), .axi(m_axi.master_rd));

    axi4_write_adapter #(.AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W))
        u_axi_wr (.clk(compute_clk), .rst_n(rst_n), .wr(wr_if.dram), .axi(m_axi.master_wr));
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
        .kv_rd_data_o           (),
        .kv_rd_valid_o          (),
        .y_out                  (),
        .y_valid                (),
        .sparse_out_wr_en       (),
        .sparse_out_wr_addr     (),
        .sparse_out_wr_data     (),
        .d2s_data_o             (),
        .d2s_user_o             (),
        .d2s_valid_o            (),
        .d2s_ready_i            (1'b1),
        .d2s_last_o             (),
        .d2s_almost_full_i      (1'b0),
        .dram_req_addr          (rd_if.req_addr),
        .dram_req_len           (rd_if.req_len),
        .dram_req_valid         (rd_if.req_valid),
        .dram_req_ready         (rd_if.req_ready),
        .dram_rsp_data          (rd_if.rsp_data),
        .dram_rsp_valid         (rd_if.rsp_valid),
        .dram_rsp_ready         (rd_if.rsp_ready),
        .dram_rsp_last          (rd_if.rsp_last),
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
`endif
