// -----------------------------------------------------------------------------
// archbetter_top.sv
//
// Phase-7 SoC top of the ArchBetter edge-LLM accelerator.
//
// Compared to the Phase-6 thin SoC, this revision composes the full set of
// in-fabric bridges:
//
//   * dense_act_streamer  -> reads activation tiles from the dense ping-pong
//                            (via uram_cascade_adapter) and drives NoC src[0]
//                            and the gemm_issue_if drv side.
//   * tlmm_driver         -> reads PROG / weight tiles from the sparse
//                            ping-pong (via uram_cascade_adapter) and drives
//                            the sparse_tile through tlmm_ctrl_if.
//   * dense_out_collector -> snapshots the dense_array's per-snap output,
//                            writes it into memory_manager's OUTPUT URAM via
//                            the on-chip out_wr_* port, and forwards a BFP12
//                            requantized stream to dense2sparse_fifo.
//   * dense2sparse_fifo   -> FIFO bridge whose .dense producer side is wired
//                            internally; its .sparse consumer side is exposed
//                            at the SoC boundary for future TLMM ingestion or
//                            for instrumentation.
//   * uram_cascade_adapter -> 72b native -> 144b cascaded view, slotted between
//                             memory_manager.dense_pp/sparse_pp and the
//                             streamer/driver consumers.
//
// Boundary surfaces that disappear (compared to Phase 6):
//   * gemm_*               (streamer drives gemm_bus.drv)
//   * tlmm_start/k_cnt/...  (driver drives tlmm_bus.drv)
//   * tlmm_prog_*/w_*/o_*   (driver owns tlmm_ctrl_if)
//   * out_wr_*              (collector owns the OUT URAM write port)
//   * src0_*                (streamer drives NoC src[0])
//
// Boundary surfaces that survive:
//   * Host control: start, program_done
//   * imem write port for the macro program
//   * descriptor table write port (csd_descriptor_t indexed by tile_id)
//   * dense weight scan port (pre-loads the 128 x 128 PE register file)
//   * KV write-data sideband + read-return observability (host-driven during
//     OP_KV_WRITE, observable during OP_KV_READ)
//   * Dense-array snap observability (y_out, y_valid)
//   * dense_act_streamer / tlmm_driver / dense_out_collector base-addr inputs
//     (the host computes these from the descriptor it loaded; no hierarchical
//     descriptor->bridge plumbing yet)
//   * dense2sparse_fifo .sparse-side consumer port (data, user, valid, ready,
//     last, almost_full) -- exposes the BFP12-forwarded FFN activation stream
//     so a future TLMM ingest path or off-fabric monitor can sink it.
//   * DRAM read master (csd_dram_if) and write master (csd_dram_wr_if) for
//     fills and OP_ST_OUT drains.
//
// Quality bar
//   * Zero magic numbers. Every width comes from types_pkg.
//   * Every interface modport is bound exactly once in the parent direction.
//   * No combinational loops, no latches, no async resets.
//   * Cascade adapter handles the 72b<->144b stitching; memory_manager and
//     uram_pingpong are unchanged.
// -----------------------------------------------------------------------------
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
    // Native (memory_manager-side) and cascaded (streamer/driver-side) widths.
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

    // ---- Dense weight scan port (load the 128 x 128 weight plane) -----------
    // Phase-7d note: the dense array is now PHYSICALLY 16x32 (two phys groups,
    // CLAUDE.md sec 2.2). w_gr / w_gc carry the LOGICAL tile coordinates the
    // host is currently scanning into; w_gc[0] is repurposed inside the top
    // as w_phys_gc (which of the 2 phys groups), w_gr[2:0] and w_gc[2:1] are
    // for the host's bookkeeping and reach the dense_array via tile_gr /
    // tile_gc below. Phase 8 will move this orchestration into the dispatcher.
    input  wire logic                                      w_we,
    input  wire logic [$clog2(DENSE_GROUPS_ROW)-1:0]       w_gr,
    input  wire logic [$clog2(DENSE_GROUPS_COL)-1:0]       w_gc,
    input  wire logic [$clog2(DENSE_PE_PER_GROUP)-1:0]     w_pe_addr,
    input  wire bfp12_mant_t                               w_in,

    // ---- Tile schedule (Phase-7d: host-driven; Phase-8: dispatcher-driven) --
    // tile_gr  : which logical row-tile of the 128-row activation vector is
    //            currently being streamed into the dense array (0..7).
    // tile_gc  : which logical column-tile (32 cols wide) is currently being
    //            computed (0..3).
    // tile_first: pulse before the first acc_clr of a layer; clears the
    //            128-wide array_acc_t bank.
    // tile_last : pulse concurrent with the FINAL acc_snap of a layer;
    //            triggers the y_out drain + y_valid pulse.
    input  wire logic [$clog2(DENSE_LOGICAL_TILE_ROWS)-1:0] tile_gr,
    input  wire logic [$clog2(DENSE_LOGICAL_TILE_COLS)-1:0] tile_gc,
    input  wire logic                                       tile_first,
    input  wire logic                                       tile_last,

    // ---- Per-bridge base-address inputs (host computes from descriptors) ----
    // dense_act_streamer reads activations from dense URAM starting here.
    input  wire logic [URAM_ADDR_W-1:0]        dense_act_base_addr,
    // tlmm_driver reads PROG + weight tiles from sparse URAM starting here.
    input  wire logic [URAM_ADDR_W-1:0]        tlmm_base_addr,
    // dense_out_collector writes its per-snap output starting here in the
    // OUTPUT URAM. The OP_ST_OUT descriptor's uram_base must match.
    input  wire logic [URAM_ADDR_W-1:0]        out_collector_base_addr,
    // sparse_out_collector writes the TLMM per-lane K-reduction vector starting
    // here. Distinct region from the dense collector's; the host owns the map.
    input  wire logic [URAM_ADDR_W-1:0]        sparse_out_base_addr,

    // ---- KV write-data sideband + read-return observability -----------------
    input  wire logic [KV_DATA_W-1:0]          kv_wr_data_i,
    output logic [KV_DATA_W-1:0]               kv_rd_data_o,
    output logic                               kv_rd_valid_o,

    // ---- Dense-array snap observability -------------------------------------
    output array_acc_t [DENSE_ARRAY_COLS-1:0]  y_out,
    output logic                               y_valid,

    // ---- Sparse output collector write port (boundary observability) --------
    // The sparse core's TLMM result now drains through sparse_out_collector to
    // this OUTPUT URAM write port. Exposing it at the boundary makes the sparse
    // datapath a live, observable endpoint (it no longer dead-ends, so OOC
    // synthesis cannot prune it). A future closed top (archbetter_core) will
    // route this into a dedicated OUTPUT URAM region instead of the boundary.
    output logic                               sparse_out_wr_en,
    output logic [URAM_ADDR_W-1:0]             sparse_out_wr_addr,
    output logic [URAM_WIDTH_BITS-1:0]         sparse_out_wr_data,

    // ---- Dense->Sparse FIFO consumer-side stream (boundary exposure) -------
    output logic [NOC_DATA_W-1:0]              d2s_data_o,
    output logic [NOC_USER_W-1:0]              d2s_user_o,
    output logic                               d2s_valid_o,
    input  wire logic                          d2s_ready_i,
    output logic                               d2s_last_o,
    input  wire logic                          d2s_almost_full_i, // ignored at sparse modport (input only)

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

    // =========================================================================
    // Internal interfaces
    // =========================================================================
    noc_cfg_if cfg_bus [N_NOC_SOURCES] (.clk(clk), .rst_n(rst_n));

    strm_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W))
        src      [N_NOC_SOURCES] (.clk(clk), .rst_n(rst_n));
    strm_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W))
        noc_dst  [NOC_NODES]     (.clk(clk), .rst_n(rst_n));
    // Single 16-mantissa activation stream into the time-multiplexed dense_array.
    // Phase-7d refactor: the array consumes only ONE row-tile's activations at a
    // time (selected by tile_gr). The 8 NoC drops noc_dst[0..7] are muxed below.
    strm_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W))
        a_strm (.clk(clk), .rst_n(rst_n));

    gemm_issue_if gemm_bus (.clk(clk), .rst_n(rst_n));
    tlmm_issue_if tlmm_bus (.clk(clk), .rst_n(rst_n));
    tlmm_ctrl_if  tlmm_ctrl (.clk(clk), .rst_n(rst_n));

    // Phase-8 dense_sched_if: dispatcher tile-walker -> (future) dense weight
    // streamer + dense_array. The closed top (Stage 8e) will instantiate the
    // weight streamer on the .streamer side and re-point the array's tile_* /
    // scan ports here. Until then this bus exists so the dispatcher elaborates;
    // the streamer side is tied off and the array keeps taking its tile schedule
    // from the host ports. The only GEMM this top issues is OP_GEMM_ALL, which
    // leaves the walker idle.
    dense_sched_if sched_bus (.clk(clk), .rst_n(rst_n));
    assign sched_bus.load_done = 1'b0;
    assign sched_bus.w_we      = 1'b0;
    assign sched_bus.w_phys_gc = '0;
    assign sched_bus.w_pe_addr = '0;
    assign sched_bus.w_in      = '0;

    mem_issue_if  mem_bus  (.clk(clk), .rst_n(rst_n));
    kv_access_if  kv_bus   (.clk(clk), .rst_n(rst_n));

    // Native-width pingpongs that memory_manager owns.
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_NATIVE_W)) dense_pp_native
        (.clk(clk), .rst_n(rst_n));
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_NATIVE_W)) sparse_pp_native
        (.clk(clk), .rst_n(rst_n));

    // Cascaded-width pingpongs that the streamer/driver consume.
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_CASCADE_W)) dense_pp_cascade
        (.clk(clk), .rst_n(rst_n));
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_CASCADE_W)) sparse_pp_cascade
        (.clk(clk), .rst_n(rst_n));

    // Dense->Sparse forwarding pair: producer side wired to dense_out_collector,
    // consumer side wired to a SoC boundary stream.
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

    // =========================================================================
    // path_id router (1 source, currently driven from the dispatcher)
    // =========================================================================
    logic [NOC_PATH_ID_W-1:0] path_id [N_NOC_SOURCES];

    // =========================================================================
    // Dispatcher
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
        .dense_drain_busy (1'b0)
    );

    assign kv_rd_data_o  = kv_bus.rd_data;
    assign kv_rd_valid_o = kv_bus.rd_valid;

    // =========================================================================
    // OUTPUT URAM write port: now driven internally by dense_out_collector.
    // =========================================================================
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

    // =========================================================================
    // Cascade adapters: 72b native -> 144b cascaded.
    // =========================================================================
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

    // =========================================================================
    // NoC fabric (1 source, 64 destinations)
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

    // Phase-7d row-tile mux: of the 8 row-tile NoC drops noc_dst[0..7], only
    // the one selected by tile_gr is forwarded to the dense_array's single
    // activation stream. The other 7 are sunk by always-ready stubs (the NoC
    // never produces beats on un-selected drops by circuit-switched contract,
    // but the always-ready ties prevent dangling-ready elaboration warnings).
    // dst[8..63] continue to be unused-but-ready as before.
    //
    // Interface arrays cannot be indexed by a runtime variable in SV, so the
    // signals are unbundled into plain logic arrays via a constant-genvar
    // generate, then those plain arrays are muxed by tile_gr.
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

    // =========================================================================
    // Dense activation streamer (drives gemm_bus.drv + src[0])
    // =========================================================================
    dense_act_streamer #(
        .PP_DATA_W(PP_CASCADE_W)
    ) u_streamer (
        .clk      (clk),
        .rst_n    (rst_n),
        .base_addr(dense_act_base_addr),
        // R6.5: legacy harness runs the v1 (PER_TOKEN) path, which ignores
        // token_stride; tie to the single-block stride.
        .token_stride(URAM_ADDR_W'(2)),
        .gemm     (gemm_bus.drv),
        .pp       (dense_pp_cascade.core),
        .src      (src[0])
    );

    // =========================================================================
    // Dense Core: dense_array (driven by NoC dst[0..7], control from gemm_bus)
    // =========================================================================
    array_acc_t [DENSE_ARRAY_COLS-1:0] y_out_w;
    logic                              y_valid_w;

    // Phase-7d translation of the legacy w_gr / w_gc port semantics:
    //   * w_phys_gc = w_gc[0]   (low bit picks 1 of 2 physical column groups)
    //   * tile_gr / tile_gc / tile_first / tile_last are top-level inputs,
    //     driven by the host now, by the dispatcher's tile-walker in Phase 8.
    // The remaining w_gr[2:0] / w_gc[2:1] bits are not consumed inside the
    // dense_array; the host scans only the CURRENT tile's weights into the
    // 2 physical groups, then changes tile_gr / tile_gc and rescans.
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
        .tile_tok   (BATCH_TOK_W'(0)),   // open harness is single-tile/decode
        .batch_n    (BATCH_TOK_W'(1)),
        .drain_busy (1'b0),
        .tile_first (tile_first),
        .tile_last  (tile_last),
        .acc_clr    (gemm_bus.acc_clr),
        .acc_snap   (gemm_bus.acc_snap),
        .stream_mode (GEMM_SNAP_PER_TOKEN),   // R6.3: legacy harness runs v1 path
        .w_we       (w_we),
        .w_phys_gc  (w_phys_gc),
        .w_pe_addr  (w_pe_addr),
        .w_in       (w_in),
        .y_out      (y_out_w),
        .y_valid    (y_valid_w)
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
        .busy_o       (/* unused */)
    );

    // =========================================================================
    // Dense->Sparse FIFO: producer side from collector, consumer at boundary.
    // =========================================================================
    dense2sparse_fifo #(
        .DATA_W    (NOC_DATA_W),
        .USER_W    (NOC_USER_W),
        .FIFO_DEPTH(D2S_FIFO_DEPTH)
    ) u_d2s_fifo (
        .clk    (clk),
        .rst_n  (rst_n),
        .in_d2s (d2s_in.sparse),   // FIFO is the consumer of d2s_in
        .out_d2s(d2s_out.dense)    // FIFO is the producer of d2s_out
    );

    // d2s_out boundary exposure. d2s_out.sparse is the consumer side at the
    // boundary; the SoC user drives ready and reads data/user/valid/last.
    assign d2s_data_o      = d2s_out.data;
    assign d2s_user_o      = d2s_out.user;
    assign d2s_valid_o     = d2s_out.valid;
    assign d2s_out.ready   = d2s_ready_i;
    assign d2s_last_o      = d2s_out.last;
    // out_d2s.almost_full is an INPUT on the .dense modport (driven by the
    // consumer of d2s_out for back-pressure hint). The boundary is the
    // consumer here; tie to the supplied input.
    assign d2s_out.almost_full = d2s_almost_full_i;

    // =========================================================================
    // Sparse Core: tlmm_driver feeds sparse_tile through tlmm_ctrl_if, and the
    // driver's per-lane K-reduction result drains through sparse_out_collector
    // to the boundary OUTPUT URAM write port.
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

endmodule : archbetter_top

`default_nettype wire
`endif // ARCHBETTER_TOP_SV
