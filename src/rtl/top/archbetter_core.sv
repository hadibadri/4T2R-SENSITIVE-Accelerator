// -----------------------------------------------------------------------------
// archbetter_core.sv  (Phase-8, Stage 8e — closed SoC top)
//
// The CLOSED-LOOP sibling of archbetter_top. Where archbetter_top is the open
// Phase-7 harness (host drives the per-tile weight scan and tile schedule, and
// the GEMM it issues is a single OP_GEMM_ALL tile), archbetter_core lets the
// DISPATCHER orchestrate a full DENSE_LOGICAL_TILE_ROWS x DENSE_LOGICAL_TILE_COLS
// layer via a single OP_GEMM_LAYER macro-instruction, with NO per-beat host
// poking. This is the design whose synthesis power/utilization is real (the
// open harness pruned the dangling host scan port + dead-ended sub-cores; see
// project memory "OOC harness prunes phantom power/util").
//
// What changed vs archbetter_top
// ------------------------------
//   REMOVED host ports : w_we / w_gr / w_gc / w_pe_addr / w_in (weight scan),
//                        tile_gr / tile_gc / tile_first / tile_last (schedule).
//   ADDED   config port : dense_weight_base_addr (the 32-tile weight image base
//                        in the dense URAM; the weight streamer reads from here).
//   INTERNALIZED        :
//     * dense_weight_streamer drives the array scan bus (sched_bus.streamer),
//       reading per-tile weights from the dense URAM ping-pong.
//     * the dispatcher tile-walker drives the array tile schedule
//       (sched_bus.walker: tile_gr/tile_gc/tile_first/tile_last) for
//       OP_GEMM_LAYER, sequencing weight-load -> single-tile GEMM per tile.
//     * the single dense URAM read port is MUXED between the weight streamer
//       (during a per-tile weight load, sched.load_busy=1) and the activation
//       streamer (during the tile's GEMM stream). They are temporally exclusive
//       by the walker's WLOAD -> GEMM_ACC sequencing.
//     * the per-tile activation BAND is selected by an address computation:
//         act_base = dense_act_base_addr + tile_gr * (k_cnt * 2)
//       Each logical row-tile gr consumes the gr-th 16-element activation band;
//       tile_gc does not change the activation (the array bank accumulates the
//       gr walk into the tile_gc output strip — see dense_array sec 5).
//
// What stayed identical to archbetter_top
// ----------------------------------------
//   memory_manager + cascade adapters + CSD/URAM, NoC fabric + row-tile mux,
//   dense_out_collector (-> OUT URAM), sparse path (tlmm_driver + sparse_tile +
//   sparse_out_collector -> boundary), dense2sparse FIFO, KV, DRAM masters.
//
// Quality bar: zero magic numbers, every modport bound once, no latches/async
// reset, cascade adapter owns the 72b<->144b stitch.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_CORE_SV
`define ARCHBETTER_CORE_SV
`default_nettype none

module archbetter_core
    import types_pkg::*;
