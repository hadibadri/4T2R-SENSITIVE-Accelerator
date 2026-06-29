// -----------------------------------------------------------------------------
// tb_dispatcher_compute.sv
//
// Layer-2 integration testbench: dispatcher + noc_fabric (N_SOURCES=1) +
// dense_array + sparse_tile.
//
// Topology under test
// -------------------
//   imem (TB write)                          weight-scan port (TB write)
//        |                                               |
//        v                                               v
//   +-----------+    noc_cfg_if   +-------------+  +----------------+
//   |dispatcher |----------------->| noc_fabric |->| dense_array    |
//   |           |    path_id_o    |  1 source  |  |  (via dst[0..7]|
//   |           |---------------->|  64 dsts   |  |   -> a_strm[gr])|
//   |           |    gemm_iss_if  +-------------+  +----------------+
//   |           |--- busy,acc_clr,acc_snap,k_cnt -> TB (plays driver)
//   |           |<--- beat_fire ---------------- TB (= src[0] fire)
//   |           |    tlmm_iss_if
//   |           |--- start,busy,k_cnt ---------> TB (plays driver)
//   |           |<--- done ----------------------+
//   +-----------+                                |
//                                                v
//                                          sparse_tile
//                                       (TB drives tlmm_ctrl_if
//                                        PROG / COMPUTE channels,
//                                        scoreboards OUT channel)
//
// The TB plays two roles that in Layer 3 belong to the memory manager and
// the TLMM driver:
//   * GEMM driver: while dispatcher.gemm.busy is high, streams k_cnt
//     activation beats into noc_fabric.src[0]. beat_fire is fed back as
//     (src[0].valid && src[0].ready).
//   * TLMM driver: on dispatcher.tlmm.start pulse, runs a PROG handshake,
//     waits for the tile to finish filling tables, streams k_cnt compute
//     beats, and pulses tlmm.done once all k_cnt OUT beats have been
//     captured.
//
// Program under test
//   0  OP_NOP
//   1  OP_CFG_NOC MASK_LO handle=0 payload=mask[31:0]
//   2  OP_CFG_NOC MASK_HI handle=0 payload=mask[63:32]
//   3  OP_CFG_NOC META    handle=0 src=0, prio=0, is_mc=1
//   4  OP_BARRIER
//   5  OP_COMMIT_NOC
//   6  OP_GEMM_ALL       path_id=0, k_cnt=K_GEMM
//   7  OP_BARRIER
//   8  OP_FFN_TLMM       k_cnt=K_FFN
//   9  OP_EOP
//
// Phase-7d note: the dense_array is now the time-multiplexed 16x32 kernel, and
// the dispatcher's OP_GEMM is ONE logical tile's reduction. This TB therefore
// validates a SINGLE-TILE GEMM (tile 0,0): the TB plays host and holds
// tile_gr=tile_gc=0, pulses tile_first before the first acc_clr, and drives
// tile_last with acc_snap. The full 32-tile layer walk is host orchestration
// that belongs in tb_archbetter_top. The 16-wide activation beat broadcasts to
// both physical groups, so:
//   y[c] = sum_k sum_r a[k][r] * W[r, c]   for c in [0..31]; 0 otherwise.
//
// Checks
//   GEMM : y_out[128] matches SV golden (cols 0..31 = tile result, rest 0).
//   FFN  : captured o_parts sequence matches SV golden for K_FFN beats.
//   Program: dispatcher.program_done rises and stays high.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_TB_DISPATCHER_COMPUTE_SV
`define ARCHBETTER_TB_DISPATCHER_COMPUTE_SV
`default_nettype none
`timescale 1ns/1ps

module tb_dispatcher_compute
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

    localparam int  ROWS        = DENSE_ARRAY_ROWS;    // 128
    localparam int  COLS        = DENSE_ARRAY_COLS;    // 128
    localparam int  GROWS       = DENSE_GROUPS_ROW;    //   8
    localparam int  GCOLS       = DENSE_GROUPS_COL;    //   8
    localparam int  GRS         = DENSE_GROUP_ROWS;    //  16
    localparam int  GCS         = DENSE_GROUP_COLS;    //  16
    localparam int  PE_ADDR_W   = $clog2(DENSE_PE_PER_GROUP);

    localparam int  K_GEMM      = 2;
    localparam int  K_FFN       = 3;

    // Multicast all 8 group-row destinations (dst[0..7]).
    localparam noc_mask_t TGT_MASK = noc_mask_t'(64'h0000_0000_0000_00FF);
    localparam logic [31:0] TGT_MASK_LO = TGT_MASK[31:0];
    localparam logic [31:0] TGT_MASK_HI = TGT_MASK[63:32];
    localparam logic [5:0]  TGT_SRC_NODE     = 6'd0;
    localparam logic [2:0]  TGT_PRIORITY     = 3'd0;
    localparam logic        TGT_IS_MULTICAST = 1'b1;
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
        src      [N_SOURCES] (.clk(clk), .rst_n(rst_n));
    strm_if #(.DATA_W(DATA_W), .USER_W(USER_W))
        noc_dst  [NOC_NODES]  (.clk(clk), .rst_n(rst_n));
    // Phase-7d: the time-multiplexed dense_array has a SINGLE activation stream.
    // The 8 row-tile NoC drops noc_dst[0..7] are muxed by tile_gr below, exactly
    // as archbetter_top does.
    strm_if #(.DATA_W(DATA_W), .USER_W(USER_W))
        a_strm                (.clk(clk), .rst_n(rst_n));

    gemm_issue_if gemm_bus (.clk(clk), .rst_n(rst_n));
    tlmm_issue_if tlmm_bus (.clk(clk), .rst_n(rst_n));
    tlmm_ctrl_if  ctrl     (.clk(clk), .rst_n(rst_n));

    // Layer-3 dispatcher ports the program never exercises (no mem / KV ops),
    // tied off so elaboration is happy and the dispatcher never blocks on them.
    mem_issue_if  mem_if   (.clk(clk), .rst_n(rst_n));
    kv_access_if  kv_if    (.clk(clk), .rst_n(rst_n));
    assign mem_if.done    = 1'b0;   // no OP_LD / OP_ST_OUT / OP_PINGPONG issued
    assign kv_if.rd_data  = '0;
    assign kv_if.rd_valid = 1'b0;   // no OP_KV_READ issued

    // Phase-8 dense_sched_if. This TB runs OP_GEMM_ALL (single tile), never
    // OP_GEMM_LAYER, so the dispatcher's tile-walker stays idle. Tie off the
    // streamer side (load_done + scan bus) so elaboration is clean.
    dense_sched_if sched_bus (.clk(clk), .rst_n(rst_n));
    assign sched_bus.load_done = 1'b0;
    assign sched_bus.w_we      = 1'b0;
    assign sched_bus.w_phys_gc = '0;
    assign sched_bus.w_pe_addr = '0;
    assign sched_bus.w_in      = '0;

    // -------------------------------------------------------------------------
    // Dispatcher control / imem sideband
    // -------------------------------------------------------------------------
    logic                    start;
    logic                    program_done;
    logic                    imem_we;
    logic [IMEM_ADDR_W-1:0]  imem_wr_addr;
    logic [MACRO_WORD_W-1:0] imem_wr_data;
    logic [NOC_PATH_ID_W-1:0] path_id [N_SOURCES];

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
        .mem_issue    (mem_if.disp),
        .kv           (kv_if.master),
        .kv_wr_data_i ('0),
        .dense_drain_busy (1'b0)
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
    logic                  w_we;
    logic                  w_phys_gc;
    logic [PE_ADDR_W-1:0]  w_pe_addr;
    bfp12_mant_t [(BFP12_BLK/2)-1:0] w_in;   // 8 mantissas/beat (C1.5)

    // Time-multiplex tile schedule. This is a SINGLE-TILE GEMM test (tile 0,0):
    // the dispatcher's unit of work is one 16x32 tile, so the TB (acting as the
    // host) holds tile_gr/tile_gc at 0, pulses tile_first before the first
    // acc_clr, and drives tile_last concurrent with acc_snap. The full 32-tile
    // layer walk is host orchestration that lives in tb_archbetter_top.
    logic [$clog2(DENSE_LOGICAL_TILE_ROWS)-1:0] tile_gr;
    logic [$clog2(DENSE_LOGICAL_TILE_COLS)-1:0] tile_gc;
    logic                  tile_first;
    logic                  tile_last;

    array_acc_t [COLS-1:0] y_out;
    logic                  y_valid;

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

    // -------------------------------------------------------------------------
    // Tile schedule driving (single-tile test).
    //   tile_gr/tile_gc : held at 0.
    //   tile_first      : 1-cycle pulse on the rising edge of gemm.busy, before
    //                     the first acc_clr — clears the array bank.
    //   tile_last       : driven concurrent with acc_snap (this is the only and
    //                     therefore the last tile of the layer).
    // -------------------------------------------------------------------------
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
    // src[0] drive: combinational from gemm.busy and beats_fired.
    //   TB is the "memory manager proxy": on the first cycle gemm.busy rises,
    //   src[0].valid goes high and stays high until k_cnt beats have fired.
    //   Data is pre-loaded by the TB before start.
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] s0_data;
    logic              s0_valid;
    logic              s0_last;
    logic              s0_ready_obs;
    int                beats_fired;

    // Pre-packed activation payloads, one per GEMM beat.
    logic [DATA_W-1:0] act_beats [K_GEMM];

    assign s0_data  = (beats_fired < K_GEMM) ? act_beats[beats_fired] : '0;
    assign s0_last  = (beats_fired == K_GEMM - 1);
    assign s0_valid = gemm_bus.busy && (beats_fired < int'(gemm_bus.k_cnt));

    assign src[0].data  = s0_data;
    assign src[0].user  = 8'h00;
    assign src[0].valid = s0_valid;
    assign src[0].last  = s0_last;
    assign s0_ready_obs = src[0].ready;

    // beat_fire is the control-plane feedback to the dispatcher.
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
    // Phase-7d row-tile mux (mirrors archbetter_top): of the 8 row-tile NoC
    // drops noc_dst[0..7], only the one selected by tile_gr is forwarded to the
    // dense_array's single activation stream. SV forbids runtime-indexing an
    // interface array, so unbundle into plain arrays first, then mux by tile_gr.
    // The unused dst[8..63] are tied ready=1.
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
    // Weight mirror + golden storage
    // -------------------------------------------------------------------------
    bfp12_mant_t         weights_ref [ROWS][COLS];
    bfp12_mant_t         a_gemm_vec  [K_GEMM][GRS];  // per beat: 16 mantissas
    array_acc_t [COLS-1:0] y_expected;
    array_acc_t [COLS-1:0] y_snapped;
    logic                  y_snap_seen;

    // Single-driver capture: y_snap_seen is reset by rst_n and set on y_valid in
    // this always_ff only (no procedural init elsewhere) so it elaborates clean.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            y_snap_seen <= 1'b0;
        end else if (y_valid) begin
            y_snapped   <= y_out;
            y_snap_seen <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Instruction-word builder (reused from tb_dispatcher_noc).
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

    // k_cnt sits at instr_raw[21:12] (macro_instr_t::k_cnt is bits [21:12]).
    function automatic logic [31:0] mk_kcnt_payload(input int k_cnt);
        logic [31:0] p;
        p = '0;
        p[21:12] = k_cnt[9:0];
        return p;
    endfunction

    // -------------------------------------------------------------------------
    // TB-side imem write.
    // -------------------------------------------------------------------------
    task automatic imem_write(
        input logic [IMEM_ADDR_W-1:0]  addr,
        input logic [MACRO_WORD_W-1:0] word
    );
        @(posedge clk);
        imem_we      <= 1'b1;
        imem_wr_addr <= addr;
        imem_wr_data <= word;
        @(posedge clk);
        imem_we      <= 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Weight scan for the single tile (0,0): the 16x32 physical kernel holds
    // rows [0..15] x cols [0..31]. Phys group 0 -> cols [0..15], phys group 1 ->
    // cols [16..31]; pe_addr within a group = local_r*16 + local_c.
    // -------------------------------------------------------------------------
    task automatic program_weights();
        localparam int WSCAN = BFP12_BLK / 2;   // 8 PEs/beat
        for (int local_r = 0; local_r < GRS; local_r++) begin
            for (int half = 0; half < GCS / WSCAN; half++) begin
                automatic int c_base = half * WSCAN;
                // phys group 0 (cols 0..15)
                @(posedge clk);
                for (int s = 0; s < WSCAN; s++)
                    w_in[s] <= weights_ref[local_r][c_base + s];
                w_we      <= 1'b1;
                w_phys_gc <= 1'b0;
                w_pe_addr <= PE_ADDR_W'(local_r * GCS + c_base);
                // phys group 1 (cols 16..31)
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

    // -------------------------------------------------------------------------
    // Build activations and golden for the GEMM op. One 192b beat carries 16
    // mantissas; every group-row sees the same beat (broadcast), so the
    // effective GEMV collapses to sum_{gr,r}.
    // -------------------------------------------------------------------------
    task automatic build_gemm_vectors();
        // Simple, diagnostic activation vectors.
        for (int k = 0; k < K_GEMM; k++) begin
            for (int r = 0; r < GRS; r++) begin
                a_gemm_vec[k][r] = bfp12_mant_t'(signed'(k*10 + r + 1));
            end
        end

        // Pack each beat into a 192b word (row r -> bits [r*12 +: 12]).
        for (int k = 0; k < K_GEMM; k++) begin
            automatic logic [DATA_W-1:0] d;
            d = '0;
            for (int r = 0; r < GRS; r++) begin
                d[r*BFP12_MANT_W +: BFP12_MANT_W] = a_gemm_vec[k][r];
            end
            act_beats[k] = d;
        end

        // Golden for the SINGLE tile (0,0): only rows [0..15] and cols [0..31]
        // participate. The 16-wide activation beat broadcasts to both physical
        // groups, so y[c] = sum_k sum_r a[k][r] * W[r, c] for c in [0..31]; all
        // other columns stay 0 (bank cleared by tile_first, only tile_gc=0's
        // 32-col strip is written).
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
    // FFN data + golden
    // -------------------------------------------------------------------------
    bfp12_mant_t      ffn_acts   [TLMM_TILE];
    tern_lane_tiles_t ffn_wbeats [K_FFN];
    tlmm_part_vec_t   ffn_expected_q [$];
    tlmm_part_vec_t   ffn_captured_q [$];

    function automatic tlmm_tile_part_t golden_lane_partial(
        input tern_tile_t w
    );
        automatic int acc;
        acc = 0;
        for (int i = 0; i < int'(TLMM_TILE); i++) begin
            unique case (w[i])
                TERN_POS : acc += $signed(ffn_acts[i]);
                TERN_NEG : acc -= $signed(ffn_acts[i]);
                TERN_ZERO: ;
                default  : ; // TERN_RSVD treated as zero (never generated here)
            endcase
        end
        return tlmm_tile_part_t'(acc);
    endfunction

    task automatic build_ffn_vectors();
        // Stationary activations: small signed ramp.
        for (int i = 0; i < int'(TLMM_TILE); i++) begin
            ffn_acts[i] = bfp12_mant_t'(signed'(3 + i));
        end

        // Ternary weight beats: a mix per lane per beat. Keep pattern simple
        // and deterministic so failure mode is legible.
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

        // Golden.
        ffn_expected_q.delete();
        for (int b = 0; b < K_FFN; b++) begin
            tlmm_part_vec_t v;
            for (int l = 0; l < int'(TLMM_LANES); l++) begin
                v[l] = golden_lane_partial(ffn_wbeats[b][l]);
            end
            ffn_expected_q.push_back(v);
        end
    endtask

    // -------------------------------------------------------------------------
    // OUT scoreboard: capture every accepted o_parts beat.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst_n && ctrl.o_valid && ctrl.o_ready) begin
            ffn_captured_q.push_back(ctrl.o_parts);
        end
    end

    // -------------------------------------------------------------------------
    // TLMM driver process: on every tlmm.start pulse, run PROG, then stream
    // k_cnt compute beats, then pulse done once all k_cnt OUT beats are in.
    // -------------------------------------------------------------------------
    task automatic tlmm_drive_once();
        int issued;
        int need;
        tlmm_tile_act_t packed_acts;

        need = int'(tlmm_bus.k_cnt);

        // 1. PROG: pack and drive acts until prog_ready fires.
        for (int i = 0; i < int'(TLMM_TILE); i++) packed_acts[i] = ffn_acts[i];
        ctrl.prog_acts  <= packed_acts;
        ctrl.prog_valid <= 1'b1;
        do @(posedge clk); while (!ctrl.prog_ready);
        ctrl.prog_valid <= 1'b0;

        // 2. Wait for tile to finish filling tables.
        while (!ctrl.w_ready) @(posedge clk);

        // 3. Stream need compute beats.
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

        // 4. Wait until scoreboard has captured all need OUT beats.
        while (ffn_captured_q.size() < need) @(posedge clk);

        // 5. Pulse done.
        tlmm_bus.done <= 1'b1;
        @(posedge clk);
        tlmm_bus.done <= 1'b0;
    endtask

    initial begin : tlmm_driver_proc
        ctrl.prog_acts  <= '0;
        ctrl.prog_valid <= 1'b0;
        ctrl.w_tiles    <= '0;
        ctrl.w_valid    <= 1'b0;
        ctrl.o_ready    <= 1'b1;   // always accept
        tlmm_bus.done   <= 1'b0;

        @(posedge clk iff rst_n);

        forever begin
            @(posedge clk iff (rst_n && tlmm_bus.start));
            tlmm_drive_once();
        end
    end

    // -------------------------------------------------------------------------
    // Weight-plane filler. A simple scheme: W[r][c] = ((r + c) % 5) - 2.
    // Small signed values so the accumulator stays well inside array_acc_t.
    // -------------------------------------------------------------------------
    task automatic fill_weights_diag_mix();
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                automatic int v = ((r + c) % 5) - 2; // range [-2, +2]
                weights_ref[r][c] = bfp12_mant_t'(signed'(v));
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Scoreboard
    // -------------------------------------------------------------------------
    int n_errors;
    int n_checks;

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin : main
        logic [IMEM_ADDR_W-1:0] a;
        int waited;

        n_errors     = 0;
        n_checks     = 0;
        rst_n        = 1'b0;
        start        = 1'b0;
        imem_we      = 1'b0;
        imem_wr_addr = '0;
        imem_wr_data = '0;
        w_we         = 1'b0;
        w_phys_gc    = 1'b0;
        w_pe_addr    = '0;
        w_in         = '0;

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // ---------------------------------------------------------------------
        // Pre-stage: build vectors, program weights, build FFN data.
        // This ALL happens before start, so dispatcher stays in S_IDLE and the
        // a_imem_write_only_idle assert is satisfied.
        // ---------------------------------------------------------------------
        $display("[%0t] STAGE 0: fill weight plane + build golden", $time);
        fill_weights_diag_mix();
        build_gemm_vectors();
        build_ffn_vectors();

        $display("[%0t] STAGE 1: scan tile(0,0) 16x32 weights into dense_array", $time);
        program_weights();

        $display("[%0t] STAGE 2: load program into imem", $time);
        a = '0;
        imem_write(a, mk_instr(OP_NOP, 8'h00, 8'h00, 32'h0)); a++;
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
        imem_write(a, mk_instr(OP_EOP,        8'h00, 8'h00, 32'h0)); a++;

        // ---------------------------------------------------------------------
        // STAGE 3: start and wait for program_done.
        // ---------------------------------------------------------------------
        $display("[%0t] STAGE 3: start dispatcher", $time);
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        waited = 0;
        while (!program_done) begin
            @(posedge clk);
            waited++;
            if (waited > 10_000)
                $fatal(1, "program_done never asserted (waited %0d cycles)", waited);
        end
        $display("[%0t] program_done asserted after %0d cycles", $time, waited);

        // Let residual pipeline finish.
        repeat (8) @(posedge clk);

        // ---------------------------------------------------------------------
        // STAGE 4: GEMM check
        // ---------------------------------------------------------------------
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
        // STAGE 5: FFN check
        // ---------------------------------------------------------------------
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
        // Finish
        // ---------------------------------------------------------------------
        if (n_errors == 0 && n_checks > 0) begin
            $display("=========================================================");
            $display(" tb_dispatcher_compute: PASS  (%0d checks, 0 errors)",
                     n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_dispatcher_compute: FAIL  (%0d checks, %0d errors)",
                     n_checks, n_errors);
            $display("=========================================================");
        end
        $finish;
    end

    initial begin : watchdog
        // Budget: 16k cycles for weight scan + a few hundred for the program.
        #(T_CLK * 500_000);
        $fatal(1, "tb_dispatcher_compute: watchdog timeout");
    end

endmodule : tb_dispatcher_compute

`default_nettype wire
`endif // ARCHBETTER_TB_DISPATCHER_COMPUTE_SV
