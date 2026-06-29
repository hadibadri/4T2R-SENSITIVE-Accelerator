
`timescale 1ns/1ps
`ifndef ARCHBETTER_TOP_SV
`define ARCHBETTER_TOP_SV
`default_nettype none

module archbetter_top
    import types_pkg::*;
#(
    parameter int unsigned IMEM_DEPTH    = 64,
    parameter int unsigned IMEM_ADDR_W   = $clog2(IMEM_DEPTH),
    parameter int unsigned N_NOC_SOURCES = 1,
    parameter int unsigned PP_NATIVE_W   = URAM_WIDTH_BITS,
    parameter int unsigned PP_CASCADE_W  = 2 * URAM_WIDTH_BITS,
    parameter int unsigned D2S_FIFO_DEPTH = 64
) (
    input  wire logic clk,
    input  wire logic rst_n,
    input  wire logic                          start,
    output logic                               program_done,
    input  wire logic                          imem_we,
    input  wire logic [IMEM_ADDR_W-1:0]        imem_wr_addr,
    input  wire logic [MACRO_WORD_W-1:0]       imem_wr_data,
    input  wire logic                          desc_we,
    input  wire logic [7:0]                    desc_wr_addr,
    input  wire csd_descriptor_t               desc_wr_data,
    input  wire logic                                      w_we,
    input  wire logic [$clog2(DENSE_GROUPS_ROW)-1:0]       w_gr,
    input  wire logic [$clog2(DENSE_GROUPS_COL)-1:0]       w_gc,
    input  wire logic [$clog2(DENSE_PE_PER_GROUP)-1:0]     w_pe_addr,
    input  wire bfp12_mant_t                               w_in,
    input  wire logic [$clog2(DENSE_LOGICAL_TILE_ROWS)-1:0] tile_gr,
    input  wire logic [$clog2(DENSE_LOGICAL_TILE_COLS)-1:0] tile_gc,
    input  wire logic                                       tile_first,
    input  wire logic                                       tile_last,
    input  wire logic [URAM_ADDR_W-1:0]        dense_act_base_addr,
    input  wire logic [URAM_ADDR_W-1:0]        tlmm_base_addr,
    input  wire logic [URAM_ADDR_W-1:0]        out_collector_base_addr,
    input  wire logic [URAM_ADDR_W-1:0]        sparse_out_base_addr,
    input  wire logic [KV_DATA_W-1:0]          kv_wr_data_i,
    output logic [KV_DATA_W-1:0]               kv_rd_data_o,
    output logic                               kv_rd_valid_o,
    output array_acc_t [DENSE_ARRAY_COLS-1:0]  y_out,
    output logic                               y_valid,
    output logic                               sparse_out_wr_en,
    output logic [URAM_ADDR_W-1:0]             sparse_out_wr_addr,
    output logic [URAM_WIDTH_BITS-1:0]         sparse_out_wr_data,
    output logic [NOC_DATA_W-1:0]              d2s_data_o,
    output logic [NOC_USER_W-1:0]              d2s_user_o,
    output logic                               d2s_valid_o,
    input  wire logic                          d2s_ready_i,
    output logic                               d2s_last_o,
    input  wire logic                          d2s_almost_full_i,
    output logic [DRAM_ADDR_W-1:0]             dram_req_addr,
    output logic [DRAM_LEN_W-1:0]              dram_req_len,
    output logic                               dram_req_valid,
    input  wire logic                          dram_req_ready,
    input  wire logic [DRAM_BEAT_W-1:0]        dram_rsp_data,
    input  wire logic                          dram_rsp_valid,
    output logic                               dram_rsp_ready,
    input  wire logic                          dram_rsp_last,
    output logic [DRAM_ADDR_W-1:0]             dram_wr_req_addr,
    output logic [DRAM_LEN_W-1:0]              dram_wr_req_len,
    output logic                               dram_wr_req_valid,
    input  wire logic                          dram_wr_req_ready,
    output logic [DRAM_BEAT_W-1:0]             dram_wr_wd_data,
    output logic                               dram_wr_wd_valid,
    input  wire logic                          dram_wr_wd_ready,
    output logic                               dram_wr_wd_last
);
    initial begin : top_elab_checks
        if (N_NOC_SOURCES != 1) begin
            $fatal(1, "archbetter_top: N_NOC_SOURCES=%0d unsupported; this revision is single-source",
                   N_NOC_SOURCES);
        end
        if (PP_NATIVE_W != URAM_WIDTH_BITS) begin
            $fatal(1, "archbetter_top: PP_NATIVE_W=%0d != URAM_WIDTH_BITS=%0d",
                   PP_NATIVE_W, URAM_WIDTH_BITS);
        end
        if (PP_CASCADE_W != 2 * URAM_WIDTH_BITS) begin
            $fatal(1, "archbetter_top: PP_CASCADE_W=%0d != 2*URAM_WIDTH_BITS=%0d",
                   PP_CASCADE_W, 2 * URAM_WIDTH_BITS);
        end
    end
    noc_cfg_if cfg_bus [N_NOC_SOURCES] (.clk(clk), .rst_n(rst_n));

    strm_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W))
        src      [N_NOC_SOURCES] (.clk(clk), .rst_n(rst_n));
    strm_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W))
        noc_dst  [NOC_NODES]     (.clk(clk), .rst_n(rst_n));
    strm_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W))
        a_strm (.clk(clk), .rst_n(rst_n));

    gemm_issue_if gemm_bus (.clk(clk), .rst_n(rst_n));
    tlmm_issue_if tlmm_bus (.clk(clk), .rst_n(rst_n));
    tlmm_ctrl_if  tlmm_ctrl (.clk(clk), .rst_n(rst_n));
    dense_sched_if sched_bus (.clk(clk), .rst_n(rst_n));
    assign sched_bus.load_done = 1'b0;
    assign sched_bus.w_we      = 1'b0;
    assign sched_bus.w_phys_gc = '0;
    assign sched_bus.w_pe_addr = '0;
    assign sched_bus.w_in      = '0;

    mem_issue_if  mem_bus  (.clk(clk), .rst_n(rst_n));
    kv_access_if  kv_bus   (.clk(clk), .rst_n(rst_n));
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_NATIVE_W)) dense_pp_native
        (.clk(clk), .rst_n(rst_n));
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_NATIVE_W)) sparse_pp_native
        (.clk(clk), .rst_n(rst_n));
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_CASCADE_W)) dense_pp_cascade
        (.clk(clk), .rst_n(rst_n));
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_CASCADE_W)) sparse_pp_cascade
        (.clk(clk), .rst_n(rst_n));
    dense2sparse_if #(
        .DATA_W    (NOC_DATA_W),
        .USER_W    (NOC_USER_W),
        .FIFO_DEPTH(D2S_FIFO_DEPTH)
    ) d2s_in  (.clk(clk), .rst_n(rst_n));
    dense2sparse_if #(
        .DATA_W    (NOC_DATA_W),
        .USER_W    (NOC_USER_W),
        .FIFO_DEPTH(D2S_FIFO_DEPTH)
    ) d2s_out (.clk(clk), .rst_n(rst_n));

    csd_dram_if    dram_bus    (.clk(clk), .rst_n(rst_n));
    csd_dram_wr_if dram_wr_bus (.clk(clk), .rst_n(rst_n));
    logic [NOC_PATH_ID_W-1:0] path_id [N_NOC_SOURCES];
    dispatcher #(
        .IMEM_DEPTH    (IMEM_DEPTH),
        .N_NOC_SOURCES (N_NOC_SOURCES)
    ) u_dispatcher (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .program_done (program_done),
        .imem_we      (imem_we),
        .imem_wr_addr (imem_wr_addr),
        .imem_wr_data (imem_wr_data),
        .path_id_o    (path_id),
        .noc_cfg      (cfg_bus[0]),
        .gemm         (gemm_bus.disp),
        .tlmm         (tlmm_bus.disp),
        .sched        (sched_bus.walker),
        .mem_issue    (mem_bus.disp),
        .kv           (kv_bus.master),
        .kv_wr_data_i (kv_wr_data_i),
        .dense_drain_busy (1'b0)
    );

    assign kv_rd_data_o  = kv_bus.rd_data;
    assign kv_rd_valid_o = kv_bus.rd_valid;
    logic                        out_wr_en_w;
    logic [URAM_ADDR_W-1:0]      out_wr_addr_w;
    logic [URAM_WIDTH_BITS-1:0]  out_wr_data_w;
    memory_manager #(
        .DESC_DEPTH (256)
    ) u_memmgr (
        .clk          (clk),
        .rst_n        (rst_n),
        .issue        (mem_bus.mgr),
        .kv           (kv_bus.slave),
        .dense_pp     (dense_pp_native.mem_mgr),
        .sparse_pp    (sparse_pp_native.mem_mgr),
        .dram         (dram_bus.mgr),
        .dram_wr      (dram_wr_bus.mgr),
        .out_wr_en    (out_wr_en_w),
        .out_wr_addr  (out_wr_addr_w),
        .out_wr_data  (out_wr_data_w),
        .desc_we      (desc_we),
        .desc_wr_addr (desc_wr_addr),
        .desc_wr_data (desc_wr_data)
    );
    uram_cascade_adapter #(
        .UP_DATA_W(PP_NATIVE_W),
        .DN_DATA_W(PP_CASCADE_W),
        .UP_ADDR_W(URAM_ADDR_W),
        .DN_ADDR_W(URAM_ADDR_W)
    ) u_dense_cascade (
        .clk  (clk),
        .rst_n(rst_n),
        .up   (dense_pp_native.core),
        .dn   (dense_pp_cascade.mem_mgr)
    );

    uram_cascade_adapter #(
        .UP_DATA_W(PP_NATIVE_W),
        .DN_DATA_W(PP_CASCADE_W),
        .UP_ADDR_W(URAM_ADDR_W),
        .DN_ADDR_W(URAM_ADDR_W)
    ) u_sparse_cascade (
        .clk  (clk),
        .rst_n(rst_n),
        .up   (sparse_pp_native.core),
        .dn   (sparse_pp_cascade.mem_mgr)
    );
    noc_fabric #(
        .N_SOURCES (N_NOC_SOURCES),
        .DATA_W    (NOC_DATA_W),
        .USER_W    (NOC_USER_W)
    ) u_fabric (
        .clk     (clk),
        .rst_n   (rst_n),
        .path_id (path_id),
        .cfg     (cfg_bus),
        .src     (src),
        .dst     (noc_dst)
    );
    logic [NOC_DATA_W-1:0] dst_data_unbund  [DENSE_LOGICAL_TILE_ROWS];
    logic [NOC_USER_W-1:0] dst_user_unbund  [DENSE_LOGICAL_TILE_ROWS];
    logic                  dst_valid_unbund [DENSE_LOGICAL_TILE_ROWS];
    logic                  dst_last_unbund  [DENSE_LOGICAL_TILE_ROWS];

    for (genvar G = 0; G < int'(DENSE_LOGICAL_TILE_ROWS); G++) begin : gen_dst_unbundle
        assign dst_data_unbund[G]  = noc_dst[G].data;
        assign dst_user_unbund[G]  = noc_dst[G].user;
        assign dst_valid_unbund[G] = noc_dst[G].valid;
        assign dst_last_unbund[G]  = noc_dst[G].last;
    end : gen_dst_unbundle

    assign a_strm.data  = dst_data_unbund [tile_gr];
    assign a_strm.user  = dst_user_unbund [tile_gr];
    assign a_strm.valid = dst_valid_unbund[tile_gr];
    assign a_strm.last  = dst_last_unbund [tile_gr];

    for (genvar G = 0; G < int'(DENSE_LOGICAL_TILE_ROWS); G++) begin : gen_dst_row_tile_ready
        assign noc_dst[G].ready = (tile_gr == ($clog2(DENSE_LOGICAL_TILE_ROWS))'(G))
                                  ? a_strm.ready : 1'b1;
    end : gen_dst_row_tile_ready

    for (genvar D = int'(DENSE_LOGICAL_TILE_ROWS); D < int'(NOC_NODES); D++)
    begin : gen_dst_unused_tieoff
        assign noc_dst[D].ready = 1'b1;
    end : gen_dst_unused_tieoff
    dense_act_streamer #(
        .PP_DATA_W(PP_CASCADE_W)
    ) u_streamer (
        .clk      (clk),
        .rst_n    (rst_n),
        .base_addr(dense_act_base_addr),
        .token_stride(URAM_ADDR_W'(2)),
        .gemm     (gemm_bus.drv),
        .pp       (dense_pp_cascade.core),
        .src      (src[0])
    );
    array_acc_t [DENSE_ARRAY_COLS-1:0] y_out_w;
    logic                              y_valid_w;
    logic w_phys_gc;
    assign w_phys_gc = w_gc[0];

    dense_array #(
        .ENABLE_NOISE_HOOKS (1'b0),
        .ARRAY_ID           (32'd0)
    ) u_array (
        .clk        (clk),
        .rst_n      (rst_n),
        .a_strm     (a_strm),
        .tile_gr    (tile_gr),
        .tile_gc    (tile_gc),
        .tile_tok   (BATCH_TOK_W'(0)),
        .batch_n    (BATCH_TOK_W'(1)),
        .drain_busy (1'b0),
        .tile_first (tile_first),
        .tile_last  (tile_last),
        .acc_clr    (gemm_bus.acc_clr),
        .acc_snap   (gemm_bus.acc_snap),
        .stream_mode (GEMM_SNAP_PER_TOKEN),
        .w_we       (w_we),
        .w_phys_gc  (w_phys_gc),
        .w_pe_addr  (w_pe_addr),
        .w_in       (w_in),
        .y_out      (y_out_w),
        .y_valid    (y_valid_w)
    );

    assign y_out   = y_out_w;
    assign y_valid = y_valid_w;
    dense_out_collector #(
        .WR_DATA_W(URAM_WIDTH_BITS)
    ) u_collector (
        .clk          (clk),
        .rst_n        (rst_n),
        .y_valid      (y_valid_w),
        .y_out        (y_out_w),
        .wr_base_addr (out_collector_base_addr),
        .wr_en        (out_wr_en_w),
        .wr_addr      (out_wr_addr_w),
        .wr_data      (out_wr_data_w),
        .d2s          (d2s_in.dense),
        .busy_o       ()
    );
    dense2sparse_fifo #(
        .DATA_W    (NOC_DATA_W),
        .USER_W    (NOC_USER_W),
        .FIFO_DEPTH(D2S_FIFO_DEPTH)
    ) u_d2s_fifo (
        .clk    (clk),
        .rst_n  (rst_n),
        .in_d2s (d2s_in.sparse),
        .out_d2s(d2s_out.dense)
    );
    assign d2s_data_o      = d2s_out.data;
    assign d2s_user_o      = d2s_out.user;
    assign d2s_valid_o     = d2s_out.valid;
    assign d2s_out.ready   = d2s_ready_i;
    assign d2s_last_o      = d2s_out.last;
    assign d2s_out.almost_full = d2s_almost_full_i;
    tlmm_acc_vec_t sparse_result_acc_w;
    logic          sparse_result_valid_w;

    tlmm_driver #(
        .PP_DATA_W(PP_CASCADE_W)
    ) u_tlmm_driver (
        .clk         (clk),
        .rst_n       (rst_n),
        .base_addr   (tlmm_base_addr),
        .tlmm        (tlmm_bus.drv),
        .pp          (sparse_pp_cascade.core),
        .ctrl        (tlmm_ctrl.driver),
        .result_acc  (sparse_result_acc_w),
        .result_valid(sparse_result_valid_w)
    );

    sparse_tile u_sparse_tile (
        .clk   (clk),
        .rst_n (rst_n),
        .ctrl  (tlmm_ctrl.tile)
    );

    sparse_out_collector #(
        .WR_DATA_W(URAM_WIDTH_BITS)
    ) u_sparse_collector (
        .clk         (clk),
        .rst_n       (rst_n),
        .result_valid(sparse_result_valid_w),
        .result_acc  (sparse_result_acc_w),
        .wr_base_addr(sparse_out_base_addr),
        .wr_en       (sparse_out_wr_en),
        .wr_addr     (sparse_out_wr_addr),
        .wr_data     (sparse_out_wr_data),
        .busy_o      ()
    );
    assign dram_req_addr      = dram_bus.req_addr;
    assign dram_req_len       = dram_bus.req_len;
    assign dram_req_valid     = dram_bus.req_valid;
    assign dram_bus.req_ready = dram_req_ready;
    assign dram_bus.rsp_data  = dram_rsp_data;
    assign dram_bus.rsp_valid = dram_rsp_valid;
    assign dram_bus.rsp_last  = dram_rsp_last;
    assign dram_rsp_ready     = dram_bus.rsp_ready;

    assign dram_wr_req_addr      = dram_wr_bus.req_addr;
    assign dram_wr_req_len       = dram_wr_bus.req_len;
    assign dram_wr_req_valid     = dram_wr_bus.req_valid;
    assign dram_wr_bus.req_ready = dram_wr_req_ready;
    assign dram_wr_wd_data       = dram_wr_bus.wd_data;
    assign dram_wr_wd_valid      = dram_wr_bus.wd_valid;
    assign dram_wr_wd_last       = dram_wr_bus.wd_last;
    assign dram_wr_bus.wd_ready  = dram_wr_wd_ready;

endmodule : archbetter_top

`default_nettype wire
`endif
