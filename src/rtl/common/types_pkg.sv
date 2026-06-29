// -----------------------------------------------------------------------------
// types_pkg.sv
//
// Global types and parameters for the ArchBetter edge-LLM accelerator.
// Target: Xilinx Kintex UltraScale+ XCKU5P (xcku5p-ffvd900-3-e), Vivado 2025.2.
//
// This package is the single source of truth for:
//   * global geometry of the dense and sparse cores
//   * BFP12 block-floating-point data types
//   * ternary weight encoding for the sparse (TLMM) core
//   * macro-instruction ISA consumed by the dispatcher
//   * NoC circuit-switched path configuration types
//   * URAM ping-pong control types
//
// All RTL and testbench code must pull widths / opcodes / geometry from here.
// No magic numbers elsewhere.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_TYPES_PKG_SV
`define ARCHBETTER_TYPES_PKG_SV
`default_nettype none

package types_pkg;

    // -------------------------------------------------------------------------
    // 1. Global geometry of the compute fabric
    // -------------------------------------------------------------------------
    localparam int unsigned DENSE_ARRAY_ROWS   = 128;
    localparam int unsigned DENSE_ARRAY_COLS   = 128;
    localparam int unsigned DENSE_GROUP_ROWS   = 16;
    localparam int unsigned DENSE_GROUP_COLS   = 16;
    localparam int unsigned DENSE_GROUPS_ROW   = DENSE_ARRAY_ROWS / DENSE_GROUP_ROWS; //   8
    localparam int unsigned DENSE_GROUPS_COL   = DENSE_ARRAY_COLS / DENSE_GROUP_COLS; //   8
    localparam int unsigned DENSE_GROUPS_TOTAL = DENSE_GROUPS_ROW * DENSE_GROUPS_COL; //  64
    localparam int unsigned DENSE_PE_PER_GROUP = DENSE_GROUP_ROWS * DENSE_GROUP_COLS; // 256

    // -------------------------------------------------------------------------
    // Physical-vs-logical sizing (CLAUDE.md sec 2.2)
    //
    //   The dense_array kernel is PHYSICALLY 16 x 32 (two dense_group instances
    //   placed side-by-side in the column dimension). The logical 128 x 128
    //   matrix-vector throughput is achieved by time-multiplexing
    //   DENSE_LOGICAL_TILES_TOTAL (= 32) logical tiles through this kernel.
    //
    //   DSP budget at the current 2-DSP/PE inference rate:
    //     DENSE_PHYS_ROWS * DENSE_PHYS_COLS * 2 = 1024 / 1824  (= 56% of XCKU5P)
    //
    //   Phase-9 may scale to DENSE_PHYS_GROUPS_COL = 4 once the PE is fused to
    //   1 DSP/PE; the macro-ISA tile schedule absorbs the scaling without
    //   contract changes outside the dense_array harness.
    //
    //   IMPORTANT: do NOT re-introduce a generate-replicated 8x8 grid of
    //   dense_group instances. That was the cause of the 32k-DSP overrun the
    //   refactor fixes. CLAUDE.md sec 2.2 has the load-bearing version of this
    //   warning.
    // -------------------------------------------------------------------------
    localparam int unsigned DENSE_PHYS_GROUPS_ROW   = 1;
    localparam int unsigned DENSE_PHYS_GROUPS_COL   = 2;
    localparam int unsigned DENSE_PHYS_ROWS         = DENSE_GROUP_ROWS * DENSE_PHYS_GROUPS_ROW;        //  16
    localparam int unsigned DENSE_PHYS_COLS         = DENSE_GROUP_COLS * DENSE_PHYS_GROUPS_COL;        //  32
    localparam int unsigned DENSE_LOGICAL_TILE_ROWS = DENSE_ARRAY_ROWS / DENSE_PHYS_ROWS;              //   8
    localparam int unsigned DENSE_LOGICAL_TILE_COLS = DENSE_ARRAY_COLS / DENSE_PHYS_COLS;              //   4
    localparam int unsigned DENSE_LOGICAL_TILES_TOTAL = DENSE_LOGICAL_TILE_ROWS * DENSE_LOGICAL_TILE_COLS; // 32

    // UltraRAM ping-pong: banks 0,1 feed the Dense Core; banks 2,3 feed the Sparse Core.
    localparam int unsigned URAM_BANKS       = 4;
    localparam int unsigned URAM_WIDTH_BITS  = 72;    // native UltraRAM data width
    localparam int unsigned URAM_DEPTH       = 4096;  // 72b x 4K per UltraRAM primitive
    localparam int unsigned URAM_ADDR_W      = $clog2(URAM_DEPTH);

    // -------------------------------------------------------------------------
    // 2. BFP12 block-floating-point format
    //
    //   Per-element : signed 12-bit mantissa        (bfp12_mant_t)
    //   Per-block   : signed  8-bit shared exponent (bfp12_exp_t)
    //   Block size  : BFP12_BLK = 16 mantissas share one exponent
    //   Accumulator : signed 32-bit integer (DSP48E2 P-register), exponent-scaled
    //                 after full group reduction.
    //
    //   One PE multiply = 12b * 12b -> 24b, fits a single DSP48E2 (18 * 27).
    //   One group reduction = 16 * 16 = 256 MACs accumulated into one INT32.
    //   Group accumulation is STRICTLY LOCAL to the 16x16 group; only reduced
    //   INT32 leaves the group via the NoC.
    // -------------------------------------------------------------------------
    localparam int unsigned BFP12_MANT_W  = 12;
    localparam int unsigned BFP12_EXP_W   =  8;
    localparam int unsigned BFP12_BLK     = 16;
    localparam int unsigned DENSE_ACC_W   = 32;

    typedef logic signed [BFP12_MANT_W-1:0] bfp12_mant_t;
    typedef logic signed [BFP12_EXP_W-1:0]  bfp12_exp_t;
    typedef logic signed [DENSE_ACC_W-1:0]  dense_acc_t;

    // Per-cell signed mantissa product width: 12b * 12b -> 24b.
    // One CIM cell emits one bfp12_prod_t per activation beat; the PE/group
    // accumulates BFP12_BLK * BFP12_BLK = 256 of these into a dense_acc_t.
    localparam int unsigned BFP12_PROD_W = 2 * BFP12_MANT_W;
    typedef logic signed [BFP12_PROD_W-1:0] bfp12_prod_t;

    // Post-column-reduction width inside a dense group.
    // A group sums DENSE_GROUP_ROWS (=16) dense_acc_t values per column.
    // Bound to keep this from overflowing: K-per-snap <= 256 -> per-PE sum
    // magnitude <= 2^30, column sum magnitude <= 2^34. 40b signed is safe
    // with headroom; do not narrow without re-doing the K bound.
    localparam int unsigned GROUP_ACC_W = 40;
    typedef logic signed [GROUP_ACC_W-1:0] group_acc_t;

    // Post-array-reduction width. The dense_array sums DENSE_GROUPS_ROW (=8)
    // group_acc_t values per global output column, so add log2(8)=3 bits of
    // headroom. 43 bits is the minimum; we round up to 44 for a cleaner byte
    // boundary at no meaningful cost.
    localparam int unsigned ARRAY_ACC_W = 44;
    typedef logic signed [ARRAY_ACC_W-1:0] array_acc_t;

    // -------------------------------------------------------------------------
    // 2b. Dense-core snap mode + result-latency contract  (R6 / v2)
    //
    //   v1 (decode + small-batch prefill) snaps one token's reduction per tile
    //   with a 3-cycle drain and a single acc_snap pulse spaced far apart — the
    //   per-token drain caps prefill DSP utilization at ~12.5%. v2 (large-T
    //   prefill, the compute-bound regime) streams T token-beats back-to-back at
    //   II=1 with acc_clr=1 on EVERY beat (each beat is a fresh K=1 LOAD), and a
    //   complete 16-wide column partial falls out of the pipe every cycle. The
    //   per-cycle bank read-modify-write must target the token whose beat entered
    //   the pipe DENSE_CONT_RESULT_LAT cycles earlier (the tok_out alignment —
    //   the single highest-risk number in R6, validated bit-exact at R6.3).
    //
    //   This is a CONTRACT only (types/params). No datapath consumes it until the
    //   mode-gated continuous path lands (R6.2 pe/group, R6.3 array, R6.4 disp).
    //   The interface sidebands that carry stream_mode / tok_out are added in the
    //   same stage as their drivers so every intermediate build stays
    //   elaboration-clean (no undriven modport nets) — a refinement of the §13
    //   "R6.1 = types+interfaces" grouping in service of the zero-warning bar.
    // -------------------------------------------------------------------------
    typedef enum logic {
        GEMM_SNAP_PER_TOKEN = 1'b0,  // v1: drain + single acc_snap per token
        GEMM_SNAP_CONTINUOUS = 1'b1  // v2: II=1, per-cycle snap, tok_out RMW
    } gemm_stream_mode_e;

    // Fused-MACC latency: a_valid -> cim_cell acc_valid, asserted exact (##4) in
    // cim_cell_4t2r (AREG=2/BREG=2/MREG/PREG). GEMM_DRAIN_CYCLES (=3) = LAT-1.
    localparam int unsigned DENSE_MACC_LAT      = 4;
    // Output-register stages the continuous partial traverses after the cell:
    //   dense_pe samples cell_acc on cell_acc_valid (+1), dense_group registers
    //   the column-reduction into y_out (+1).
    localparam int unsigned DENSE_PE_SNAP_REGS  = 1;
    localparam int unsigned DENSE_GROUP_OUT_REGS = 1;
    // Cycles from a_fire (beat enters the array) to bank_update_now (the coherent
    // gp_y_valid for that beat). The dense_array tile_tok shift-register depth.
    //   a_fire(t) -> acc_valid(t+4) -> pe snap(t+5) -> group y_valid(t+6).
    localparam int unsigned DENSE_CONT_RESULT_LAT =
        DENSE_MACC_LAT + DENSE_PE_SNAP_REGS + DENSE_GROUP_OUT_REGS;  // = 6

    // (tok_idx_t — the named token-index type — is declared with BATCH_TOK_W in
    //  the macro-ISA section below, since it depends on that width.)

    // A BFP12 block: BFP12_BLK mantissas + one shared exponent.
    typedef struct packed {
        bfp12_exp_t                  shared_exp;
        bfp12_mant_t [BFP12_BLK-1:0] mant;
    } bfp12_block_t;

    // Convenience width: flat payload of one block on a stream wire.
    localparam int unsigned BFP12_BLOCK_W = BFP12_EXP_W + BFP12_BLK * BFP12_MANT_W; // 8+192 = 200

    // -------------------------------------------------------------------------
    // R6.8b — wide dense ping-pong URAM read (serves BOTH the weight scan and the
    // activation stream, which share the dense pp through one cascade port).
    //
    // The fetch floor is how many native 72b URAM reads a beat costs. Today a
    // block is stored as 4 native words (2 cascade words x 2 natives) = 288 b, and
    // read serially → II=4. Placing DENSE_PP_URAM_WIDE = 4 URAM288 leaves
    // side-by-side at the same address returns all 4 natives in ONE cycle → II=1.
    //
    // The wide word is a TRANSPARENT N-native container: leaf l holds the native
    // at wide-word offset l, i.e. wide_word[l*72 +: 72] = native[wide_addr*4 + l].
    // It carries the existing 4-native-per-block layout verbatim (the {hi,lo}
    // cascade pair), so NO DRAM-image / golden re-layout is needed — the fill just
    // groups every 4 contiguous natives into one wide word, and the streamer slices
    // the block out of the 288 b exactly as it sliced the two cascade words before.
    // WIDE=4 (vs the tighter 216 b WIDE=3) keeps the existing layout and gives
    // power-of-2 leaf addressing (leaf = native_addr[1:0]); see design doc §14.8.
    localparam int unsigned DENSE_PP_URAM_WIDE = 4;
    localparam int unsigned DENSE_PP_URAM_W    = DENSE_PP_URAM_WIDE * URAM_WIDTH_BITS; // 288
    localparam int unsigned DENSE_PP_LEAF_SEL_W = $clog2(DENSE_PP_URAM_WIDE);          // 2

    // -------------------------------------------------------------------------
    // 3. Ternary weight format for the Sparse Core (TLMM)
    //
    //   Encoding : 2'b01 = +1,  2'b00 = 0,  2'b11 = -1,  2'b10 = reserved.
    //
    //   TLMM is activation-stationary with a HIERARCHICAL subset-sum table.
    //   A full tile of TLMM_TILE activations is subdivided into
    //   TLMM_SUBTABLES_PER_TILE sub-tiles of TLMM_SUBTILE activations each.
    //   Each sub-tile owns one LUTRAM table of depth 2^TLMM_SUBTILE whose
    //   entries are the signed sum of the subset of activations selected by
    //   the binary address: entry[m] = sum_{i : m[i]=1} a[i].
    //
    //   Compute flow for one output neuron's partial over one tile:
    //     for each of TLMM_SUBTABLES_PER_TILE sub-tiles:
    //         pos_mask = bits where w_i = +1
    //         neg_mask = bits where w_i = -1
    //         sub_partial = T[pos_mask] - T[neg_mask]
    //     tile_partial = sum of sub_partials           (4-way adder tree)
    //
    //   Whole-layer accumulation across K/TLMM_TILE tiles happens outside the
    //   tile module, in an INT32 neuron-accumulator (tlmm_acc_t).
    //
    //   Cost sanity (one lane, one sub-tile):
    //     16 entries x 14 bits = 224 bits of distributed LUTRAM, ~8 LUT6s.
    //   Per-tile, per-lane: 4 sub-tables => ~32 LUT6s of LUTRAM.
    //   TLMM_LANES=16 output neurons in parallel => ~512 LUT6s of LUTRAM.
    //
    //   Zero DSP48E2 usage. All sums happen in LUT-built adders, with
    //   (* use_dsp = "no" *) enforced on the sparse-core adder trees.
    // -------------------------------------------------------------------------
    localparam int unsigned TLMM_TILE              = 16;
    localparam int unsigned TLMM_SUBTILE           = 4;
    localparam int unsigned TLMM_SUBTABLES_PER_TILE = TLMM_TILE / TLMM_SUBTILE;   // 4
    localparam int unsigned TLMM_SUBTABLE_ADDR_W   = TLMM_SUBTILE;                // 4
    localparam int unsigned TLMM_SUBTABLE_DEPTH    = (1 << TLMM_SUBTABLE_ADDR_W); // 16

    // Entry width: signed sum of up to TLMM_SUBTILE BFP12 mantissas.
    //   max magnitude = TLMM_SUBTILE * (2^(BFP12_MANT_W-1) - 1)
    //   width        = BFP12_MANT_W + $clog2(TLMM_SUBTILE)
    //                = 12 + 2 = 14 bits (signed).
    localparam int unsigned TLMM_SUB_ENTRY_W = BFP12_MANT_W + $clog2(TLMM_SUBTILE); // 14

    // Post-subtract width (T[+mask] - T[-mask]) grows by 1 bit.
    localparam int unsigned TLMM_SUB_PART_W  = TLMM_SUB_ENTRY_W + 1;  // 15

    // Tile-partial width: sum of TLMM_SUBTABLES_PER_TILE sub_partials.
    localparam int unsigned TLMM_TILE_PART_W = TLMM_SUB_PART_W + $clog2(TLMM_SUBTABLES_PER_TILE); // 17

    // Neuron accumulator width for whole-layer K-reduction. Keep it INT32 for
    // parity with the dense accumulator and headroom against deep layers.
    localparam int unsigned TLMM_ACC_W = 32;

    // Number of output-neuron lanes computed in parallel per sparse tile module.
    // Each lane owns a private replica of the subset-sum tables (cheap in LUTRAM).
    localparam int unsigned TLMM_LANES = 16;

    typedef enum logic [1:0] {
        TERN_ZERO = 2'b00,
        TERN_POS  = 2'b01,
        TERN_NEG  = 2'b11,
        TERN_RSVD = 2'b10
    } tern_weight_e;

    // One full tile's worth of ternary weights for one output neuron.
    typedef tern_weight_e [TLMM_TILE-1:0]    tern_tile_t;
    // One sub-tile's worth of ternary weights.
    typedef tern_weight_e [TLMM_SUBTILE-1:0] tern_subtile_t;

    // Per-sub-table entry (signed).
    typedef logic signed [TLMM_SUB_ENTRY_W-1:0] tlmm_sub_entry_t;
    // Post-subtract sub-tile partial (signed).
    typedef logic signed [TLMM_SUB_PART_W-1:0]  tlmm_sub_part_t;
    // Tile-level partial output (signed).
    typedef logic signed [TLMM_TILE_PART_W-1:0] tlmm_tile_part_t;
    // Whole-layer neuron accumulator (signed).
    typedef logic signed [TLMM_ACC_W-1:0]       tlmm_acc_t;

    // A sub-tile's worth of stationary activations (BFP12 mantissas).
    typedef bfp12_mant_t [TLMM_SUBTILE-1:0] tlmm_subtile_act_t;
    // A full tile's worth of stationary activations.
    typedef bfp12_mant_t [TLMM_TILE-1:0]    tlmm_tile_act_t;

    // One TLMM weight beat: ternary weights for TLMM_LANES parallel output
    // neurons, each neuron getting TLMM_TILE ternary weights per beat.
    //   Width = TLMM_LANES * TLMM_TILE * 2 = 16 * 16 * 2 = 512 bits.
    typedef tern_tile_t [TLMM_LANES-1:0] tern_lane_tiles_t;

    // One TLMM tile-partial output beat: one tile_partial per parallel lane.
    // The tile module is a pure (activations, weights) -> tile_partials
    // evaluator; whole-layer K-reduction across K/TLMM_TILE tiles is the job of
    // a separate neuron-accumulator module (it uses tlmm_acc_t above).
    //   Width = TLMM_LANES * TLMM_TILE_PART_W = 16 * 17 = 272 bits.
    typedef tlmm_tile_part_t [TLMM_LANES-1:0] tlmm_part_vec_t;

    // Whole-layer neuron accumulator bank: one INT32 K-reduction accumulator per
    // parallel output-neuron lane. This is what the tlmm_driver folds tile
    // partials into across an op, and what the sparse_out_collector drains to the
    // OUTPUT URAM on tlmm.done (the sparse analogue of the dense array_acc_t bank).
    //   Width = TLMM_LANES * TLMM_ACC_W = 16 * 32 = 512 bits.
    typedef tlmm_acc_t [TLMM_LANES-1:0] tlmm_acc_vec_t;

    // -------------------------------------------------------------------------
    // 4. Macro-instruction ISA for the Dispatcher (FlightLLM-style)
    //
    //   One 64-bit macro-instruction per layer-step. The dispatcher fans out
    //   sub-ops to the NoC configurator, Memory Manager, Dense Core, Sparse
    //   Core, and the KV cache controller. Asymmetric pipelining is achieved
    //   by interleaving issue slots across cores.
    // -------------------------------------------------------------------------
    localparam int unsigned MACRO_OPC_W  =  6;
    localparam int unsigned MACRO_WORD_W = 64;

    // Width of the row/col/k counters carried by macro_instr_t. The struct
    // below hard-encodes [9:0] for bit-layout stability; downstream consumers
    // (dispatcher issue FSMs, gemm_issue_if, tlmm_issue_if) must use this
    // parameter so that a future ISA widening only touches the struct.
    localparam int unsigned MACRO_CNT_W  = 10;

    // Weight-resident batched GEMM (C1.5). For OP_GEMM_BATCH the macro's tile_id
    // field carries the batch token count T (number of activation vectors streamed
    // through each resident weight tile before the tile is retired). T = 0 or 1
    // both mean a single token (decode-equivalent). BATCH_TOK_W bounds the encoded
    // T and sizes the dense_sched_if token-index sideband.
    localparam int unsigned BATCH_TOK_W = 8;   // encodable T in [1 .. 255]

    // Named token-index type for batched-GEMM tile_tok / tok_out sidebands (R6).
    // Declared here (not in the dense-core section) because it depends on
    // BATCH_TOK_W; used by the dense_sched_if sideband and the v2 tok_out pipe.
    typedef logic [BATCH_TOK_W-1:0] tok_idx_t;

    typedef enum logic [MACRO_OPC_W-1:0] {
        // No-op / control
        OP_NOP         = 6'h00,
        OP_BARRIER     = 6'h01,  // drain + sync all cores
        OP_EOP         = 6'h02,  // end of program

        // NoC path programming (must precede any streaming op using the path)
        OP_CFG_NOC     = 6'h08,
        OP_COMMIT_NOC  = 6'h09,  // freeze committed paths, enter streaming mode

        // Memory / ping-pong
        OP_LD_W_URAM   = 6'h10,  // DRAM -> URAM weight tile via CSD engine
        OP_LD_A_URAM   = 6'h11,  // DRAM -> URAM activation tile
        OP_ST_OUT      = 6'h12,  // URAM -> DRAM output drain
        OP_PINGPONG    = 6'h13,  // flip compute/fill banks (after drain handshake)

        // Dense compute
        OP_GEMM_DENSE  = 6'h20,  // dense BFP12 GEMM on one group tile
        OP_GEMM_ALL    = 6'h21,  // one logical tile's reduction (inner primitive)
        OP_GEMM_LAYER  = 6'h22,  // Phase-8: full-layer GEMM. The dispatcher
                                 // tile-walker iterates the
                                 // DENSE_LOGICAL_TILE_ROWS x DENSE_LOGICAL_TILE_COLS
                                 // grid, loading per-tile weights (dense_sched_if)
                                 // and accumulating the persistent array bank.
                                 // row_cnt/col_cnt carry the grid extents; k_cnt
                                 // is beats-per-tile. OP_GEMM_ALL is its inner
                                 // single-tile body, retained for back-compat.
        OP_GEMM_BATCH  = 6'h23,  // C1.5: weight-resident batched GEMM. Same tile
                                 // walk as OP_GEMM_LAYER, but each resident weight
                                 // tile is reused across T tokens (tile_id field =
                                 // T) before reload, so the 256-cycle weight load
                                 // amortizes over the batch (prefill). T tokens
                                 // produce T independent 128-wide outputs.

        // Sparse compute
        OP_FFN_TLMM    = 6'h28,  // sparse ternary FFN step

        // Elementwise / nonlinear
        OP_ACT_NL      = 6'h30,  // GELU / SiLU / ReLU etc.
        OP_LAYERNORM   = 6'h31,
        OP_SOFTMAX     = 6'h32,

        // KV cache (global BRAM)
        OP_KV_WRITE    = 6'h38,
        OP_KV_READ     = 6'h39
    } macro_opc_e;

    // 64-bit macro-instruction layout. Bit-exact by design; dispatcher reads
    // the struct-packed form directly from the instruction memory.
    //   opc      (6)
    //   tile_id  (8)   -- selects weight/activation tile within current layer
    //   path_id  (8)   -- NoC path handle, pre-committed via OP_CFG_NOC
    //   row_cnt (10)   -- GEMM M tile count
    //   col_cnt (10)   -- GEMM N tile count
    //   k_cnt   (10)   -- GEMM K tile count
    //   flags   (12)   -- barrier, bank sel, priority, quant-control bits
    // Total: 6+8+8+10+10+10+12 = 64.
    typedef struct packed {
        macro_opc_e  opc;
        logic [7:0]  tile_id;
        logic [7:0]  path_id;
        logic [9:0]  row_cnt;
        logic [9:0]  col_cnt;
        logic [9:0]  k_cnt;
        logic [11:0] flags;
    } macro_instr_t;

    // Compile-time width check; fires at elaboration if the struct drifts.
    // (Use inside any consumer module as:
    //   `ARCHBETTER_STATIC_ASSERT($bits(types_pkg::macro_instr_t) == types_pkg::MACRO_WORD_W) )
    `define ARCHBETTER_STATIC_ASSERT(cond) \
        generate if (!(cond)) begin : static_assert_fail \
            $error("static assertion failed: ", `"cond`"); \
        end endgenerate

    // Flag bit positions (named constants, keep in sync with flags width above).
    localparam int unsigned FLG_BANK_SEL_LSB = 0;   // 1 bit
    localparam int unsigned FLG_BARRIER      = 1;   // 1 bit
    localparam int unsigned FLG_PRIORITY_LSB = 2;   // 3 bits
    localparam int unsigned FLG_QUANT_LSB    = 5;   // 3 bits
    // Memory-pool selector for OP_LD_*_URAM / OP_ST_OUT / OP_PINGPONG. 0 = dense
    // pool (banks 0/1), 1 = sparse pool (banks 2/3). Allocated from what was
    // previously the reserved range [11:8]; the top 3 bits [11:9] stay reserved.
    localparam int unsigned FLG_IS_SPARSE    = 8;   // 1 bit
    // R6.4: opt-in continuous (v2) snap for OP_GEMM_BATCH. When set, each resident
    // weight tile streams its T tokens at II=1 with per-cycle tok_out bank RMW
    // (no per-token drain/snap); when clear, OP_GEMM_BATCH keeps the v1 per-token
    // path bit-identical. Allocated from the previously-reserved [11:9] range.
    localparam int unsigned FLG_GEMM_CONTINUOUS = 9;   // 1 bit
    localparam int unsigned FLG_RSVD_LSB     = 10;  // 2 bits reserved [11:10]

    // -------------------------------------------------------------------------
    // 5. Circuit-switched NoC configuration (Blackwell B200-style)
    //
    //   Paths are committed by OP_CFG_NOC + OP_COMMIT_NOC BEFORE streaming.
    //   During execution, routers are pure muxes: no arbitration, no tables.
    // -------------------------------------------------------------------------
    localparam int unsigned NOC_NODES        = 64;   // one per dense group; sidecars alias
    localparam int unsigned NOC_NODE_ID_W    = $clog2(NOC_NODES);
    localparam int unsigned NOC_PATH_HANDLES = 32;   // number of simultaneously-live paths
    localparam int unsigned NOC_PATH_ID_W    = $clog2(NOC_PATH_HANDLES);

    // Stream payload: one BFP12 activation block per beat = 16 mantissas = 192 b.
    localparam int unsigned NOC_DATA_W = BFP12_BLK * BFP12_MANT_W; // 192
    localparam int unsigned NOC_USER_W = 8;

    // Hard-wired multicast mask: one bit per destination node.
    typedef logic [NOC_NODES-1:0] noc_mask_t;

    typedef struct packed {
        logic [NOC_NODE_ID_W-1:0] src_node;
        noc_mask_t                dst_mask;     // multicast destinations
        logic [2:0]               priority_lvl; // 0 = bulk, 7 = critical
        logic                     is_multicast; // 0 = single dst, 1 = multicast set
    } noc_path_cfg_t;

    // One noc_path_cfg_t is 74 bits (NOC_NODE_ID_W + NOC_NODES + 3 + 1), which
    // does not fit in a 64-bit macro_instr_t payload. OP_CFG_NOC therefore
    // programs a path via THREE sequential macro-ops, each carrying one chunk
    // of the full path config. The chunk selector lives in tile_id[1:0], the
    // handle lives in path_id[NOC_PATH_ID_W-1:0], and the chunk payload is
    // packed into the lower 32 bits of the instruction word:
    //   MASK_LO  : instr[31:0]  = dst_mask[31:0]
    //   MASK_HI  : instr[31:0]  = dst_mask[63:32]
    //   META     : instr[9:0]   = { src_node[5:0], priority_lvl[2:0], is_multicast }
    // The dispatcher accumulates chunks in a staging register and issues the
    // noc_cfg handshake only on META (so exactly one cfg write per path). The
    // program must write MASK_LO, MASK_HI, META in any order but all three
    // for each handle before OP_COMMIT_NOC.
    typedef enum logic [1:0] {
        CFG_NOC_MASK_LO = 2'b00,
        CFG_NOC_MASK_HI = 2'b01,
        CFG_NOC_META    = 2'b10,
        CFG_NOC_RSVD    = 2'b11
    } cfg_noc_chunk_e;

    // -------------------------------------------------------------------------
    // 6. URAM ping-pong control
    // -------------------------------------------------------------------------
    typedef enum logic {
        BANK_A = 1'b0,
        BANK_B = 1'b1
    } bank_sel_e;

    typedef struct packed {
        bank_sel_e compute_side;  // bank currently presented to the compute core
        bank_sel_e fill_side;     // bank currently being refilled from DRAM
        logic      fill_done;     // CSD engine has finished refilling fill_side
        logic      swap_pending;  // dispatcher requested a swap; waiting for drain_ack
    } pingpong_state_t;

    // -------------------------------------------------------------------------
    // 7. Off-chip DRAM stub + CSD descriptor
    //
    //   csd_dram_if carries a fire-and-forget read request (base + length) and
    //   returns a beat stream. One beat = one URAM word (72 b) so the CSD
    //   engine's write path into URAM is a straight pipe in the pass-through
    //   case. When a real compressor lands (Phase 2.5), the payload stays 72 b
    //   but the beats carry encoded tokens and the engine expands them before
    //   committing to URAM.
    //
    //   csd_descriptor_t is the per-tile fill spec produced by the dispatcher /
    //   Memory Manager from OP_LD_W_URAM / OP_LD_A_URAM. It does NOT pick the
    //   destination bank: the Memory Manager routes to whichever side of the
    //   selected pool (dense or sparse) is currently the fill side.
    // -------------------------------------------------------------------------
    localparam int unsigned DRAM_ADDR_W = 32;
    localparam int unsigned DRAM_BEAT_W = URAM_WIDTH_BITS;  // 72 b: 1 DRAM beat = 1 URAM word
    localparam int unsigned DRAM_LEN_W  = 16;               // up to 64K beats per descriptor

    typedef struct packed {
        logic                    compressed;  // 0 = raw 72b beats; 1 = RLE (Phase 2.5)
        logic                    is_sparse;   // 0 = dense pool, 1 = sparse pool
        logic [URAM_ADDR_W-1:0]  uram_base;   // URAM write base (within fill-side bank)
        logic [DRAM_ADDR_W-1:0]  dram_base;   // DRAM read base
        logic [DRAM_LEN_W-1:0]   n_beats;     // number of DRAM beats
    } csd_descriptor_t;

    // -------------------------------------------------------------------------
    // 7b. Phase-8 per-layer execution descriptor (OP_GEMM_LAYER)
    //
    //   Internalizes the per-layer URAM base addresses that the Phase-7 harness
    //   top exposed as host ports (dense_act_base_addr / tlmm_base_addr /
    //   out_collector_base_addr). The dispatcher tile-walker reads one of these
    //   from a small layer-descriptor table and hands the bases to the
    //   activation streamer, TLMM driver, and output collector — so the closed
    //   top no longer needs those ports (the dangling inputs OOC was pruning).
    //
    //   Tile-grid extents (row_cnt/col_cnt) and beats-per-tile (k_cnt) ride the
    //   macro instruction, NOT this struct. Consumed in Stage 8e (closed top);
    //   the table that holds it is added alongside.
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic [URAM_ADDR_W-1:0] dense_act_base;  // dense_act_streamer read base
        logic [URAM_ADDR_W-1:0] tlmm_base;       // tlmm_driver read base
        logic [URAM_ADDR_W-1:0] out_base;        // dense_out_collector write base
    } layer_desc_t;

    // -------------------------------------------------------------------------
    // 8. KV cache (global BRAM)
    //
    //   Distinct from URAM: URAM is reserved for weights/activations, BRAM
    //   carries KV. One entry = KV_DATA_W bits (two cascaded BRAM18 primitives
    //   = 144 b, matching the natural BFP12 activation half-block width of
    //   8 * 12 = 96 b with 48 b spare for metadata/exponent).
    //
    //   KV_DEPTH is picked so that 16K entries x 144 b fit in ~64 BRAM18Es,
    //   well within the XCKU5P 480-BRAM36 budget.
    // -------------------------------------------------------------------------
    localparam int unsigned KV_DATA_W = 144;
    localparam int unsigned KV_DEPTH  = 16384;
    localparam int unsigned KV_ADDR_W = $clog2(KV_DEPTH);  // 14

endpackage : types_pkg

`default_nettype wire
`endif // ARCHBETTER_TYPES_PKG_SV