#(
    parameter int unsigned IMEM_DEPTH    = 64,
    parameter int unsigned IMEM_ADDR_W   = $clog2(IMEM_DEPTH),
    parameter int unsigned N_NOC_SOURCES = 1,
    // C1.5: dense per-token accumulator-bank depth (max tokens per OP_GEMM_BATCH).
    // 1 = decode-only (back-compat). The bank costs BATCH_T*128*44 FFs at v1.
    parameter int unsigned BATCH_T       = 1,
    parameter int unsigned PP_NATIVE_W   = URAM_WIDTH_BITS,         // 72
    parameter int unsigned PP_CASCADE_W  = 2 * URAM_WIDTH_BITS,     // 144
    parameter int unsigned D2S_FIFO_DEPTH = 64
) (
    input  wire logic clk,
    input  wire logic rst_n,

    // ---- Host control --------------------------------------------------------
    input  wire logic                          start,
    output logic                               program_done,

    // ---- Instruction memory write port --------------------------------------
    input  wire logic                          imem_we,
    input  wire logic [IMEM_ADDR_W-1:0]        imem_wr_addr,
    input  wire logic [MACRO_WORD_W-1:0]       imem_wr_data,

    // ---- CSD descriptor table write port ------------------------------------
    input  wire logic                          desc_we,
    input  wire logic [7:0]                    desc_wr_addr,
    input  wire csd_descriptor_t               desc_wr_data,

    // ---- Layer descriptor: URAM base addresses (host computes pre-run) -------
    // Dense URAM weight image base (dense_weight_streamer reads per-tile from
    // here; tile (gr,gc) occupies WORDS_PER_TILE cascaded words at
    // base + (gr*DENSE_LOGICAL_TILE_COLS + gc)*WORDS_PER_TILE).
    input  wire logic [URAM_ADDR_W-1:0]        dense_weight_base_addr,
    // Dense URAM activation image base. Row-band gr lives at
    // base + gr*(k_cnt*2) cascaded words (k_cnt beats * 2 cascaded words/beat).
    input  wire logic [URAM_ADDR_W-1:0]        dense_act_base_addr,
    // Sparse URAM PROG+weight base for the TLMM driver.
    input  wire logic [URAM_ADDR_W-1:0]        tlmm_base_addr,
    // Dense collector OUTPUT URAM base (OP_ST_OUT descriptor uram_base matches).
    input  wire logic [URAM_ADDR_W-1:0]        out_collector_base_addr,
    // Sparse collector OUTPUT URAM base (boundary write port).
    input  wire logic [URAM_ADDR_W-1:0]        sparse_out_base_addr,

    // ---- KV write-data sideband + read-return observability -----------------
    input  wire logic [KV_DATA_W-1:0]          kv_wr_data_i,
    output logic [KV_DATA_W-1:0]               kv_rd_data_o,
    output logic                               kv_rd_valid_o,

    // ---- Dense-array snap observability -------------------------------------
    output array_acc_t [DENSE_ARRAY_COLS-1:0]  y_out,
    output logic                               y_valid,

    // ---- Sparse output collector write port (boundary observability) --------
    output logic                               sparse_out_wr_en,
    output logic [URAM_ADDR_W-1:0]             sparse_out_wr_addr,
    output logic [URAM_WIDTH_BITS-1:0]         sparse_out_wr_data,

    // ---- Dense->Sparse FIFO consumer-side stream (boundary exposure) -------
    output logic [NOC_DATA_W-1:0]              d2s_data_o,
    output logic [NOC_USER_W-1:0]              d2s_user_o,
    output logic                               d2s_valid_o,
    input  wire logic                          d2s_ready_i,
    output logic                               d2s_last_o,
    input  wire logic                          d2s_almost_full_i,

    // ---- DRAM read master (csd_dram_if) -------------------------------------
    output logic [DRAM_ADDR_W-1:0]             dram_req_addr,
    output logic [DRAM_LEN_W-1:0]              dram_req_len,
    output logic                               dram_req_valid,
    input  wire logic                          dram_req_ready,
    input  wire logic [DRAM_BEAT_W-1:0]        dram_rsp_data,
    input  wire logic                          dram_rsp_valid,
    output logic                               dram_rsp_ready,
    input  wire logic                          dram_rsp_last,

    // ---- DRAM write master (csd_dram_wr_if) ---------------------------------
    output logic [DRAM_ADDR_W-1:0]             dram_wr_req_addr,
    output logic [DRAM_LEN_W-1:0]              dram_wr_req_len,
    output logic                               dram_wr_req_valid,
    input  wire logic                          dram_wr_req_ready,
    output logic [DRAM_BEAT_W-1:0]             dram_wr_wd_data,
    output logic                               dram_wr_wd_valid,
    input  wire logic                          dram_wr_wd_ready,
    output logic                               dram_wr_wd_last
);

    // -------------------------------------------------------------------------
    // Elaboration sanity.
    // -------------------------------------------------------------------------
    initial begin : core_elab_checks
        if (N_NOC_SOURCES != 1) begin
            $fatal(1, "archbetter_core: N_NOC_SOURCES=%0d unsupported (single-source)",
                   N_NOC_SOURCES);
        end
        if (PP_NATIVE_W != URAM_WIDTH_BITS) begin
            $fatal(1, "archbetter_core: PP_NATIVE_W=%0d != URAM_WIDTH_BITS=%0d",
                   PP_NATIVE_W, URAM_WIDTH_BITS);
        end
        if (PP_CASCADE_W != 2 * URAM_WIDTH_BITS) begin
            $fatal(1, "archbetter_core: PP_CASCADE_W=%0d != 2*URAM_WIDTH_BITS=%0d",
                   PP_CASCADE_W, 2 * URAM_WIDTH_BITS);
        end
    end

    // =========================================================================
    // Internal interfaces
    // =========================================================================
    noc_cfg_if cfg_bus [N_NOC_SOURCES] (.clk(clk), .rst_n(rst_n));

    strm_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W))
        src      [N_NOC_SOURCES] (.clk(clk), .rst_n(rst_n));
    strm_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W))
        noc_dst  [NOC_NODES]     (.clk(clk), .rst_n(rst_n));
    strm_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W))
        a_strm (.clk(clk), .rst_n(rst_n));

    gemm_issue_if  gemm_bus  (.clk(clk), .rst_n(rst_n));
    tlmm_issue_if  tlmm_bus  (.clk(clk), .rst_n(rst_n));
    tlmm_ctrl_if   tlmm_ctrl (.clk(clk), .rst_n(rst_n));

    // Phase-8 tile-schedule bus: dispatcher walker + dense weight streamer.
    dense_sched_if sched_bus (.clk(clk), .rst_n(rst_n));

    mem_issue_if   mem_bus   (.clk(clk), .rst_n(rst_n));
    kv_access_if   kv_bus    (.clk(clk), .rst_n(rst_n));

    // R6.8b: Dense is a WIDE pingpong (DENSE_PP_URAM_W = 288 b = 4 native leaves)
    // that memory_manager drives DIRECTLY — no cascade adapter. Its .core read
    // port is MUXED below between the weight streamer and the act streamer, both
    // of which now read a whole block (II=1).
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(DENSE_PP_URAM_W)) dense_pp_wide
        (.clk(clk), .rst_n(rst_n));

    // Sparse keeps the native pingpong + cascade adapter (TLMM reads 144b cascade).
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_NATIVE_W)) sparse_pp_native
        (.clk(clk), .rst_n(rst_n));
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_CASCADE_W)) sparse_pp_cascade
        (.clk(clk), .rst_n(rst_n));

    // Per-streamer WIDE ping-pong views (consumer side). The mux below routes
    // exactly one of these onto dense_pp_wide's read port.
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(DENSE_PP_URAM_W)) wt_pp
        (.clk(clk), .rst_n(rst_n));
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(DENSE_PP_URAM_W)) act_pp
        (.clk(clk), .rst_n(rst_n));

    dense2sparse_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W), .FIFO_DEPTH(D2S_FIFO_DEPTH))
        d2s_in  (.clk(clk), .rst_n(rst_n));
    dense2sparse_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W), .FIFO_DEPTH(D2S_FIFO_DEPTH))
        d2s_out (.clk(clk), .rst_n(rst_n));

    csd_dram_if    dram_bus    (.clk(clk), .rst_n(rst_n));
    csd_dram_wr_if dram_wr_bus (.clk(clk), .rst_n(rst_n));

    logic [NOC_PATH_ID_W-1:0] path_id [N_NOC_SOURCES];

    // =========================================================================
    // Dispatcher (now also drives the tile-walker on sched_bus.walker)
    // =========================================================================
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
        // Layer+drain (array) OR per-snap collector busy: stays high for the
        // whole batched drain so the barrier can't slip through mid-batch.
        .dense_drain_busy (array_drain_active_w || collector_busy_w)
    );

    assign kv_rd_data_o  = kv_bus.rd_data;
    assign kv_rd_valid_o = kv_bus.rd_valid;

    // =========================================================================
    // OUTPUT URAM write port: driven internally by dense_out_collector.
    // =========================================================================
    logic                        collector_busy_w;  // dense collector drain back-pressure
    logic                        array_drain_active_w; // dense layer+drain in flight
    logic                        out_wr_en_w;
    logic [URAM_ADDR_W-1:0]      out_wr_addr_w;
    logic [URAM_WIDTH_BITS-1:0]  out_wr_data_w;

    // =========================================================================
    // Memory Manager (native-width pingpongs)
    // =========================================================================
    memory_manager #(
        .DESC_DEPTH (256)
    ) u_memmgr (
        .clk          (clk),
        .rst_n        (rst_n),
        .issue        (mem_bus.mgr),
        .kv           (kv_bus.slave),
        .dense_pp     (dense_pp_wide.mem_mgr),
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

    // =========================================================================
    // Cascade adapter (SPARSE only): 72b native -> 144b cascaded. The dense path
    // is now a direct WIDE read (no adapter) — see dense_pp_wide above (R6.8b).
    // =========================================================================
    uram_cascade_adapter #(
        .UP_DATA_W(PP_NATIVE_W), .DN_DATA_W(PP_CASCADE_W),
        .UP_ADDR_W(URAM_ADDR_W), .DN_ADDR_W(URAM_ADDR_W)
    ) u_sparse_cascade (
        .clk(clk), .rst_n(rst_n),
        .up (sparse_pp_native.core),
        .dn (sparse_pp_cascade.mem_mgr)
    );

    // =========================================================================
    // Dense URAM read-port MUX (weight streamer vs activation streamer)
    //
    // sched_bus.load_busy is high exactly during a per-tile weight load (the
    // dispatcher's S_LAYER_WLOAD). During that window the weight streamer owns
    // the read port; otherwise the activation streamer owns it. The two are
    // temporally exclusive (weights load, then activations stream), and the
    // weight streamer pulses load_done only after its final scan write — so no
    // read is in flight across the switch boundary.
    //
    // dense_pp_wide core-side (rd_en/rd_addr/drain_ack) is driven here; its
    // mem_mgr-side responses (active_side/side_valid/rd_data/rd_valid/drain_req)
    // are fanned to both streamer views, gated so the INACTIVE streamer sees a
    // quiescent port (its internal handshake assertions stay satisfied).
    // =========================================================================
    logic dense_rd_sel_wt;
    assign dense_rd_sel_wt = sched_bus.load_busy;

    always_comb begin
        // Core-side: route the active streamer's commands to the real port.
        dense_pp_wide.rd_en     = dense_rd_sel_wt ? wt_pp.rd_en     : act_pp.rd_en;
        dense_pp_wide.rd_addr   = dense_rd_sel_wt ? wt_pp.rd_addr   : act_pp.rd_addr;
        dense_pp_wide.drain_ack = dense_rd_sel_wt ? wt_pp.drain_ack : act_pp.drain_ack;

        // mem_mgr-side responses fanned to both views.
        wt_pp.active_side  = dense_pp_wide.active_side;
        act_pp.active_side = dense_pp_wide.active_side;
        wt_pp.rd_data      = dense_pp_wide.rd_data;
        act_pp.rd_data     = dense_pp_wide.rd_data;

        // Gate side_valid / rd_valid / drain_req to the active view only.
        wt_pp.side_valid  =  dense_rd_sel_wt && dense_pp_wide.side_valid;
        act_pp.side_valid = !dense_rd_sel_wt && dense_pp_wide.side_valid;
        wt_pp.rd_valid    =  dense_rd_sel_wt && dense_pp_wide.rd_valid;
        act_pp.rd_valid   = !dense_rd_sel_wt && dense_pp_wide.rd_valid;
        wt_pp.drain_req   =  dense_rd_sel_wt && dense_pp_wide.drain_req;
        act_pp.drain_req  = !dense_rd_sel_wt && dense_pp_wide.drain_req;
    end

    // =========================================================================
    // Dense weight streamer: per-tile URAM -> PE scan over sched_bus.streamer.
    // =========================================================================
    dense_weight_streamer #(
        .PP_DATA_W(DENSE_PP_URAM_W)
    ) u_weight_streamer (
        .clk      (clk),
        .rst_n    (rst_n),
        .base_addr(dense_weight_base_addr),
        .sched    (sched_bus.streamer),
        .pp       (wt_pp.core)
    );

    // =========================================================================
    // Per-tile activation band base.
    //   act_base = dense_act_base_addr + tile_gr * (k_cnt * 2)
    // tile_gr (walker) and k_cnt (gemm bus) are both stable during the tile's
    // GEMM stream, so the act streamer reads the gr-th band coherently.
    // =========================================================================
    logic [URAM_ADDR_W-1:0] act_base_c;
    always_comb begin
        act_base_c = URAM_ADDR_W'(dense_act_base_addr
                   + URAM_ADDR_W'(sched_bus.tile_gr)
                     * (URAM_ADDR_W'(gemm_bus.k_cnt) << 1));
    end

    // =========================================================================
    // NoC fabric (1 source, NOC_NODES destinations) + row-tile mux.
    // =========================================================================
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

    // Row-band selected by the walker's tile_gr.
    assign a_strm.data  = dst_data_unbund [sched_bus.tile_gr];
    assign a_strm.user  = dst_user_unbund [sched_bus.tile_gr];
    assign a_strm.valid = dst_valid_unbund[sched_bus.tile_gr];
    assign a_strm.last  = dst_last_unbund [sched_bus.tile_gr];

    for (genvar G = 0; G < int'(DENSE_LOGICAL_TILE_ROWS); G++) begin : gen_dst_row_tile_ready
        assign noc_dst[G].ready = (sched_bus.tile_gr == ($clog2(DENSE_LOGICAL_TILE_ROWS))'(G))
                                  ? a_strm.ready : 1'b1;
    end : gen_dst_row_tile_ready

    for (genvar D = int'(DENSE_LOGICAL_TILE_ROWS); D < int'(NOC_NODES); D++)
    begin : gen_dst_unused_tieoff
        assign noc_dst[D].ready = 1'b1;
    end : gen_dst_unused_tieoff

    // =========================================================================
    // Dense activation streamer (drives gemm_bus.drv + src[0]); per-tile base.
    // =========================================================================
    // R6.5 CONTINUOUS per-token stride: consecutive tokens' same-band (gr) 192b
    // blocks are one full token vector apart = (#bands) * (2 words/band). #bands =
    // DENSE_LOGICAL_TILE_ROWS (8), so 16 words. act_base_c already carries the gr
    // band offset (gr*2 when k_cnt=1, the continuous case), so the streamer just
    // adds tok*ACT_TOKEN_STRIDE. PER_TOKEN ignores token_stride.
    localparam int unsigned ACT_TOKEN_STRIDE =
        int'(DENSE_LOGICAL_TILE_ROWS) * 2;   // 8 bands * 2 words = 16

    dense_act_streamer #(
        .PP_DATA_W(DENSE_PP_URAM_W)
    ) u_streamer (
        .clk         (clk),
        .rst_n       (rst_n),
        .base_addr   (act_base_c),
        .token_stride(URAM_ADDR_W'(ACT_TOKEN_STRIDE)),
        .gemm        (gemm_bus.drv),
        .pp          (act_pp.core),
        .src         (src[0])
    );

    // =========================================================================
    // Dense Core: dense_array driven by sched_bus (tile schedule + weight scan)
    // and gemm_bus (acc pulses).
    // =========================================================================
    array_acc_t [DENSE_ARRAY_COLS-1:0] y_out_w;
    logic                              y_valid_w;

    dense_array #(
        .ENABLE_NOISE_HOOKS (1'b0),
        .ARRAY_ID           (32'd0),
        .BATCH_T            (BATCH_T)
    ) u_array (
        .clk        (clk),
        .rst_n      (rst_n),
        .a_strm     (a_strm),
        .tile_gr    (sched_bus.tile_gr),
        .tile_gc    (sched_bus.tile_gc),
        .tile_tok   (sched_bus.tile_tok),
        .batch_n    (sched_bus.batch_n),
        .drain_busy (collector_busy_w),
        .tile_first (sched_bus.tile_first),
        .tile_last  (sched_bus.tile_last),
        .acc_clr    (gemm_bus.acc_clr),
        .acc_snap   (gemm_bus.acc_snap),
        // R6.4: the array snap mode is now driven by the dispatcher (PER_TOKEN for
        // v1 ops, CONTINUOUS for OP_GEMM_BATCH with FLG_GEMM_CONTINUOUS set).
        .stream_mode (sched_bus.stream_mode),
        .w_we       (sched_bus.w_we),
        .w_phys_gc  (sched_bus.w_phys_gc),
        .w_pe_addr  (sched_bus.w_pe_addr),
        .w_in       (sched_bus.w_in),
        .y_out      (y_out_w),
        .y_valid    (y_valid_w),
        .drain_active(array_drain_active_w)
    );

    assign y_out   = y_out_w;
    assign y_valid = y_valid_w;

    // =========================================================================
    // Dense output collector: drains y_out into OUT URAM and the d2s producer.
    // =========================================================================
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
        .busy_o       (collector_busy_w)
    );

    // =========================================================================
    // Dense->Sparse FIFO: producer side from collector, consumer at boundary.
    // =========================================================================
    dense2sparse_fifo #(
        .DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W), .FIFO_DEPTH(D2S_FIFO_DEPTH)
    ) u_d2s_fifo (
        .clk    (clk),
        .rst_n  (rst_n),
        .in_d2s (d2s_in.sparse),
        .out_d2s(d2s_out.dense)
    );

    assign d2s_data_o          = d2s_out.data;
    assign d2s_user_o          = d2s_out.user;
    assign d2s_valid_o         = d2s_out.valid;
    assign d2s_out.ready       = d2s_ready_i;
    assign d2s_last_o          = d2s_out.last;
    assign d2s_out.almost_full = d2s_almost_full_i;

    // =========================================================================
    // Sparse Core: tlmm_driver -> sparse_tile, result -> sparse_out_collector.
    // =========================================================================
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
        .busy_o      (/* unused */)
    );

    // =========================================================================
    // DRAM master fanout to top-level pins
    // =========================================================================
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

endmodule : archbetter_core

`default_nettype wire
`endif // ARCHBETTER_CORE_SV
