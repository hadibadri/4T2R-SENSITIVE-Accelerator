// -----------------------------------------------------------------------------
// tb_dispatcher_full.sv
//
// Layer-3 end-to-end testbench: a single macro program drives the dispatcher,
// which in turn coordinates the REAL memory_manager (CSD / pingpong / KV),
// the REAL noc_fabric (1 source, 64 dsts), the REAL dense_array (Phase-7d
// time-multiplexed 16x32 kernel), and the REAL sparse_tile (TLMM).
//
// Phase-7d note: the dispatcher's OP_GEMM is ONE logical tile's reduction, so
// the GEMM portion validates a SINGLE-TILE GEMM (tile 0,0): the TB plays host,
// holds tile_gr=tile_gc=0, pulses tile_first before the first acc_clr, and
// drives tile_last with acc_snap. The full 32-tile layer walk lives in
// tb_archbetter_top.
//
// Topology under test
// -------------------
//   imem (TB write)                     weight-scan port (TB write)
//        |                                          |
//        v                                          v
//   +-----------+  noc_cfg_if   +-----------+  +---------------+
//   |dispatcher |--------------->|noc_fabric|->|dense_array    |
//   |           |  path_id_o     |  1 src   |  | (a_strm[gr])  |
//   |           |--------------->|  64 dsts |  +---------------+
//   |           |  gemm_iss_if  +-----------+
//   |           |---busy/clr/snap/k_cnt---> TB-side activation streamer
//   |           |<--beat_fire------------- (= src[0] fire)
//   |           |  tlmm_iss_if
//   |           |---start/busy/k_cnt-----> TB TLMM driver
//   |           |<--done------------------ (after K_FFN OUT beats captured)
//   |           |  mem_issue_if
//   |           |<====mgr=====> memory_manager (real)
//   |           |  kv_access_if          |
//   |           |<====slave===> kv_bram inside memory_manager
//   +-----------+                        |
//                                  csd_dram_if
//                                        |
//                                   DRAM stub (TB)
//                                        +-- dense_pp.mem_mgr <-> TB drain ack
//                                        +-- sparse_pp.mem_mgr <-> TB drain ack
//
// Why the activation streamer + TLMM driver are still TB-side: there is no
// "URAM-to-NoC streamer" RTL in Phase 3 (the dispatcher only signals via
// gemm_issue_if, and dense_array consumes a_strm; the producer between URAM
// and NoC is a future module). Same story for sparse: there is no TLMM
// driver RTL yet. The TB plays these two roles, identically to the existing
// tb_dispatcher_compute.
//
// Program under test (single shot, all Layer-3 opcodes interleaved):
//   pc 0  OP_NOP
//   pc 1  OP_LD_W_URAM  tile_id=0  (dense pool fill via CSD)
//   pc 2  OP_LD_A_URAM  tile_id=1  is_sparse=1  (sparse pool fill via CSD)
//   pc 3  OP_PINGPONG   dense
//   pc 4  OP_PINGPONG   sparse  is_sparse=1
//   pc 5  OP_CFG_NOC    MASK_LO  handle=0
//   pc 6  OP_CFG_NOC    MASK_HI  handle=0
//   pc 7  OP_CFG_NOC    META     handle=0  src=0 prio=0 mc=1
//   pc 8  OP_BARRIER
//   pc 9  OP_COMMIT_NOC
//   pc10  OP_GEMM_ALL   path_id=0 k_cnt=K_GEMM
//   pc11  OP_BARRIER
//   pc12  OP_FFN_TLMM   k_cnt=K_FFN
//   pc13  OP_KV_WRITE   addr_0  data=kv_val_0
//   pc14  OP_KV_WRITE   addr_1  data=kv_val_1
//   pc15  OP_KV_WRITE   addr_2  data=kv_val_2
//   pc16  OP_KV_READ    addr_0
//   pc17  OP_KV_READ    addr_2
//   pc18  OP_KV_READ    addr_1
//   pc19  OP_ST_OUT     tile_id=0
//   pc20  OP_EOP
//
// Checks
//   GEMM     : dense_array y_out[128] matches SV golden (single tile 0,0: cols
//              0..31 = tile result, 32..127 = 0).
//   FFN      : sparse_tile o_parts sequence matches SV golden (K_FFN beats).
//   MEM_ISSUE: observed (opc, tile_id, is_sparse) sequence == expected.
//   KV       : observed write/read sequence matches; reads return mirror data.
//   Program  : program_done rises and stays high; no hangs.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_TB_DISPATCHER_FULL_SV
`define ARCHBETTER_TB_DISPATCHER_FULL_SV
`default_nettype none
`timescale 1ns/1ps

module tb_dispatcher_full
    import types_pkg::*;
();

    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------
    localparam time T_CLK       = 10ns;
    localparam int  N_SOURCES   = 1;
    localparam int  IMEM_DEPTH  = 64;
    localparam int  IMEM_ADDR_W = $clog2(IMEM_DEPTH);
    localparam int  DATA_W      = NOC_DATA_W;
    localparam int  USER_W      = NOC_USER_W;

    localparam int  ROWS        = DENSE_ARRAY_ROWS;
    localparam int  COLS        = DENSE_ARRAY_COLS;
    localparam int  GROWS       = DENSE_GROUPS_ROW;
    localparam int  GCOLS       = DENSE_GROUPS_COL;
    localparam int  GRS         = DENSE_GROUP_ROWS;
    localparam int  GCS         = DENSE_GROUP_COLS;
    localparam int  PE_ADDR_W   = $clog2(DENSE_PE_PER_GROUP);

    localparam int  K_GEMM      = 2;
    localparam int  K_FFN       = 3;

    // Memory test sizing. Beats per fill kept small so sim time stays bounded.
    localparam int          N_BEATS_SMALL    = 8;
    localparam int          URAM_DATA_W      = URAM_WIDTH_BITS;
    localparam int          URAM_AW          = URAM_ADDR_W;
    localparam logic [39:0] DRAM_PATTERN_HI  = 40'hCA_FEBA_BECA;

    // Multicast mask covers dst[0..7] = the eight dense_array group rows.
    localparam noc_mask_t TGT_MASK            = noc_mask_t'(64'h0000_0000_0000_00FF);
    localparam logic [31:0] TGT_MASK_LO       = TGT_MASK[31:0];
    localparam logic [31:0] TGT_MASK_HI       = TGT_MASK[63:32];
    localparam logic [5:0]  TGT_SRC_NODE      = 6'd0;
    localparam logic [2:0]  TGT_PRIORITY      = 3'd0;
    localparam logic        TGT_IS_MULTICAST  = 1'b1;
    localparam logic [NOC_PATH_ID_W-1:0] TGT_HANDLE = '0;

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    logic clk, rst_n;
    initial clk = 1'b0;
    always  #(T_CLK/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Interfaces
    // -------------------------------------------------------------------------
    noc_cfg_if cfg_bus [N_SOURCES] (.clk(clk), .rst_n(rst_n));

    strm_if #(.DATA_W(DATA_W), .USER_W(USER_W))
        src       [N_SOURCES] (.clk(clk), .rst_n(rst_n));
    strm_if #(.DATA_W(DATA_W), .USER_W(USER_W))
        noc_dst   [NOC_NODES] (.clk(clk), .rst_n(rst_n));
    // Phase-7d: time-multiplexed dense_array has a SINGLE activation stream;
    // noc_dst[0..7] are muxed by tile_gr below (mirrors archbetter_top).
    strm_if #(.DATA_W(DATA_W), .USER_W(USER_W))
        a_strm                (.clk(clk), .rst_n(rst_n));

    gemm_issue_if gemm_bus (.clk(clk), .rst_n(rst_n));
    tlmm_issue_if tlmm_bus (.clk(clk), .rst_n(rst_n));
    tlmm_ctrl_if  ctrl     (.clk(clk), .rst_n(rst_n));

    mem_issue_if  memif    (.clk(clk), .rst_n(rst_n));
    kv_access_if  kvif     (.clk(clk), .rst_n(rst_n));

    pingpong_if #(.ADDR_W(URAM_AW), .DATA_W(URAM_DATA_W)) dense_pp
        (.clk(clk), .rst_n(rst_n));
    pingpong_if #(.ADDR_W(URAM_AW), .DATA_W(URAM_DATA_W)) sparse_pp
        (.clk(clk), .rst_n(rst_n));
    csd_dram_if   dramif   (.clk(clk), .rst_n(rst_n));
    // DRAM write-back side (OP_ST_OUT drain). The memory_manager is master; the
    // TB plays the DRAM slave and always accepts so the drain completes.
    csd_dram_wr_if dram_wr_if (.clk(clk), .rst_n(rst_n));
    assign dram_wr_if.req_ready = 1'b1;
    assign dram_wr_if.wd_ready  = 1'b1;

    // OUTPUT-URAM write port. Normally driven by dense_out_collector; this TB
    // has no collector, so it is tied idle (no OUTPUT-URAM writes). OP_ST_OUT
    // still drains whatever the OUTPUT URAM holds — only the mem_issue handshake
    // sequence is scoreboarded, not the drained data.
    logic                       out_wr_en_w;
    logic [URAM_ADDR_W-1:0]     out_wr_addr_w;
    logic [URAM_WIDTH_BITS-1:0] out_wr_data_w;
    assign out_wr_en_w   = 1'b0;
    assign out_wr_addr_w = '0;
    assign out_wr_data_w = '0;

    // Descriptor table write port.
    logic              desc_we;
    logic [7:0]        desc_wr_addr;
    csd_descriptor_t   desc_wr_data;

    // Phase-8 dense_sched_if. This TB exercises memory/compute ops but not
    // OP_GEMM_LAYER, so the dispatcher's tile-walker stays idle. Tie off the
    // streamer side (load_done + scan bus).
    dense_sched_if sched_bus (.clk(clk), .rst_n(rst_n));
    assign sched_bus.load_done = 1'b0;
    assign sched_bus.w_we      = 1'b0;
    assign sched_bus.w_phys_gc = '0;
    assign sched_bus.w_pe_addr = '0;
    assign sched_bus.w_in      = '0;

    // -------------------------------------------------------------------------
    // Dispatcher sidebands
    // -------------------------------------------------------------------------
    logic                     start;
    logic                     program_done;
    logic                     imem_we;
    logic [IMEM_ADDR_W-1:0]   imem_wr_addr;
    logic [MACRO_WORD_W-1:0]  imem_wr_data;
    logic [NOC_PATH_ID_W-1:0] path_id [N_SOURCES];
    logic [KV_DATA_W-1:0]     kv_wr_data_sideband;

    // -------------------------------------------------------------------------
    // DUTs
    // -------------------------------------------------------------------------
    dispatcher #(
        .IMEM_DEPTH    (IMEM_DEPTH),
        .N_NOC_SOURCES (N_SOURCES)
    ) u_disp (
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
        .mem_issue    (memif.disp),
        .kv           (kvif.master),
        .kv_wr_data_i (kv_wr_data_sideband),
        .dense_drain_busy (1'b0)
    );

    memory_manager #(
        .DESC_DEPTH (256)
    ) u_memmgr (
        .clk          (clk),
        .rst_n        (rst_n),
        .issue        (memif.mgr),
        .kv           (kvif.slave),
        .dense_pp     (dense_pp.mem_mgr),
        .sparse_pp    (sparse_pp.mem_mgr),
        .dram         (dramif.mgr),
        .dram_wr      (dram_wr_if.mgr),
        .out_wr_en    (out_wr_en_w),
        .out_wr_addr  (out_wr_addr_w),
        .out_wr_data  (out_wr_data_w),
        .desc_we      (desc_we),
        .desc_wr_addr (desc_wr_addr),
        .desc_wr_data (desc_wr_data)
    );

    noc_fabric #(
        .N_SOURCES (N_SOURCES),
        .DATA_W    (DATA_W),
        .USER_W    (USER_W)
    ) u_fabric (
        .clk     (clk),
        .rst_n   (rst_n),
        .path_id (path_id),
        .cfg     (cfg_bus),
        .src     (src),
        .dst     (noc_dst)
    );

    // Weight-scan sideband for dense_array (Phase-7d: w_phys_gc selects which of
    // the 2 physical column-groups receives the beat).
    logic                     w_we;
    logic                     w_phys_gc;
    logic [PE_ADDR_W-1:0]     w_pe_addr;
    bfp12_mant_t [(BFP12_BLK/2)-1:0] w_in;   // 8 mantissas/beat (C1.5)

    // Time-multiplex tile schedule. SINGLE-TILE GEMM (tile 0,0): the TB plays
    // host, holds tile_gr/tile_gc=0, pulses tile_first before the first acc_clr,
    // and drives tile_last with acc_snap. (Full 32-tile walk lives in
    // tb_archbetter_top.)
    logic [$clog2(DENSE_LOGICAL_TILE_ROWS)-1:0] tile_gr;
    logic [$clog2(DENSE_LOGICAL_TILE_COLS)-1:0] tile_gc;
    logic                     tile_first;
    logic                     tile_last;

    array_acc_t [COLS-1:0]    y_out;
    logic                     y_valid;

    dense_array #(
        .ENABLE_NOISE_HOOKS (1'b0),
        .ARRAY_ID           (32'd0)
    ) u_array (
        .clk       (clk),
        .rst_n     (rst_n),
        .a_strm    (a_strm),
        .tile_gr   (tile_gr),
        .tile_gc   (tile_gc),
        .tile_tok  (BATCH_TOK_W'(0)),
        .batch_n   (BATCH_TOK_W'(1)),
        .drain_busy(1'b0),
        .tile_first(tile_first),
        .tile_last (tile_last),
        .acc_clr   (gemm_bus.acc_clr),
        .acc_snap  (gemm_bus.acc_snap),
        .stream_mode (GEMM_SNAP_PER_TOKEN),   // R6.3: dispatcher TB runs v1 path
        .w_we      (w_we),
        .w_phys_gc (w_phys_gc),
        .w_pe_addr (w_pe_addr),
        .w_in      (w_in),
        .y_out     (y_out),
        .y_valid   (y_valid)
    );

    // Tile schedule driving (single-tile): tile_gr/gc held 0; tile_first pulses
    // on gemm.busy rising (before first acc_clr, clears bank); tile_last tracks
    // acc_snap.
    assign tile_gr = '0;
    assign tile_gc = '0;
    logic gemm_busy_q;
    always_ff @(posedge clk) begin
        if (!rst_n) gemm_busy_q <= 1'b0;
        else        gemm_busy_q <= gemm_bus.busy;
    end
    assign tile_first = gemm_bus.busy && !gemm_busy_q;
    assign tile_last  = gemm_bus.acc_snap;

    sparse_tile u_tile (
        .clk   (clk),
        .rst_n (rst_n),
        .ctrl  (ctrl.tile)
    );

    // -------------------------------------------------------------------------
    // DRAM stub: same deterministic-pattern model as tb_dispatcher_mem.
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        D_IDLE = 2'b00,
        D_REQ  = 2'b01,
        D_RESP = 2'b10
    } dram_state_e;

    dram_state_e            dram_state_q;
    logic [DRAM_ADDR_W-1:0] dram_addr_q;
    logic [DRAM_LEN_W-1:0]  dram_len_q;
    logic [DRAM_LEN_W-1:0]  dram_idx_q;

    logic                   stub_req_ready;
    logic                   stub_rsp_valid;
    logic                   stub_rsp_last;
    logic [DRAM_BEAT_W-1:0] stub_rsp_data;

    always_comb begin
        stub_req_ready = 1'b0;
        stub_rsp_valid = 1'b0;
        stub_rsp_last  = 1'b0;
        stub_rsp_data  = '0;
        unique case (dram_state_q)
            D_IDLE: ;
            D_REQ : stub_req_ready = 1'b1;
            D_RESP: begin
                stub_rsp_valid = 1'b1;
                stub_rsp_last  = (dram_idx_q == DRAM_LEN_W'(dram_len_q - 1'b1));
                stub_rsp_data  = {DRAM_PATTERN_HI,
                                  DRAM_ADDR_W'(dram_addr_q + DRAM_ADDR_W'(dram_idx_q << 3))};
            end
            default: ;
        endcase
    end

    assign dramif.req_ready = stub_req_ready;
    assign dramif.rsp_valid = stub_rsp_valid;
    assign dramif.rsp_last  = stub_rsp_last;
    assign dramif.rsp_data  = stub_rsp_data;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dram_state_q <= D_IDLE;
            dram_addr_q  <= '0;
            dram_len_q   <= '0;
            dram_idx_q   <= '0;
        end else begin
            unique case (dram_state_q)
                D_IDLE: if (dramif.req_valid) dram_state_q <= D_REQ;
                D_REQ : if (dramif.req_valid) begin
                    dram_addr_q  <= dramif.req_addr;
                    dram_len_q   <= dramif.req_len;
                    dram_idx_q   <= '0;
                    dram_state_q <= D_RESP;
                end
                D_RESP: if (dramif.rsp_ready && stub_rsp_valid) begin
                    if (stub_rsp_last) dram_state_q <= D_IDLE;
                    else               dram_idx_q   <= DRAM_LEN_W'(dram_idx_q + 1'b1);
                end
                default: dram_state_q <= D_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Pingpong auto-ack on both pools.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dense_pp.drain_ack  <= 1'b0;
            sparse_pp.drain_ack <= 1'b0;
        end else begin
            dense_pp.drain_ack  <= dense_pp.drain_req  && !dense_pp.drain_ack;
            sparse_pp.drain_ack <= sparse_pp.drain_req && !sparse_pp.drain_ack;
        end
    end

    // Compute-side reads not exercised here; the activation streamer below uses
    // a TB-prepared payload, not URAM contents. Tie the rd ports off so the
    // pingpong assertions stay quiet.
    assign dense_pp.rd_en    = 1'b0;
    assign dense_pp.rd_addr  = '0;
    assign sparse_pp.rd_en   = 1'b0;
    assign sparse_pp.rd_addr = '0;

    // -------------------------------------------------------------------------
    // GEMM activation streamer (TB role: in lieu of a URAM-to-NoC streamer).
    //   On the first cycle gemm.busy rises, push K_GEMM activation beats into
    //   noc_fabric.src[0]. beat_fire is the (valid && ready) feedback.
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] s0_data;
    logic              s0_valid;
    logic              s0_last;
    logic              s0_ready_obs;
    int                beats_fired;

    logic [DATA_W-1:0] act_beats [K_GEMM];

    assign s0_data  = (beats_fired < K_GEMM) ? act_beats[beats_fired] : '0;
    assign s0_last  = (beats_fired == K_GEMM - 1);
    assign s0_valid = gemm_bus.busy && (beats_fired < int'(gemm_bus.k_cnt));

    assign src[0].data  = s0_data;
    assign src[0].user  = 8'h00;
    assign src[0].valid = s0_valid;
    assign src[0].last  = s0_last;
    assign s0_ready_obs = src[0].ready;

    assign gemm_bus.beat_fire = s0_valid && s0_ready_obs;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            beats_fired <= 0;
        end else if (!gemm_bus.busy) begin
            beats_fired <= 0;
        end else if (s0_valid && s0_ready_obs) begin
            beats_fired <= beats_fired + 1;
        end
    end

    // -------------------------------------------------------------------------
    // Phase-7d row-tile mux (mirrors archbetter_top): of noc_dst[0..7], only the
    // one selected by tile_gr is forwarded to the single a_strm. SV forbids
    // runtime-indexing an interface array, so unbundle then mux. dst[8..63]
    // tied ready=1.
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] dst_data_unbund  [DENSE_LOGICAL_TILE_ROWS];
    logic [USER_W-1:0] dst_user_unbund  [DENSE_LOGICAL_TILE_ROWS];
    logic              dst_valid_unbund [DENSE_LOGICAL_TILE_ROWS];
    logic              dst_last_unbund  [DENSE_LOGICAL_TILE_ROWS];

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
    begin : gen_dst_tie
        assign noc_dst[D].ready = 1'b1;
    end : gen_dst_tie

    // -------------------------------------------------------------------------
    // GEMM golden + capture
    // -------------------------------------------------------------------------
    bfp12_mant_t           weights_ref [ROWS][COLS];
    bfp12_mant_t           a_gemm_vec  [K_GEMM][GRS];
    array_acc_t [COLS-1:0] y_expected;
    array_acc_t [COLS-1:0] y_snapped;
    logic                  y_snap_seen;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            y_snapped   <= '{default: '0};
            y_snap_seen <= 1'b0;
        end else if (y_valid) begin
            y_snapped   <= y_out;
            y_snap_seen <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // FFN data + golden
    // -------------------------------------------------------------------------
    bfp12_mant_t      ffn_acts   [TLMM_TILE];
    tern_lane_tiles_t ffn_wbeats [K_FFN];
    tlmm_part_vec_t   ffn_expected_q [$];
    tlmm_part_vec_t   ffn_captured_q [$];

    function automatic tlmm_tile_part_t golden_lane_partial(input tern_tile_t w);
        automatic int acc;
        acc = 0;
        for (int i = 0; i < int'(TLMM_TILE); i++) begin
            unique case (w[i])
                TERN_POS : acc += $signed(ffn_acts[i]);
                TERN_NEG : acc -= $signed(ffn_acts[i]);
                TERN_ZERO: ;
                default  : ;
            endcase
        end
        return tlmm_tile_part_t'(acc);
    endfunction

    task automatic build_ffn_vectors();
        for (int i = 0; i < int'(TLMM_TILE); i++) begin
            ffn_acts[i] = bfp12_mant_t'(signed'(3 + i));
        end
        for (int b = 0; b < K_FFN; b++) begin
            for (int l = 0; l < int'(TLMM_LANES); l++) begin
                for (int i = 0; i < int'(TLMM_TILE); i++) begin
                    automatic int sel = (b + l + i) % 3;
                    unique case (sel)
                        0       : ffn_wbeats[b][l][i] = TERN_ZERO;
                        1       : ffn_wbeats[b][l][i] = TERN_POS;
                        default : ffn_wbeats[b][l][i] = TERN_NEG;
                    endcase
                end
            end
        end
        ffn_expected_q.delete();
        for (int b = 0; b < K_FFN; b++) begin
            tlmm_part_vec_t v;
            for (int l = 0; l < int'(TLMM_LANES); l++) begin
                v[l] = golden_lane_partial(ffn_wbeats[b][l]);
            end
            ffn_expected_q.push_back(v);
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst_n && ctrl.o_valid && ctrl.o_ready) begin
            ffn_captured_q.push_back(ctrl.o_parts);
        end
    end

    // -------------------------------------------------------------------------
    // TLMM driver process: on every tlmm.start pulse, run PROG, stream k_cnt
    // compute beats, then pulse done after k_cnt OUT beats are captured.
    // -------------------------------------------------------------------------
    task automatic tlmm_drive_once();
        int issued;
        int need;
        tlmm_tile_act_t packed_acts;
        int captured_at_entry;

        need              = int'(tlmm_bus.k_cnt);
        captured_at_entry = ffn_captured_q.size();

        for (int i = 0; i < int'(TLMM_TILE); i++) packed_acts[i] = ffn_acts[i];
        ctrl.prog_acts  <= packed_acts;
        ctrl.prog_valid <= 1'b1;
        do @(posedge clk); while (!ctrl.prog_ready);
        ctrl.prog_valid <= 1'b0;

        while (!ctrl.w_ready) @(posedge clk);

        issued = 0;
        while (issued < need) begin
            ctrl.w_tiles <= ffn_wbeats[issued];
            ctrl.w_valid <= 1'b1;
            @(posedge clk);
            if (ctrl.w_ready) begin
                issued++;
            end
        end
        ctrl.w_valid <= 1'b0;
        ctrl.w_tiles <= '0;

        while ((ffn_captured_q.size() - captured_at_entry) < need)
            @(posedge clk);

        tlmm_bus.done <= 1'b1;
        @(posedge clk);
        tlmm_bus.done <= 1'b0;
    endtask

    initial begin : tlmm_driver_proc
        ctrl.prog_acts  <= '0;
        ctrl.prog_valid <= 1'b0;
        ctrl.w_tiles    <= '0;
        ctrl.w_valid    <= 1'b0;
        ctrl.o_ready    <= 1'b1;
        tlmm_bus.done   <= 1'b0;

        @(posedge clk iff rst_n);

        forever begin
            @(posedge clk iff (rst_n && tlmm_bus.start));
            tlmm_drive_once();
        end
    end

    // -------------------------------------------------------------------------
    // mem_issue scoreboard
    // -------------------------------------------------------------------------
    typedef struct packed {
        macro_opc_e opc;
        logic [7:0] tile_id;
        logic       is_sparse;
    } mem_obs_t;

    mem_obs_t mem_exp_q [$];
    mem_obs_t mem_obs_q [$];

    always_ff @(posedge clk) begin
        if (rst_n && memif.start) begin
            mem_obs_t e;
            e.opc       = memif.opc;
            e.tile_id   = memif.tile_id;
            e.is_sparse = memif.is_sparse;
            mem_obs_q.push_back(e);
        end
    end

    // -------------------------------------------------------------------------
    // KV scoreboard + sideband driver
    // -------------------------------------------------------------------------
    logic [KV_DATA_W-1:0] kv_mirror [2**KV_ADDR_W];

    typedef struct packed {
        logic                 is_read;
        logic [KV_ADDR_W-1:0] addr;
        logic [KV_DATA_W-1:0] data;
    } kv_obs_t;

    kv_obs_t kv_exp_q [$];
    kv_obs_t kv_obs_q [$];

    // 2-stage rd_addr shadow aligned to the KV BRAM 2-cycle read latency
    // (output latch + OREG). Shifts every cycle, so it is correct for spaced
    // AND back-to-back reads; non-rd_en cycles never produce an rd_valid, so
    // the shadow is only ever sampled at an aligned slot.
    logic [KV_ADDR_W-1:0] kv_rd_addr_s1, kv_rd_addr_s2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            kv_rd_addr_s1 <= '0;
            kv_rd_addr_s2 <= '0;
        end else begin
            kv_rd_addr_s1 <= kvif.rd_addr;
            kv_rd_addr_s2 <= kv_rd_addr_s1;

            if (kvif.wr_en) begin
                kv_obs_t e;
                e.is_read = 1'b0;
                e.addr    = kvif.wr_addr;
                e.data    = kvif.wr_data;
                kv_obs_q.push_back(e);
            end
            if (kvif.rd_valid) begin
                kv_obs_t e;
                e.is_read = 1'b1;
                e.addr    = kv_rd_addr_s2;
                e.data    = kvif.rd_data;
                kv_obs_q.push_back(e);
            end
        end
    end

    // KV write-data sideband: when the next-to-decode opcode is OP_KV_WRITE,
    // present the matching mirror payload so the dispatcher latches it on the
    // wr_en cycle.
    always_comb begin
        kv_wr_data_sideband = '0;
        if (rst_n) begin
            automatic logic [MACRO_WORD_W-1:0] cur     = u_disp.imem[u_disp.pc];
            automatic logic [MACRO_OPC_W-1:0]  cur_opc = cur[63:58];
            automatic logic [KV_ADDR_W-1:0]    cur_addr;
            cur_addr = {cur[47:42], cur[57:50]};
            if (cur_opc == OP_KV_WRITE) begin
                kv_wr_data_sideband = kv_mirror[cur_addr];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Builders / utilities
    // -------------------------------------------------------------------------
    function automatic logic [MACRO_WORD_W-1:0] mk_instr(
        input macro_opc_e  opc,
        input logic [7:0]  tile_id,
        input logic [7:0]  path_id_field,
        input logic [31:0] low32
    );
        logic [MACRO_WORD_W-1:0] w;
        w        = '0;
        w[63:58] = opc;
        w[57:50] = tile_id;
        w[49:42] = path_id_field;
        w[31:0]  = low32;
        return w;
    endfunction

    function automatic logic [MACRO_WORD_W-1:0] mk_instr_flags(
        input macro_opc_e  opc,
        input logic [7:0]  tile_id,
        input logic [7:0]  path_id_field,
        input logic [11:0] flags
    );
        logic [MACRO_WORD_W-1:0] w;
        w        = '0;
        w[63:58] = opc;
        w[57:50] = tile_id;
        w[49:42] = path_id_field;
        w[11:0]  = flags;
        return w;
    endfunction

    function automatic logic [31:0] mk_meta_payload(
        input logic [5:0] src_node,
        input logic [2:0] priority_lvl,
        input logic       is_multicast
    );
        logic [31:0] p;
        p       = '0;
        p[9:4]  = src_node;
        p[3:1]  = priority_lvl;
        p[0]    = is_multicast;
        return p;
    endfunction

    function automatic logic [31:0] mk_kcnt_payload(input int k_cnt);
        logic [31:0] p;
        p = '0;
        p[21:12] = k_cnt[9:0];
        return p;
    endfunction

    function automatic logic [KV_DATA_W-1:0] rand_kv();
        logic [KV_DATA_W-1:0] v;
        v = {$urandom(), $urandom(), $urandom(), $urandom(), $urandom()};
        v = v[KV_DATA_W-1:0];
        return v;
    endfunction

    task automatic imem_write(
        input logic [IMEM_ADDR_W-1:0]  addr,
        input logic [MACRO_WORD_W-1:0] word
    );
        @(negedge clk);
        imem_we      = 1'b1;
        imem_wr_addr = addr;
        imem_wr_data = word;
        @(negedge clk);
        imem_we      = 1'b0;
    endtask

    task automatic write_desc(
        input logic [7:0]             tile_id,
        input logic                   is_sparse_f,
        input logic [URAM_AW-1:0]     uram_base,
        input logic [DRAM_ADDR_W-1:0] dram_base,
        input logic [DRAM_LEN_W-1:0]  n_beats
    );
        csd_descriptor_t d;
        d.compressed = 1'b0;
        d.is_sparse  = is_sparse_f;
        d.uram_base  = uram_base;
        d.dram_base  = dram_base;
        d.n_beats    = n_beats;
        @(negedge clk);
        desc_we      = 1'b1;
        desc_wr_addr = tile_id;
        desc_wr_data = d;
        @(negedge clk);
        desc_we      = 1'b0;
    endtask

    // Single tile (0,0): the 16x32 physical kernel holds rows [0..15] x cols
    // [0..31]. Phys group 0 -> cols [0..15], group 1 -> cols [16..31].
    task automatic program_weights();
        localparam int WSCAN = BFP12_BLK / 2;   // 8 PEs/beat
        for (int local_r = 0; local_r < GRS; local_r++) begin
            for (int half = 0; half < GCS / WSCAN; half++) begin
                automatic int c_base = half * WSCAN;
                @(posedge clk);
                for (int s = 0; s < WSCAN; s++)
                    w_in[s] <= weights_ref[local_r][c_base + s];
                w_we      <= 1'b1;
                w_phys_gc <= 1'b0;
                w_pe_addr <= PE_ADDR_W'(local_r * GCS + c_base);
                @(posedge clk);
                for (int s = 0; s < WSCAN; s++)
                    w_in[s] <= weights_ref[local_r][GCS + c_base + s];
                w_we      <= 1'b1;
                w_phys_gc <= 1'b1;
                w_pe_addr <= PE_ADDR_W'(local_r * GCS + c_base);
            end
        end
        @(posedge clk);
        w_we <= 1'b0;
        w_in <= '0;
    endtask

    task automatic fill_weights_diag_mix();
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                automatic int v = ((r + c) % 5) - 2;
                weights_ref[r][c] = bfp12_mant_t'(signed'(v));
            end
        end
    endtask

    task automatic build_gemm_vectors();
        for (int k = 0; k < K_GEMM; k++) begin
            for (int r = 0; r < GRS; r++) begin
                a_gemm_vec[k][r] = bfp12_mant_t'(signed'(k*10 + r + 1));
            end
        end
        for (int k = 0; k < K_GEMM; k++) begin
            automatic logic [DATA_W-1:0] d;
            d = '0;
            for (int r = 0; r < GRS; r++) begin
                d[r*BFP12_MANT_W +: BFP12_MANT_W] = a_gemm_vec[k][r];
            end
            act_beats[k] = d;
        end
        // Golden for the SINGLE tile (0,0): only rows [0..15] and cols [0..31].
        // The 16-wide beat broadcasts to both physical groups, so
        // y[c] = sum_k sum_r a[k][r] * W[r, c] for c in [0..31]; 0 otherwise.
        for (int c = 0; c < COLS; c++) y_expected[c] = '0;
        for (int c = 0; c < int'(DENSE_PHYS_COLS); c++) begin
            automatic array_acc_t acc;
            acc = '0;
            for (int k = 0; k < K_GEMM; k++) begin
                for (int r = 0; r < GRS; r++) begin
                    acc += array_acc_t'(
                        $signed(a_gemm_vec[k][r])
                      * $signed(weights_ref[r][c])
                    );
                end
            end
            y_expected[c] = acc;
        end
    endtask

    // -------------------------------------------------------------------------
    // Scoreboards
    // -------------------------------------------------------------------------
    int n_errors;
    int n_checks;

    task automatic compare_mem_queues();
        int n_exp = mem_exp_q.size();
        int n_obs = mem_obs_q.size();
        n_checks++;
        if (n_exp != n_obs) begin
            n_errors++;
            $display("[%0t] MEM SEQ LENGTH MISMATCH exp=%0d obs=%0d",
                     $time, n_exp, n_obs);
        end
        for (int i = 0; i < ((n_exp < n_obs) ? n_exp : n_obs); i++) begin
            mem_obs_t e = mem_exp_q[i];
            mem_obs_t o = mem_obs_q[i];
            n_checks++;
            if (e.opc !== o.opc) begin
                n_errors++;
                $display("[%0t] MEM[%0d] opc mismatch exp=%0h obs=%0h",
                         $time, i, e.opc, o.opc);
            end
            if (e.tile_id !== o.tile_id) begin
                n_errors++;
                $display("[%0t] MEM[%0d] tile_id mismatch exp=%0h obs=%0h",
                         $time, i, e.tile_id, o.tile_id);
            end
            if (e.is_sparse !== o.is_sparse) begin
                n_errors++;
                $display("[%0t] MEM[%0d] is_sparse mismatch exp=%0b obs=%0b",
                         $time, i, e.is_sparse, o.is_sparse);
            end
        end
    endtask

    task automatic compare_kv_queues();
        int n_exp = kv_exp_q.size();
        int n_obs = kv_obs_q.size();
        n_checks++;
        if (n_exp != n_obs) begin
            n_errors++;
            $display("[%0t] KV SEQ LENGTH MISMATCH exp=%0d obs=%0d",
                     $time, n_exp, n_obs);
        end
        for (int i = 0; i < ((n_exp < n_obs) ? n_exp : n_obs); i++) begin
            kv_obs_t e = kv_exp_q[i];
            kv_obs_t o = kv_obs_q[i];
            n_checks++;
            if (e.is_read !== o.is_read) begin
                n_errors++;
                $display("[%0t] KV[%0d] direction mismatch exp_read=%0b obs_read=%0b",
                         $time, i, e.is_read, o.is_read);
            end
            if (e.addr !== o.addr) begin
                n_errors++;
                $display("[%0t] KV[%0d] addr mismatch exp=%0h obs=%0h",
                         $time, i, e.addr, o.addr);
            end
            if (e.data !== o.data) begin
                n_errors++;
                $display("[%0t] KV[%0d] data mismatch exp=%0h obs=%0h",
                         $time, i, e.data, o.data);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin : main
        logic [IMEM_ADDR_W-1:0] a;
        int waited;
        logic [KV_DATA_W-1:0]   kv_val_0, kv_val_1, kv_val_2;
        logic [KV_ADDR_W-1:0]   kv_addr_0, kv_addr_1, kv_addr_2;

        n_errors            = 0;
        n_checks            = 0;
        rst_n               = 1'b0;
        start               = 1'b0;
        imem_we             = 1'b0;
        imem_wr_addr        = '0;
        imem_wr_data        = '0;
        desc_we             = 1'b0;
        desc_wr_addr        = '0;
        desc_wr_data        = '0;
        w_we                = 1'b0;
        w_phys_gc           = 1'b0;
        w_pe_addr           = '0;
        w_in                = '0;

        for (int i = 0; i < 2**KV_ADDR_W; i++) kv_mirror[i] = '0;

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // ---------------------------------------------------------------------
        // STAGE 0: build vectors + golden, scan dense weights, load descriptors
        // ---------------------------------------------------------------------
        $display("[%0t] STAGE 0: fill weight plane + build golden", $time);
        fill_weights_diag_mix();
        build_gemm_vectors();
        build_ffn_vectors();

        $display("[%0t] STAGE 1: scan tile(0,0) 16x32 dense weights", $time);
        program_weights();

        $display("[%0t] STAGE 2: load CSD descriptors", $time);
        // tile 0 (dense), tile 1 (sparse). Pre-compressed=0 so the engine
        // treats each as a pass-through fill from DRAM.
        write_desc(8'd0, /*is_sparse=*/ 1'b0, URAM_AW'(12'h010),
                   DRAM_ADDR_W'(32'h1000_0000), DRAM_LEN_W'(N_BEATS_SMALL));
        write_desc(8'd1, /*is_sparse=*/ 1'b1, URAM_AW'(12'h020),
                   DRAM_ADDR_W'(32'h2000_0000), DRAM_LEN_W'(N_BEATS_SMALL));

        // ---------------------------------------------------------------------
        // STAGE 3: Build the program
        // ---------------------------------------------------------------------
        kv_addr_0 = KV_ADDR_W'(14'h0042);
        kv_addr_1 = KV_ADDR_W'(14'h00A5);
        kv_addr_2 = KV_ADDR_W'(14'h1234);
        kv_val_0  = rand_kv();
        kv_val_1  = rand_kv();
        kv_val_2  = rand_kv();
        kv_mirror[kv_addr_0] = kv_val_0;
        kv_mirror[kv_addr_1] = kv_val_1;
        kv_mirror[kv_addr_2] = kv_val_2;

        $display("[%0t] STAGE 3: load imem program", $time);
        a = '0;
        imem_write(a, mk_instr_flags(OP_NOP,        8'h00, 8'h00, 12'h000)); a++;
        imem_write(a, mk_instr_flags(OP_LD_W_URAM,  8'h00, 8'h00, 12'h000)); a++;
        imem_write(a, mk_instr_flags(OP_LD_A_URAM,  8'h01, 8'h00,
                               12'h000 | (1 << FLG_IS_SPARSE))); a++;
        imem_write(a, mk_instr_flags(OP_PINGPONG,   8'h00, 8'h00, 12'h000)); a++;
        imem_write(a, mk_instr_flags(OP_PINGPONG,   8'h01, 8'h00,
                               12'h000 | (1 << FLG_IS_SPARSE))); a++;
        imem_write(a, mk_instr(OP_CFG_NOC,
                               {6'd0, CFG_NOC_MASK_LO},
                               {3'd0, TGT_HANDLE},
                               TGT_MASK_LO)); a++;
        imem_write(a, mk_instr(OP_CFG_NOC,
                               {6'd0, CFG_NOC_MASK_HI},
                               {3'd0, TGT_HANDLE},
                               TGT_MASK_HI)); a++;
        imem_write(a, mk_instr(OP_CFG_NOC,
                               {6'd0, CFG_NOC_META},
                               {3'd0, TGT_HANDLE},
                               mk_meta_payload(TGT_SRC_NODE,
                                               TGT_PRIORITY,
                                               TGT_IS_MULTICAST))); a++;
        imem_write(a, mk_instr(OP_BARRIER,    8'h00, 8'h00, 32'h0)); a++;
        imem_write(a, mk_instr(OP_COMMIT_NOC, 8'h00, 8'h00, 32'h0)); a++;
        imem_write(a, mk_instr(OP_GEMM_ALL,   8'h00,
                               {3'd0, TGT_HANDLE},
                               mk_kcnt_payload(K_GEMM))); a++;
        imem_write(a, mk_instr(OP_BARRIER,    8'h00, 8'h00, 32'h0)); a++;
        imem_write(a, mk_instr(OP_FFN_TLMM,   8'h00, 8'h00,
                               mk_kcnt_payload(K_FFN))); a++;
        imem_write(a, mk_instr_flags(OP_KV_WRITE,
                               kv_addr_0[7:0],
                               {2'b00, kv_addr_0[13:8]},
                               12'h000)); a++;
        imem_write(a, mk_instr_flags(OP_KV_WRITE,
                               kv_addr_1[7:0],
                               {2'b00, kv_addr_1[13:8]},
                               12'h000)); a++;
        imem_write(a, mk_instr_flags(OP_KV_WRITE,
                               kv_addr_2[7:0],
                               {2'b00, kv_addr_2[13:8]},
                               12'h000)); a++;
        imem_write(a, mk_instr_flags(OP_KV_READ,
                               kv_addr_0[7:0],
                               {2'b00, kv_addr_0[13:8]},
                               12'h000)); a++;
        imem_write(a, mk_instr_flags(OP_KV_READ,
                               kv_addr_2[7:0],
                               {2'b00, kv_addr_2[13:8]},
                               12'h000)); a++;
        imem_write(a, mk_instr_flags(OP_KV_READ,
                               kv_addr_1[7:0],
                               {2'b00, kv_addr_1[13:8]},
                               12'h000)); a++;
        imem_write(a, mk_instr_flags(OP_ST_OUT,     8'h00, 8'h00, 12'h000)); a++;
        imem_write(a, mk_instr_flags(OP_EOP,        8'h00, 8'h00, 12'h000)); a++;

        // Expected mem_issue handshake sequence (program order).
        mem_exp_q.push_back('{opc:OP_LD_W_URAM, tile_id:8'h00, is_sparse:1'b0});
        mem_exp_q.push_back('{opc:OP_LD_A_URAM, tile_id:8'h01, is_sparse:1'b1});
        mem_exp_q.push_back('{opc:OP_PINGPONG,  tile_id:8'h00, is_sparse:1'b0});
        mem_exp_q.push_back('{opc:OP_PINGPONG,  tile_id:8'h01, is_sparse:1'b1});
        mem_exp_q.push_back('{opc:OP_ST_OUT,    tile_id:8'h00, is_sparse:1'b0});

        // Expected KV sequence.
        kv_exp_q.push_back('{is_read:1'b0, addr:kv_addr_0, data:kv_val_0});
        kv_exp_q.push_back('{is_read:1'b0, addr:kv_addr_1, data:kv_val_1});
        kv_exp_q.push_back('{is_read:1'b0, addr:kv_addr_2, data:kv_val_2});
        kv_exp_q.push_back('{is_read:1'b1, addr:kv_addr_0, data:kv_val_0});
        kv_exp_q.push_back('{is_read:1'b1, addr:kv_addr_2, data:kv_val_2});
        kv_exp_q.push_back('{is_read:1'b1, addr:kv_addr_1, data:kv_val_1});

        // ---------------------------------------------------------------------
        // STAGE 4: start dispatcher and wait for program_done
        // ---------------------------------------------------------------------
        $display("[%0t] STAGE 4: start dispatcher", $time);
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        waited = 0;
        while (!program_done) begin
            @(posedge clk);
            waited++;
            if (waited > 50_000) begin
                $fatal(1, "tb_dispatcher_full: program_done never asserted after %0d cycles",
                       waited);
            end
        end
        $display("[%0t] program_done asserted after %0d cycles", $time, waited);

        // Let residual rd_valid / done pulses settle.
        repeat (16) @(posedge clk);

        // ---------------------------------------------------------------------
        // STAGE 5: GEMM check
        // ---------------------------------------------------------------------
        $display("[%0t] STAGE 5: check GEMM result", $time);
        n_checks++;
        if (!y_snap_seen) begin
            n_errors++;
            $error("GEMM: y_valid never observed");
        end else begin
            automatic int col_errs = 0;
            for (int c = 0; c < COLS; c++) begin
                n_checks++;
                if (y_snapped[c] !== y_expected[c]) begin
                    n_errors++;
                    col_errs++;
                    if (col_errs <= 8) begin
                        $error("GEMM col %0d mismatch: dut=%0d ref=%0d",
                               c, $signed(y_snapped[c]),
                                  $signed(y_expected[c]));
                    end
                end
            end
            if (col_errs == 0)
                $display("[%0t] GEMM PASS: all %0d columns match", $time, COLS);
            else
                $display("[%0t] GEMM FAIL: %0d/%0d columns mismatched",
                         $time, col_errs, COLS);
        end

        // ---------------------------------------------------------------------
        // STAGE 6: FFN check
        // ---------------------------------------------------------------------
        $display("[%0t] STAGE 6: check FFN result", $time);
        n_checks++;
        if (ffn_captured_q.size() != K_FFN) begin
            n_errors++;
            $error("FFN: captured %0d beats, expected %0d",
                   ffn_captured_q.size(), K_FFN);
        end else begin
            for (int b = 0; b < K_FFN; b++) begin
                automatic tlmm_part_vec_t act_vec = ffn_captured_q[b];
                automatic tlmm_part_vec_t exp_vec = ffn_expected_q[b];
                for (int l = 0; l < int'(TLMM_LANES); l++) begin
                    n_checks++;
                    if (act_vec[l] !== exp_vec[l]) begin
                        n_errors++;
                        $error("FFN beat %0d lane %0d mismatch: dut=%0d ref=%0d",
                               b, l, $signed(act_vec[l]), $signed(exp_vec[l]));
                    end
                end
            end
            $display("[%0t] FFN check done (%0d beats)", $time, K_FFN);
        end

        // ---------------------------------------------------------------------
        // STAGE 7: mem_issue and KV sequence checks
        // ---------------------------------------------------------------------
        $display("[%0t] STAGE 7: check mem_issue + KV sequences", $time);
        compare_mem_queues();
        compare_kv_queues();

        // ---------------------------------------------------------------------
        // Finish
        // ---------------------------------------------------------------------
        if (n_errors == 0 && n_checks > 0) begin
            $display("=========================================================");
            $display(" tb_dispatcher_full: PASS  (%0d checks, 0 errors)", n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_dispatcher_full: FAIL  (%0d checks, %0d errors)",
                     n_checks, n_errors);
            $display("=========================================================");
        end
        $finish;
    end

    // -------------------------------------------------------------------------
    // Watchdog. Generous: 16k weight scan + memory fills + GEMM + FFN.
    // -------------------------------------------------------------------------
    initial begin : watchdog
        #(T_CLK * 1_000_000);
        $fatal(1, "tb_dispatcher_full: watchdog timeout");
    end

endmodule : tb_dispatcher_full

`default_nettype wire
`endif // ARCHBETTER_TB_DISPATCHER_FULL_SV
