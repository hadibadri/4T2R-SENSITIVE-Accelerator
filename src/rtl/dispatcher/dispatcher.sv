// -----------------------------------------------------------------------------
// dispatcher.sv
//
// ArchBetter Macro-Instruction Dispatcher - Layer 3 (control + NoC config +
// compute-op issue + memory-op issue + KV cache access).
//
// Scope of this file (Layer 3):
//   Handles:
//       OP_NOP         - single-cycle no-op
//       OP_CFG_NOC     - three-chunk path programming (MASK_LO, MASK_HI, META)
//                        emits exactly one noc_cfg_if handshake on META
//       OP_COMMIT_NOC  - single-cycle pulse on noc_cfg.path_commit
//       OP_BARRIER     - drain hook (trivial at Layer 3 - no in-flight ops
//                        span a BARRIER by construction, since GEMM / FFN /
//                        MEM complete before pc advances)
//       OP_EOP         - stop fetch, assert program_done
//       OP_GEMM_ALL    - latch path_id + k_cnt, drive gemm_issue_if:
//                          * S_GEMM_ACC   : count beat_fire down from k_cnt;
//                                           acc_clr is combinational and pulses
//                                           only on the first beat_fire of the op
//                                           (dense_group co-fire contract)
//                          * S_GEMM_DRAIN : GEMM_DRAIN_CYCLES (=3) pure nops
//                                           after the last beat_fire; required
//                                           because the fused-MACC DSP48E2 has a
//                                           3-cycle latency (a_in -> A-reg ->
//                                           M-reg -> P-reg) so the Kth product
//                                           only reaches the P-register
//                                           accumulator two cycles after its
//                                           beat (see dense_pe.sv timing
//                                           contract)
//                          * S_GEMM_SNAP  : combinational acc_snap=1 this cycle,
//                                           drop busy, advance pc
//       OP_FFN_TLMM    - pulse tlmm_issue_if.start, latch k_cnt, wait for
//                        tlmm.done to advance pc
//       OP_LD_W_URAM   - issue CSD fill on mem_issue_if; wait for done in
//       OP_LD_A_URAM     S_MEM_WAIT. tile_id selects the descriptor table
//       OP_ST_OUT        entry in the memory_manager; flags[FLG_IS_SPARSE]
//       OP_PINGPONG      selects the dense vs sparse pool. All four opcodes
//                        share the mem_issue handshake (start pulse co-rises
//                        with busy, done pulse co-falls with busy). PINGPONG
//                        blocks on the compute-side drain_ack; LD blocks on
//                        CSD completion; ST_OUT is currently a 1-cycle stub.
//       OP_KV_WRITE    - single-cycle direct drive on kv_access_if. The KV
//       OP_KV_READ       address is packed into the macro instr as
//                        { path_id[5:0], tile_id[7:0] } = 14 bits = KV_ADDR_W.
//                        Write data is sourced from the sideband port
//                        kv_wr_data_i (TB drives in tests; the attention
//                        block will drive in the production SoC). rd_data /
//                        rd_valid propagate to the downstream consumer via
//                        the kv_access_if slave side - the dispatcher does
//                        not observe the read result itself.
//
// An unrecognized opcode is treated as OP_NOP in simulation with a $warning so
// that future opcodes can be added without breaking existing programs.
//
// Instruction memory:
//   A small distributed-RAM ROM (LUTRAM, 64-bit words). The host / testbench
//   writes the program word-by-word through the imem_we / imem_wr_addr /
//   imem_wr_data port BEFORE asserting start. Writes while state != S_IDLE
//   are flagged by a simulation assertion.
//
//   Read of the current instruction is combinational from imem[pc]. Depth is
//   small (default 64 words = ~64 LUT6 as LUTRAM) so a flop-less read stays
//   cheap and keeps the FSM one-cycle-per-simple-op.
//
// Latency contract (cycles from decode of the opcode to pc advance):
//   OP_NOP / OP_BARRIER / OP_COMMIT_NOC / CFG_NOC{MASK_LO,MASK_HI} : 1
//   OP_CFG_NOC{META}                                               : 1 + cfg-slave stalls
//   OP_EOP                                                         : 1 (then S_DONE forever)
//   OP_GEMM_ALL                                                    : 1 + K + 2
//                                                                    (K fire cycles + 2 drain + 1 snap)
//   OP_FFN_TLMM                                                    : 1 + driver-latency
//   OP_LD_*_URAM / OP_ST_OUT / OP_PINGPONG                         : 1 + mem_mgr-latency
//   OP_KV_WRITE / OP_KV_READ                                       : 1
//
// Forward-compat:
//   * N_NOC_SOURCES is a parameter; path_id_o is an unpacked array. Layer 3+
//     can widen without changing the ISA.
//   * tile_id[4:2] is reserved as a per-op NoC source selector (src_sel). In
//     Layer 2 the dispatcher asserts that src_sel == 0 on any CFG_NOC /
//     OP_GEMM_ALL; Layer 3+ lifts this by demuxing the noc_cfg master and by
//     driving the correct path_id_o[src_sel].
//
// Resource class:
//   LUTRAM imem + a handful of flops. No DSP. No BRAM. No URAM.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_DISPATCHER_SV
`define ARCHBETTER_DISPATCHER_SV
`default_nettype none
`timescale 1ns/1ps

module dispatcher
    import types_pkg::*;
#(
    parameter int unsigned IMEM_DEPTH    = 64,
    parameter int unsigned IMEM_ADDR_W   = $clog2(IMEM_DEPTH),
    parameter int unsigned N_NOC_SOURCES = 1
) (
    input  wire logic                         clk,
    input  wire logic                         rst_n,

    // Control.
    input  wire logic                         start,         // one-shot pulse or level-high
    output logic                              program_done,  // sticky once OP_EOP executed

    // Instruction memory write port (host / TB).
    input  wire logic                         imem_we,
    input  wire logic [IMEM_ADDR_W-1:0]       imem_wr_addr,
    input  wire logic [MACRO_WORD_W-1:0]      imem_wr_data,

    // NoC source -> path selector. Unpacked array, one entry per NoC source.
    // Layer 2 only drives entry 0; Layer 3 widens.
    output logic [NOC_PATH_ID_W-1:0]          path_id_o [N_NOC_SOURCES],

    // NoC path configuration master (Layer 2: single source).
    noc_cfg_if.master                         noc_cfg,

    // Compute-op issue sidebands.
    gemm_issue_if.disp                        gemm,
    tlmm_issue_if.disp                        tlmm,

    // Phase-8 dense layer-walk schedule + per-tile weight-load (OP_GEMM_LAYER).
    // The tile-walker drives the logical tile coordinate + lifecycle pulses to
    // the dense_array and the load_req/load_busy handshake to the dense weight
    // streamer; load_done returns here. Idle (all outputs low) for every other
    // opcode, including the single-tile OP_GEMM_ALL.
    dense_sched_if.walker                     sched,

    // Memory-op issue sideband (Layer 3). Carries start/opc/tile_id/is_sparse
    // to the Memory Manager; done returns on the same bus.
    mem_issue_if.disp                         mem_issue,

    // KV cache master port (Layer 3). kv_wr_data_i is a sideband that supplies
    // the 144-bit write payload - it does not fit in the 64-bit macro word, so
    // the instruction carries only the address and the TB / attention block
    // presents data via this port.
    kv_access_if.master                       kv,
    input  wire logic [KV_DATA_W-1:0]         kv_wr_data_i,

    // Dense output-collector drain back-pressure (C1.5). OP_BARRIER holds until
    // this is low, so a downstream consumer (e.g. ST_OUT) never reads the OUT
    // URAM while the collector is still draining a batch into it. Tie 0 where no
    // collector is present (the dispatcher-only testbenches).
    input  wire logic                         dense_drain_busy
);

    // -------------------------------------------------------------------------
    // Elaboration-time checks.
    // -------------------------------------------------------------------------
    initial begin : elab_checks
        if ($bits(macro_instr_t) != MACRO_WORD_W) begin
            $fatal(1, "dispatcher: macro_instr_t width %0d != MACRO_WORD_W %0d",
                   $bits(macro_instr_t), MACRO_WORD_W);
        end
        if (IMEM_ADDR_W != $clog2(IMEM_DEPTH)) begin
            $fatal(1, "dispatcher: IMEM_ADDR_W=%0d inconsistent with IMEM_DEPTH=%0d",
                   IMEM_ADDR_W, IMEM_DEPTH);
        end
        if (N_NOC_SOURCES < 1) begin
            $fatal(1, "dispatcher: N_NOC_SOURCES must be >= 1 (got %0d)", N_NOC_SOURCES);
        end
    end

    // -------------------------------------------------------------------------
    // Instruction memory: distributed LUTRAM. One write port (host), one
    // combinational read port (pc).
    // -------------------------------------------------------------------------
    (* ram_style = "distributed" *)
    logic [MACRO_WORD_W-1:0] imem [IMEM_DEPTH];

    always_ff @(posedge clk) begin
        if (imem_we) begin
            imem[imem_wr_addr] <= imem_wr_data;
        end
    end

    // -------------------------------------------------------------------------
    // Program counter and current-instruction view.
    // -------------------------------------------------------------------------
    logic [IMEM_ADDR_W-1:0] pc;

    // Individual field views, as raw bit vectors.
    //
    // Bit layout (MSB first, matches types_pkg::macro_instr_t):
    //   [63:58] opc, [57:50] tile_id, [49:42] path_id,
    //   [41:32] row_cnt, [31:22] col_cnt, [21:12] k_cnt, [11:0] flags.
    logic [MACRO_WORD_W-1:0] instr_raw;
    logic [MACRO_OPC_W-1:0]  instr_opc;
    logic [7:0]              instr_tile_id;
    logic [7:0]              instr_path_id;
    logic [MACRO_CNT_W-1:0]  instr_row_cnt;
    logic [MACRO_CNT_W-1:0]  instr_col_cnt;
    logic [MACRO_CNT_W-1:0]  instr_k_cnt;
    logic [1:0]              cfg_chunk;
    logic [2:0]              src_sel;

    assign instr_raw     = imem[pc];
    assign instr_opc     = instr_raw[63:58];
    assign instr_tile_id = instr_raw[57:50];
    assign instr_path_id = instr_raw[49:42];
    assign instr_row_cnt = instr_raw[41:32];   // OP_GEMM_LAYER row-tile extent
    assign instr_col_cnt = instr_raw[31:22];   // OP_GEMM_LAYER col-tile extent
    assign instr_k_cnt   = instr_raw[21:12];
    assign cfg_chunk     = instr_tile_id[1:0];
    assign src_sel       = instr_tile_id[4:2];

    // Phase-8 tile-walk geometry.
    localparam int unsigned TGR_W     = $clog2(DENSE_LOGICAL_TILE_ROWS);     // 3
    localparam int unsigned TGC_W     = $clog2(DENSE_LOGICAL_TILE_COLS);     // 2
    localparam int unsigned ROW_CNT_W = $clog2(DENSE_LOGICAL_TILE_ROWS + 1); // 4
    localparam int unsigned COL_CNT_W = $clog2(DENSE_LOGICAL_TILE_COLS + 1); // 3

    // -------------------------------------------------------------------------
    // FSM.
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE        = 4'd0,
        S_EXEC        = 4'd1,
        S_GEMM_ACC    = 4'd2,  // streaming: count beat_fire down to zero
        S_GEMM_DRAIN  = 4'd3,  // GEMM_DRAIN_CYCLES nop(s) for fused-MACC latency
        S_GEMM_SNAP   = 4'd4,  // pulse acc_snap (combinational), advance pc/tile
        S_FFN_WAIT    = 4'd5,  // wait for tlmm.done
        S_MEM_WAIT    = 4'd6,  // wait for mem_issue.done (LD / ST_OUT / PINGPONG)
        S_DONE        = 4'd7,
        S_LAYER_WLOAD = 4'd8,  // OP_GEMM_LAYER: wait for sched.load_done per tile
        S_BATCH_REARM = 4'd9,  // OP_GEMM_BATCH: 1-cycle busy drop between tokens
        S_GEMM_CONT   = 4'd10, // OP_GEMM_BATCH continuous (R6.4): stream T beats II=1
        S_GEMM_CFLUSH = 4'd11  // continuous tile flush: drain pipe before reload/done
    } disp_state_e;

    disp_state_e state;

    // -------------------------------------------------------------------------
    // CFG_NOC staging. One handle at a time: the program writes MASK_LO,
    // MASK_HI and META (any order) and META emits exactly one cfg handshake
    // carrying {mask_hi, mask_lo} + META fields.
    // -------------------------------------------------------------------------
    logic [31:0] stg_mask_lo;
    logic [31:0] stg_mask_hi;

    logic                          cfg_pending;
    logic [NOC_PATH_ID_W-1:0]      cfg_handle_r;
    noc_path_cfg_t                 cfg_cfg_r;

    // 1-cycle path_commit pulse.
    logic path_commit_r;

    // Sticky program_done.
    logic program_done_r;

    // -------------------------------------------------------------------------
    // NoC source path selection. Registered. Layer 2 only writes entry 0.
    // -------------------------------------------------------------------------
    logic [NOC_PATH_ID_W-1:0] path_id_r [N_NOC_SOURCES];

    // -------------------------------------------------------------------------
    // GEMM issue state.
    //   gemm_k_rem        : remaining beats expected (decrements on beat_fire)
    //   gemm_k_cnt_r      : snapshot of k_cnt for TB visibility on gemm.k_cnt
    //   gemm_first_done_r : has the first beat_fire been observed in this op?
    //   gemm_busy_r       : level high for the whole op
    // -------------------------------------------------------------------------
    logic [MACRO_CNT_W-1:0] gemm_k_rem;
    logic [MACRO_CNT_W-1:0] gemm_k_cnt_r;
    logic                   gemm_first_done_r;
    logic                   gemm_busy_r;

    // Fused-MACC (Phase-8b) drain length. The dense PE is now a 4-stage DSP48E2
    // MACC (AREG=2 + MREG + PREG, i.e. A1/A2/M/P), one cycle deeper than the
    // AREG=1 form, because the second input register (A1/B1) was added to clear
    // DPIP-2 and shorten the A/B setup path. The last product therefore reaches
    // the accumulator 4 cycles after its beat, so the post-stream drain is 3
    // cycles (was 2). Over-draining is benign (the P register holds once beats
    // stop); under-draining snaps a stale sum. $clog2 sizes the counter (now 2b).
    localparam int unsigned GEMM_DRAIN_CYCLES = 3;
    logic [$clog2(GEMM_DRAIN_CYCLES)-1:0] gemm_drain_cnt;

    // -------------------------------------------------------------------------
    // Phase-8 tile-walk state (OP_GEMM_LAYER). The walker wraps the existing
    // single-tile S_GEMM_ACC/DRAIN/SNAP body in a raster loop over the
    // gemm_row_cnt_r x gemm_col_cnt_r logical tile grid:
    //   for gr in 0..row-1: for gc in 0..col-1:
    //       weight-load(gr,gc)  ->  single-tile GEMM  ->  snap
    // gemm_is_layer_r distinguishes a layer op from a bare OP_GEMM_ALL so the
    // shared S_GEMM_SNAP either advances to the next tile or finishes the op.
    // -------------------------------------------------------------------------
    logic [TGR_W-1:0]     gemm_tile_gr_r;
    logic [TGC_W-1:0]     gemm_tile_gc_r;
    logic [ROW_CNT_W-1:0] gemm_row_cnt_r;     // layer row-tile count (1..8)
    logic [COL_CNT_W-1:0] gemm_col_cnt_r;     // layer col-tile count (1..4)
    logic                 gemm_is_layer_r;    // current GEMM op walks the tile grid
    logic                 layer_first_tile_r; // pending tile_first pulse (bank clear)
    logic                 load_req_r;         // 1-cycle weight-load request pulse
    logic                 load_busy_r;        // level high while a tile's weights load

    // C1.5 weight-resident batched GEMM (OP_GEMM_BATCH). gemm_is_batch_r adds an
    // inner token loop to the tile walk: each resident weight tile is reused
    // across gemm_batch_n_r tokens (gemm_tok_r indexes the current one) before
    // the tile is advanced + reloaded. OP_GEMM_LAYER sets gemm_is_batch_r=0,
    // batch_n=1 -> the loop degenerates to today's single-token-per-tile walk.
    logic                   gemm_is_batch_r;
    logic [BATCH_TOK_W-1:0] gemm_batch_n_r;   // token count T for this op (>=1)
    logic [BATCH_TOK_W-1:0] gemm_tok_r;       // current token index (0..T-1)

    // R6.4 continuous (v2) snap for OP_GEMM_BATCH (opt-in via FLG_GEMM_CONTINUOUS).
    // gemm_is_cont_r selects the S_GEMM_CONT/CFLUSH path (T beats II=1, per-cycle
    // tok_out bank RMW, no per-token drain/snap) over the v1 ACC/DRAIN/SNAP/REARM
    // path. The post-stream flush must cover the fused-MACC depth so in-flight
    // beats finish multiplying against THIS tile's weights before the next tile's
    // weight scan overwrites them; DENSE_CONT_RESULT_LAT (>= MACC depth) is safe
    // and also lets the final beat's bank RMW land.
    logic                   gemm_is_cont_r;
    localparam int unsigned GEMM_CONT_FLUSH = DENSE_CONT_RESULT_LAT;  // 6
    logic [$clog2(GEMM_CONT_FLUSH+1)-1:0] gemm_cflush_cnt;

    // Last tile of the layer in raster order.
    logic gemm_is_last_tile_c;
    assign gemm_is_last_tile_c =
        (gemm_tile_gr_r == TGR_W'(gemm_row_cnt_r - 1'b1)) &&
        (gemm_tile_gc_r == TGC_W'(gemm_col_cnt_r - 1'b1));

    // Last token of the current tile (always true when not batched).
    logic gemm_is_last_tok_c;
    assign gemm_is_last_tok_c =
        !gemm_is_batch_r || (gemm_tok_r == (gemm_batch_n_r - BATCH_TOK_W'(1)));

    // acc_clr and acc_snap are BOTH combinational from state:
    //   - acc_clr must co-fire with the first beat_fire on the same cycle
    //     (dense_group contract). Gating on !gemm_first_done_r guarantees it
    //     pulses exactly once per op.
    //   - acc_snap is the level decode of S_GEMM_SNAP. Keeping it combinational
    //     means busy and acc_snap can both be high on the same cycle (the
    //     dedicated S_GEMM_SNAP cycle), satisfying acc_snap |-> busy without
    //     needing a post-snap cleanup state.
    logic gemm_acc_clr_c;
    logic gemm_acc_snap_c;
    // PER_TOKEN (S_GEMM_ACC): acc_clr co-fires the FIRST beat only. CONTINUOUS
    // (S_GEMM_CONT): every beat is a fresh K=1 LOAD, so acc_clr co-fires EVERY
    // beat. Both forms satisfy acc_clr |-> beat_fire (gemm_issue_if contract).
    assign gemm_acc_clr_c  = ((state == S_GEMM_ACC)
                              && gemm.beat_fire
                              && !gemm_first_done_r)
                          ||  ((state == S_GEMM_CONT) && gemm.beat_fire);
    // acc_snap is PER_TOKEN only; CONTINUOUS never pulses it (the per-beat cell
    // valid drives the snap inside the array).
    assign gemm_acc_snap_c = (state == S_GEMM_SNAP);

    // -------------------------------------------------------------------------
    // TLMM issue state.
    // -------------------------------------------------------------------------
    logic [MACRO_CNT_W-1:0] tlmm_k_cnt_r;
    logic                   tlmm_start_r;
    logic                   tlmm_busy_r;

    // -------------------------------------------------------------------------
    // MEM issue state. mem_start_r is a 1-cycle pulse that co-rises with
    // mem_busy_r on the S_EXEC -> S_MEM_WAIT transition. The mem_issue_if
    // contract (a_start_requires_busy, p_start_pulse) is satisfied by this
    // single-edge pair.
    // -------------------------------------------------------------------------
    logic                   mem_start_r;
    logic                   mem_busy_r;
    macro_opc_e             mem_opc_r;
    logic [7:0]             mem_tile_id_r;
    logic                   mem_is_sparse_r;

    // -------------------------------------------------------------------------
    // KV port registers. All KV ops are 1-cycle from the dispatcher's POV:
    // pulse wr_en OR rd_en in the cycle after decode, advance pc. rd_valid
    // returns 1 cycle later via kv_access_if (interface contract); the
    // dispatcher does not block on it.
    // -------------------------------------------------------------------------
    logic                   kv_wr_en_r;
    logic                   kv_rd_en_r;
    logic [KV_ADDR_W-1:0]   kv_wr_addr_r;
    logic [KV_ADDR_W-1:0]   kv_rd_addr_r;
    logic [KV_DATA_W-1:0]   kv_wr_data_r;

    // -------------------------------------------------------------------------
    // Output drive.
    // -------------------------------------------------------------------------
    assign noc_cfg.handle      = cfg_handle_r;
    assign noc_cfg.cfg         = cfg_cfg_r;
    assign noc_cfg.cfg_valid   = cfg_pending;
    assign noc_cfg.path_commit = path_commit_r;
    assign program_done        = program_done_r;

    // path_id unpacked-array output.
    always_comb begin
        for (int s = 0; s < int'(N_NOC_SOURCES); s++) begin
            path_id_o[s] = path_id_r[s];
        end
    end

    // gemm_issue_if.disp drive. path_id / k_cnt surface the Layer-2 convention
    // that OP_GEMM_ALL always targets NoC source 0. Layer 3 lifts this.
    assign gemm.path_id  = path_id_r[0];
    assign gemm.k_cnt    = gemm_k_cnt_r;
    assign gemm.acc_clr  = gemm_acc_clr_c;
    assign gemm.acc_snap = gemm_acc_snap_c;
    assign gemm.busy     = gemm_busy_r;
    assign gemm.stream_mode = gemm_is_cont_r ? GEMM_SNAP_CONTINUOUS
                                             : GEMM_SNAP_PER_TOKEN;
    assign gemm.batch_n  = gemm_batch_n_r;   // R6.5: CONTINUOUS beat count = T

    // dense_sched_if.walker drive (Phase-8). tile_first co-fires with the FIRST
    // tile's acc_clr (clears the array bank); tile_last co-fires with the LAST
    // tile's acc_snap (drains y_out). Both are gated on gemm_is_layer_r so a
    // bare OP_GEMM_ALL leaves the whole bus idle.
    assign sched.tile_gr    = gemm_tile_gr_r;
    assign sched.tile_gc    = gemm_tile_gc_r;
    // tile_first (bank clear) = the FIRST beat of the FIRST tile of the op, in
    // BOTH modes: layer_first_tile_r is high only during tile 0, and
    // !gemm_first_done_r (cleared per tile in S_LAYER_WLOAD) selects that tile's
    // first beat. Independent of acc_clr so continuous (acc_clr every beat) still
    // pulses tile_first exactly once.
    assign sched.tile_first = gemm_is_layer_r && layer_first_tile_r
                            && gemm.beat_fire && !gemm_first_done_r;
    // tile_last (drain trigger) fires on the FINAL token of the FINAL tile.
    // PER_TOKEN: co-fires the final acc_snap. CONTINUOUS: co-fires the final beat
    // (there is no acc_snap), aligned by the array's last_pipe to the bank RMW.
    assign sched.tile_last  = gemm_is_layer_r && gemm_is_last_tile_c
                            && gemm_is_last_tok_c
                            && (gemm_is_cont_r
                                ? ((state == S_GEMM_CONT) && gemm.beat_fire)
                                : gemm_acc_snap_c);
    assign sched.load_req   = load_req_r;
    assign sched.load_busy  = load_busy_r;
    // C1.5 batched-GEMM sideband (driven by the token-loop walker below).
    assign sched.tile_tok   = gemm_tok_r;
    assign sched.batch_n    = gemm_batch_n_r;
    assign sched.stream_mode = gemm_is_cont_r ? GEMM_SNAP_CONTINUOUS
                                              : GEMM_SNAP_PER_TOKEN;

    // tlmm_issue_if.disp drive.
    assign tlmm.start = tlmm_start_r;
    assign tlmm.k_cnt = tlmm_k_cnt_r;
    assign tlmm.busy  = tlmm_busy_r;

    // mem_issue_if.disp drive.
    assign mem_issue.start     = mem_start_r;
    assign mem_issue.opc       = mem_opc_r;
    assign mem_issue.tile_id   = mem_tile_id_r;
    assign mem_issue.is_sparse = mem_is_sparse_r;
    assign mem_issue.busy      = mem_busy_r;

    // kv_access_if.master drive.
    assign kv.wr_en   = kv_wr_en_r;
    assign kv.wr_addr = kv_wr_addr_r;
    assign kv.wr_data = kv_wr_data_r;
    assign kv.rd_en   = kv_rd_en_r;
    assign kv.rd_addr = kv_rd_addr_r;

    // -------------------------------------------------------------------------
    // Sequential logic.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            pc                <= '0;
            stg_mask_lo       <= '0;
            stg_mask_hi       <= '0;
            cfg_pending       <= 1'b0;
            cfg_handle_r      <= '0;
            cfg_cfg_r         <= '0;
            path_commit_r     <= 1'b0;
            program_done_r    <= 1'b0;
            for (int s = 0; s < int'(N_NOC_SOURCES); s++) begin
                path_id_r[s]  <= '0;
            end
            gemm_k_rem        <= '0;
            gemm_k_cnt_r      <= '0;
            gemm_first_done_r <= 1'b0;
            gemm_busy_r       <= 1'b0;
            gemm_drain_cnt    <= '0;
            gemm_tile_gr_r     <= '0;
            gemm_tile_gc_r     <= '0;
            gemm_row_cnt_r     <= '0;
            gemm_col_cnt_r     <= '0;
            gemm_is_layer_r    <= 1'b0;
            gemm_is_batch_r    <= 1'b0;
            gemm_is_cont_r     <= 1'b0;
            gemm_cflush_cnt    <= '0;
            gemm_batch_n_r     <= BATCH_TOK_W'(1);
            gemm_tok_r         <= '0;
            layer_first_tile_r <= 1'b0;
            load_req_r         <= 1'b0;
            load_busy_r        <= 1'b0;
            tlmm_k_cnt_r      <= '0;
            tlmm_start_r      <= 1'b0;
            tlmm_busy_r       <= 1'b0;
            mem_start_r       <= 1'b0;
            mem_busy_r        <= 1'b0;
            mem_opc_r         <= OP_NOP;
            mem_tile_id_r     <= '0;
            mem_is_sparse_r   <= 1'b0;
            kv_wr_en_r        <= 1'b0;
            kv_rd_en_r        <= 1'b0;
            kv_wr_addr_r      <= '0;
            kv_rd_addr_r      <= '0;
            kv_wr_data_r      <= '0;
        end else begin
            // Default pulse-clears.
            path_commit_r <= 1'b0;
            tlmm_start_r  <= 1'b0;
            mem_start_r   <= 1'b0;
            kv_wr_en_r    <= 1'b0;
            kv_rd_en_r    <= 1'b0;
            load_req_r    <= 1'b0;

            unique case (state)
                // -------------------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        pc    <= '0;
                        state <= S_EXEC;
                    end
                end

                // -------------------------------------------------------------
                S_EXEC: begin
                    if (cfg_pending) begin
                        // Mid-handshake for CFG_NOC META.
                        if (noc_cfg.cfg_ready) begin
                            cfg_pending <= 1'b0;
                            pc          <= pc + 1'b1;
                        end
                    end else begin
                        unique case (instr_opc)
                            // ---- control ------------------------------------
                            OP_NOP: begin
                                pc <= pc + 1'b1;
                            end

                            OP_BARRIER: begin
                                // Dispatcher-side compute (GEMM/FFN) completes
                                // before pc advances, but the dense collector
                                // drains DOWNSTREAM and asynchronously. Hold the
                                // barrier until it is idle so a following ST_OUT
                                // reads a fully-written OUT URAM (C1.5 batched
                                // drain races ST_OUT otherwise).
                                if (!dense_drain_busy) pc <= pc + 1'b1;
                            end

                            OP_EOP: begin
                                program_done_r <= 1'b1;
                                state          <= S_DONE;
                            end

                            // ---- NoC path programming -----------------------
                            OP_CFG_NOC: begin
`ifndef SYNTHESIS
                                if (src_sel != 3'd0) begin
                                    $warning("dispatcher: CFG_NOC src_sel=%0d reserved in Layer 2 at pc=%0d",
                                             src_sel, pc);
                                end
`endif
                                unique case (cfg_chunk)
                                    CFG_NOC_MASK_LO: begin
                                        stg_mask_lo <= instr_raw[31:0];
                                        pc          <= pc + 1'b1;
                                    end
                                    CFG_NOC_MASK_HI: begin
                                        stg_mask_hi <= instr_raw[31:0];
                                        pc          <= pc + 1'b1;
                                    end
                                    CFG_NOC_META: begin
                                        cfg_handle_r           <= instr_path_id[NOC_PATH_ID_W-1:0];
                                        cfg_cfg_r.src_node     <= instr_raw[9:4];
                                        cfg_cfg_r.priority_lvl <= instr_raw[3:1];
                                        cfg_cfg_r.is_multicast <= instr_raw[0];
                                        cfg_cfg_r.dst_mask     <= {stg_mask_hi, stg_mask_lo};
                                        cfg_pending            <= 1'b1;
                                    end
                                    CFG_NOC_RSVD: begin
`ifndef SYNTHESIS
                                        $warning("dispatcher: CFG_NOC with reserved chunk selector at pc=%0d",
                                                 pc);
`endif
                                        pc <= pc + 1'b1;
                                    end
                                    default: pc <= pc + 1'b1;
                                endcase
                            end

                            OP_COMMIT_NOC: begin
                                path_commit_r <= 1'b1;
                                pc            <= pc + 1'b1;
                            end

                            // ---- compute-op issue ---------------------------
                            OP_GEMM_ALL: begin
`ifndef SYNTHESIS
                                if (src_sel != 3'd0) begin
                                    $warning("dispatcher: OP_GEMM_ALL src_sel=%0d reserved in Layer 2 at pc=%0d",
                                             src_sel, pc);
                                end
`endif
                                if (instr_k_cnt == '0) begin
`ifndef SYNTHESIS
                                    $warning("dispatcher: OP_GEMM_ALL k_cnt=0 at pc=%0d (skipped)", pc);
`endif
                                    // k_cnt=0 would deadlock S_GEMM_ACC. Skip.
                                    pc <= pc + 1'b1;
                                end else begin
                                    // Layer-2 convention: always NoC source 0.
                                    path_id_r[0]      <= instr_path_id[NOC_PATH_ID_W-1:0];
                                    gemm_k_rem        <= instr_k_cnt;
                                    gemm_k_cnt_r      <= instr_k_cnt;
                                    gemm_first_done_r <= 1'b0;
                                    gemm_is_cont_r    <= 1'b0;   // OP_GEMM_ALL = v1
                                    gemm_busy_r       <= 1'b1;
                                    state             <= S_GEMM_ACC;
                                end
                            end

                            // ---- Phase-8 full-layer GEMM (tile-walk) --------
                            OP_GEMM_LAYER: begin
                                if (instr_k_cnt == '0 || instr_row_cnt == '0
                                                      || instr_col_cnt == '0) begin
`ifndef SYNTHESIS
                                    $warning("dispatcher: OP_GEMM_LAYER zero extent (k=%0d r=%0d c=%0d) at pc=%0d (skipped)",
                                             instr_k_cnt, instr_row_cnt, instr_col_cnt, pc);
`endif
                                    pc <= pc + 1'b1;
                                end else begin
                                    path_id_r[0]       <= instr_path_id[NOC_PATH_ID_W-1:0];
                                    gemm_k_cnt_r       <= instr_k_cnt;            // beats per tile
                                    gemm_row_cnt_r     <= ROW_CNT_W'(instr_row_cnt);
                                    gemm_col_cnt_r     <= COL_CNT_W'(instr_col_cnt);
                                    gemm_tile_gr_r     <= '0;
                                    gemm_tile_gc_r     <= '0;
                                    gemm_is_layer_r    <= 1'b1;
                                    gemm_is_batch_r    <= 1'b0;          // single token/tile
                                    gemm_is_cont_r     <= 1'b0;          // OP_GEMM_LAYER = v1
                                    gemm_batch_n_r     <= BATCH_TOK_W'(1);
                                    gemm_tok_r         <= '0;
                                    layer_first_tile_r <= 1'b1;
                                    // Kick off tile (0,0)'s weight load.
                                    load_busy_r        <= 1'b1;
                                    load_req_r         <= 1'b1;   // 1-cycle (default-cleared)
                                    state              <= S_LAYER_WLOAD;
                                end
                            end

                            // ---- C1.5 weight-resident batched GEMM ----------
                            // Same tile walk as OP_GEMM_LAYER, but each resident
                            // weight tile is reused across T tokens (the tile_id
                            // field carries T; 0/1 both mean single-token). The
                            // 256-cycle weight load amortizes over the batch.
                            OP_GEMM_BATCH: begin
                                if (instr_k_cnt == '0 || instr_row_cnt == '0
                                                      || instr_col_cnt == '0) begin
`ifndef SYNTHESIS
                                    $warning("dispatcher: OP_GEMM_BATCH zero extent (k=%0d r=%0d c=%0d) at pc=%0d (skipped)",
                                             instr_k_cnt, instr_row_cnt, instr_col_cnt, pc);
`endif
                                    pc <= pc + 1'b1;
                                end else begin
                                    path_id_r[0]       <= instr_path_id[NOC_PATH_ID_W-1:0];
                                    gemm_k_cnt_r       <= instr_k_cnt;
                                    gemm_row_cnt_r     <= ROW_CNT_W'(instr_row_cnt);
                                    gemm_col_cnt_r     <= COL_CNT_W'(instr_col_cnt);
                                    gemm_tile_gr_r     <= '0;
                                    gemm_tile_gc_r     <= '0;
                                    gemm_is_layer_r    <= 1'b1;
                                    gemm_is_batch_r    <= 1'b1;
                                    // R6.4: opt-in continuous (v2) snap via flag bit.
                                    gemm_is_cont_r     <= instr_raw[FLG_GEMM_CONTINUOUS];
                                    // tile_id field = T; 0 -> 1 (decode-equivalent).
                                    gemm_batch_n_r     <= (instr_tile_id == 8'd0)
                                                        ? BATCH_TOK_W'(1)
                                                        : instr_tile_id[BATCH_TOK_W-1:0];
                                    gemm_tok_r         <= '0;
                                    layer_first_tile_r <= 1'b1;
                                    load_busy_r        <= 1'b1;
                                    load_req_r         <= 1'b1;
                                    state              <= S_LAYER_WLOAD;
                                end
                            end

                            OP_FFN_TLMM: begin
                                if (instr_k_cnt == '0) begin
`ifndef SYNTHESIS
                                    $warning("dispatcher: OP_FFN_TLMM k_cnt=0 at pc=%0d (skipped)", pc);
`endif
                                    pc <= pc + 1'b1;
                                end else begin
                                    tlmm_k_cnt_r <= instr_k_cnt;
                                    tlmm_start_r <= 1'b1;
                                    tlmm_busy_r  <= 1'b1;
                                    state        <= S_FFN_WAIT;
                                end
                            end

                            // ---- memory issue (Layer 3) ---------------------
                            // All four share one handshake: pulse start, hold
                            // busy, wait in S_MEM_WAIT for done.
                            OP_LD_W_URAM,
                            OP_LD_A_URAM,
                            OP_ST_OUT,
                            OP_PINGPONG: begin
                                mem_start_r     <= 1'b1;
                                mem_busy_r      <= 1'b1;
                                mem_opc_r       <= macro_opc_e'(instr_opc);
                                mem_tile_id_r   <= instr_tile_id;
                                mem_is_sparse_r <= instr_raw[FLG_IS_SPARSE];
                                state           <= S_MEM_WAIT;
                            end

                            // ---- KV cache (Layer 3) -------------------------
                            // KV address = { path_id[5:0], tile_id[7:0] } =
                            // 14 bits (= KV_ADDR_W). Write data is latched
                            // from the sideband port on the issue cycle.
                            OP_KV_WRITE: begin
                                kv_wr_en_r   <= 1'b1;
                                kv_wr_addr_r <= {instr_path_id[5:0], instr_tile_id};
                                kv_wr_data_r <= kv_wr_data_i;
                                pc           <= pc + 1'b1;
                            end

                            OP_KV_READ: begin
                                kv_rd_en_r   <= 1'b1;
                                kv_rd_addr_r <= {instr_path_id[5:0], instr_tile_id};
                                pc           <= pc + 1'b1;
                            end

                            // ---- truly unrecognized -------------------------
                            default: begin
`ifndef SYNTHESIS
                                $warning("dispatcher: unsupported opcode 0x%02h at pc=%0d (treated as NOP)",
                                         instr_opc, pc);
`endif
                                pc <= pc + 1'b1;
                            end
                        endcase
                    end
                end

                // -------------------------------------------------------------
                // OP_GEMM_LAYER: wait for this tile's weights to finish loading
                // into the PE register file. load_req self-cleared via the
                // default pulse-clear; load_busy is held here until load_done.
                // When the weights are in, start this tile's single-tile GEMM by
                // re-arming gemm_k_rem and raising gemm_busy (which the activation
                // streamer keys off to begin streaming this tile's beats).
                // -------------------------------------------------------------
                S_LAYER_WLOAD: begin
                    if (sched.load_done) begin
                        load_busy_r       <= 1'b0;
                        gemm_first_done_r <= 1'b0;
                        gemm_busy_r       <= 1'b1;
                        if (gemm_is_cont_r) begin
                            // CONTINUOUS: stream this tile's T tokens at II=1.
                            // gemm_tok_r was reset to 0 at op start / tile advance.
                            state         <= S_GEMM_CONT;
                        end else begin
                            gemm_k_rem    <= gemm_k_cnt_r;
                            state         <= S_GEMM_ACC;
                        end
                    end
                end

                // -------------------------------------------------------------
                S_GEMM_ACC: begin
                    if (gemm.beat_fire) begin
                        gemm_first_done_r <= 1'b1;
                        gemm_k_rem        <= gemm_k_rem - 1'b1;
                        if (gemm_k_rem == MACRO_CNT_W'(1)) begin
                            // Last beat just fired; arm the fused-MACC drain.
                            state          <= S_GEMM_DRAIN;
                            gemm_drain_cnt <= ($clog2(GEMM_DRAIN_CYCLES))'(GEMM_DRAIN_CYCLES - 1);
                        end
                    end
                end

                // -------------------------------------------------------------
                S_GEMM_DRAIN: begin
                    // Fused-MACC drain: GEMM_DRAIN_CYCLES cycles for the last
                    // cell product to reach the DSP P-register accumulator. No
                    // beat_fire, no acc_snap yet.
                    if (gemm_drain_cnt == '0) begin
                        state <= S_GEMM_SNAP;
                    end else begin
                        gemm_drain_cnt <= gemm_drain_cnt - 1'b1;
                    end
                end

                // -------------------------------------------------------------
                S_GEMM_SNAP: begin
                    // acc_snap is combinational from (state==S_GEMM_SNAP), so
                    // it is high THIS cycle while busy is still high. The busy
                    // drop and state exit below take effect on the next edge,
                    // by which time acc_snap is combinationally 0.
                    gemm_busy_r <= 1'b0;
                    if (gemm_is_layer_r) begin
                        // A tile just snapped (token gemm_tok_r). tile_first has
                        // already fired (on this op's first acc_clr), so retire it.
                        layer_first_tile_r <= 1'b0;
                        if (!gemm_is_last_tok_c) begin
                            // BATCHED: more tokens for THIS resident weight tile.
                            // Re-run the single-tile GEMM with the NEXT token's
                            // activations WITHOUT reloading weights. S_BATCH_REARM
                            // drops busy for one cycle so the activation streamer
                            // sees a fresh busy edge and restarts.
                            gemm_tok_r <= gemm_tok_r + BATCH_TOK_W'(1);
                            state      <= S_BATCH_REARM;
                        end else if (gemm_is_last_tile_c) begin
                            // Final token of final tile -> whole op done.
                            gemm_is_layer_r <= 1'b0;
                            gemm_is_batch_r <= 1'b0;
                            pc              <= pc + 1'b1;
                            state           <= S_EXEC;
                        end else begin
                            // Last token of this tile, tiles remain: advance the
                            // tile in raster order, reset token index, reload.
                            gemm_tok_r <= '0;
                            if (gemm_tile_gc_r == TGC_W'(gemm_col_cnt_r - 1'b1)) begin
                                gemm_tile_gc_r <= '0;
                                gemm_tile_gr_r <= gemm_tile_gr_r + 1'b1;
                            end else begin
                                gemm_tile_gc_r <= gemm_tile_gc_r + 1'b1;
                            end
                            load_busy_r <= 1'b1;
                            load_req_r  <= 1'b1;
                            state       <= S_LAYER_WLOAD;
                        end
                    end else begin
                        // Bare OP_GEMM_ALL: single tile, advance the program.
                        pc    <= pc + 1'b1;
                        state <= S_EXEC;
                    end
                end

                // -------------------------------------------------------------
                S_BATCH_REARM: begin
                    // One-cycle busy=0 gap (set in S_GEMM_SNAP) elapsed; re-arm
                    // the single-tile GEMM for the next token. Weights stay
                    // resident (no S_LAYER_WLOAD). acc_clr will re-fire on this
                    // token's first beat because gemm_first_done_r is cleared.
                    gemm_first_done_r <= 1'b0;
                    gemm_k_rem        <= gemm_k_cnt_r;
                    gemm_busy_r       <= 1'b1;
                    state             <= S_GEMM_ACC;
                end

                // -------------------------------------------------------------
                // R6.4 CONTINUOUS: stream this resident tile's T tokens back to
                // back, one beat per token, at II=1. acc_clr co-fires EVERY beat
                // (combinational), tile_tok = gemm_tok_r, tile_first on the very
                // first beat of the op, tile_last on the final tile's final beat.
                // No per-token drain/snap; the array's tok_out pipe routes each
                // beat's partial to bank[tok] DENSE_CONT_RESULT_LAT cycles later.
                // -------------------------------------------------------------
                S_GEMM_CONT: begin
                    if (gemm.beat_fire) begin
                        gemm_first_done_r <= 1'b1;  // arms tile_first one-shot
                        if (gemm_tok_r == (gemm_batch_n_r - BATCH_TOK_W'(1))) begin
                            // Final token's beat fired -> flush the MACC pipe
                            // before reload/done. Drop busy so no further beats.
                            gemm_busy_r     <= 1'b0;
                            gemm_cflush_cnt <= ($clog2(GEMM_CONT_FLUSH+1))'(GEMM_CONT_FLUSH);
                            state           <= S_GEMM_CFLUSH;
                        end else begin
                            gemm_tok_r <= gemm_tok_r + BATCH_TOK_W'(1);
                        end
                    end
                end

                // -------------------------------------------------------------
                // R6.4 CONTINUOUS tile flush: hold for GEMM_CONT_FLUSH cycles so
                // in-flight beats finish multiplying against THIS tile's resident
                // weights (and the final beat's bank RMW lands) before the next
                // tile's weight scan overwrites the PE registers. Then advance the
                // tile (reload) or finish the op. Mirrors the v1 DRAIN->SNAP
                // tile-advance bookkeeping.
                // -------------------------------------------------------------
                S_GEMM_CFLUSH: begin
                    layer_first_tile_r <= 1'b0;   // first tile done (idempotent)
                    if (gemm_cflush_cnt == '0) begin
                        if (gemm_is_last_tile_c) begin
                            // Final tile of the op -> done. The array's batched
                            // drain (kicked by the final tile_last) runs after.
                            gemm_is_layer_r <= 1'b0;
                            gemm_is_batch_r <= 1'b0;
                            gemm_is_cont_r  <= 1'b0;
                            pc              <= pc + 1'b1;
                            state           <= S_EXEC;
                        end else begin
                            // Advance the tile in raster order, reset the token
                            // index, reload this new tile's weights.
                            gemm_tok_r <= '0;
                            if (gemm_tile_gc_r == TGC_W'(gemm_col_cnt_r - 1'b1)) begin
                                gemm_tile_gc_r <= '0;
                                gemm_tile_gr_r <= gemm_tile_gr_r + 1'b1;
                            end else begin
                                gemm_tile_gc_r <= gemm_tile_gc_r + 1'b1;
                            end
                            load_busy_r <= 1'b1;
                            load_req_r  <= 1'b1;
                            state       <= S_LAYER_WLOAD;
                        end
                    end else begin
                        gemm_cflush_cnt <= gemm_cflush_cnt - 1'b1;
                    end
                end

                // -------------------------------------------------------------
                S_FFN_WAIT: begin
                    if (tlmm.done) begin
                        tlmm_busy_r <= 1'b0;
                        pc          <= pc + 1'b1;
                        state       <= S_EXEC;
                    end
                end

                // -------------------------------------------------------------
                S_MEM_WAIT: begin
                    // mem_start_r self-clears via the default pulse-clear at
                    // the top of this block, so it is high for exactly one
                    // cycle (the S_EXEC -> S_MEM_WAIT edge).
                    if (mem_issue.done) begin
                        mem_busy_r <= 1'b0;
                        pc         <= pc + 1'b1;
                        state      <= S_EXEC;
                    end
                end

                // -------------------------------------------------------------
                S_DONE: begin
                    // Halted. Stay here until reset.
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Simulation-only sanity checks.
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    // imem writes are only legal while the dispatcher is idle.
    property p_imem_write_only_idle;
        @(posedge clk) disable iff (!rst_n)
        imem_we |-> (state == S_IDLE);
    endproperty
    a_imem_write_only_idle: assert property (p_imem_write_only_idle)
        else $error("dispatcher: imem_we asserted while state != S_IDLE");

    // path_commit is a 1-cycle pulse.
    property p_commit_pulse;
        @(posedge clk) disable iff (!rst_n)
        path_commit_r |=> !path_commit_r;
    endproperty
    a_commit_pulse: assert property (p_commit_pulse)
        else $error("dispatcher: path_commit held high > 1 cycle");

    // We must never raise path_commit while a cfg handshake is pending.
    property p_no_commit_mid_cfg;
        @(posedge clk) disable iff (!rst_n)
        path_commit_r |-> !cfg_pending;
    endproperty
    a_no_commit_mid_cfg: assert property (p_no_commit_mid_cfg)
        else $error("dispatcher: path_commit pulsed while cfg_pending");

    // program_done is sticky.
    property p_program_done_sticky;
        @(posedge clk) disable iff (!rst_n)
        program_done_r |=> program_done_r;
    endproperty
    a_program_done_sticky: assert property (p_program_done_sticky)
        else $error("dispatcher: program_done dropped after being set");

    // In S_GEMM_ACC, beat_fire must never arrive after gemm_k_rem has hit
    // zero - the FSM moves to S_GEMM_SNAP on the cycle we count to zero, so a
    // further beat would mean the driver kept streaming past k_cnt.
    property p_no_overstream_in_gemm;
        @(posedge clk) disable iff (!rst_n)
        (state == S_GEMM_ACC && gemm.beat_fire) |-> (gemm_k_rem != '0);
    endproperty
    a_no_overstream_in_gemm: assert property (p_no_overstream_in_gemm)
        else $error("dispatcher: gemm driver asserted beat_fire after k_cnt beats were counted");

    // Drain / snap / continuous-flush cycles are beat-free by contract; a fire
    // there means the driver kept streaming past the tile's beat budget.
    property p_no_fire_in_gemm_tail;
        @(posedge clk) disable iff (!rst_n)
        (state == S_GEMM_DRAIN || state == S_GEMM_SNAP
         || state == S_GEMM_CFLUSH) |-> !gemm.beat_fire;
    endproperty
    a_no_fire_in_gemm_tail: assert property (p_no_fire_in_gemm_tail)
        else $error("dispatcher: beat_fire asserted during GEMM drain/snap/flush (driver kept streaming)");

    // Phase-8 tile-walk: a weight-load is only requested inside a layer op.
    a_load_req_in_layer: assert property (
        @(posedge clk) disable iff (!rst_n) load_req_r |-> gemm_is_layer_r
    ) else $error("dispatcher: sched.load_req asserted outside OP_GEMM_LAYER");

    // tile_first must co-fire with an acc_clr (array clears the bank on it).
    a_tile_first_with_clr: assert property (
        @(posedge clk) disable iff (!rst_n) sched.tile_first |-> gemm.acc_clr
    ) else $error("dispatcher: tile_first without acc_clr (array bank-clear contract)");

    // tile_last must co-fire with the array's drain trigger: an acc_snap in
    // PER_TOKEN, or the final beat's acc_clr in CONTINUOUS (R6.4; the array's
    // last_pipe aligns it to the bank RMW). No coverage loss vs the v1 form.
    a_tile_last_drive: assert property (
        @(posedge clk) disable iff (!rst_n)
        sched.tile_last |-> (gemm_is_cont_r ? gemm.acc_clr : gemm.acc_snap)
    ) else $error("dispatcher: tile_last without its mode's drain trigger (acc_snap PER_TOKEN / acc_clr CONTINUOUS)");
`endif

endmodule : dispatcher

`default_nettype wire
`endif // ARCHBETTER_DISPATCHER_SV
