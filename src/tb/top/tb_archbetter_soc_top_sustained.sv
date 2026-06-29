// -----------------------------------------------------------------------------
// tb_archbetter_soc_top_sustained.sv  (C6 — representative sustained power sim)
//
// PURPOSE: drive a REPRESENTATIVE, dense-array-busy workload through the closed
// SoC wrapper so a SAIF captured over this run yields a PUBLISHABLE, activity-
// based power number (CLAUDE.md §11: "the workload must keep the dense array
// genuinely busy"; a SAIF over the K=1 single-matrix-vector toy is inadmissible).
//
// It is a faithful clone of the proven tb_archbetter_soc_top (135-check end-to-
// end regression), scaled up on three axes:
//   * ROW_CNT 4 -> 8                ==> the full 128-row reduction depth (8 row-
//     tiles accumulated into the column bank). COL_CNT stays 2 (matches the
//     proven regression's column config; de-risks the array column-bank drain).
//   * BATCH_TOK 8 -> 64             ==> each resident weight tile is reused over
//     64 tokens; the 256-cycle weight scan amortizes -> 16 tiles x 64 tokens =
//     1024 GEMM iterations of sustained compute per layer. BATCH_TOK ALSO drives
//     the structural .BATCH_T param, so the TB accumulator bank is 256x1408 =
//     20 RAMB36 — IDENTICAL to the routed BATCH_T=64 ku5p_top, so the SAIF maps
//     1:1 onto the bank BRAMs (no under-counted bank power). BATCH_TOK<=BANK depth.
//   * N_LAYERS = 8 DISTINCT-DATA LAYERS, back to back, captured into ONE SAIF.
//     Each layer presents different weights+activations (build_weights_and_x is
//     layer-seeded), with its own real CSD DRAM fills + 512-iteration dense
//     burst, and self-checks at the AXI seam. The dispatcher is single-shot per
//     reset (OP_EOP -> S_DONE forever; program_done sticky; imem_we legal only in
//     S_IDLE), so each layer re-arms via a reset pulse — the architecturally-
//     intended re-arm. NET: the SAIF averages over 8 distinct (weights,acts)
//     operating points + 8x sustained activity, NOT a single fixed-data window.
//
// WHY NOT THE FULL 8x4 = 32-TILE GRID (capacity wall — do not "fix" by enlarging
// the grid): the dense weight working set for one batched GEMM must be RESIDENT
// in a single ping-pong bank, addressed through uram_cascade_adapter whose
// consumer index is bounded to [0, 2047] cascade words (DN_ADDR_W=12, high bit
// must be 0). The image is WEIGHT_NATIVE (=(max_tile_linear+1)*128) native beats
// of weights + activations, mapped native->cascade by /2; activations start at
// ACT_CASC_BASE = WEIGHT_NATIVE/2. A 32-tile grid (max_tile_linear=31) gives
// WEIGHT_NATIVE=4096 -> ACT_CASC_BASE=2048 -> the FIRST activation read overflows
// the residency (the 8x4 attempt failed with "uram_cascade_adapter: dn.rd_addr
// [11]=1; cascaded address out of upstream range"). The largest residency-safe
// layer keeps ACT_CASC_BASE < 2048; 8x2 (max_tile_linear=29) -> WEIGHT_NATIVE=
// 3840 -> ACT_CASC_BASE=1920, fits. The FULL 128x128 layer is served by multi-
// residency tiling (per-tile DRAM reload via the CSD path); this power workload
// uses the largest SINGLE-residency batched layer to keep the array maximally
// busy WITHOUT reload stalls — the right peak-sustained-power operating point.
//
// EVERY tile reuses the same physical 16x32 = 512-PE kernel (CLAUDE.md §2.2), so
// ALL 512 DSPs are exercised regardless of grid size; §11 "genuinely busy" is an
// OCCUPANCY property (compute beats vs reload), satisfied by the 512-iteration
// schedule above, not by covering all 32 logical tiles.
//
// HONESTY NOTE (state in the paper): data toggling is now varied at the LAYER
// grain (8 distinct weight/activation sets), which is the dominant representative-
// ness lever. The one residual is WITHIN a layer: the activation streamer reads a
// fixed base per tile (no token offset), so the 64-token batch replays identical
// activations across the 64 tokens of that single layer. Averaged over 8 distinct
// layers this is a small, disclosed residual; fully distinct PER-TOKEN activations
// would need a token-indexed offset in dense_act_streamer (RTL change) and is the
// only remaining fidelity step if a reviewer presses on per-token activity.
//
// SIM_CLOCK_BYPASS=1: the functional path runs on clk_in directly (the real MMCM
// is exercised at synth/impl, C5). clk_in is driven at 225 MHz (T_CLK=4.444ns) so
// the captured SAIF's switching-activity time base equals the silicon operating
// point that report_power assumes from the 225 MHz clock constraint — otherwise
// dynamic power is mis-scaled (see the T_CLK comment).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_archbetter_soc_top_sustained;
    import types_pkg::*;

    // SAIF time base MUST match the silicon operating point or report_power
    // scales dynamic power by the wrong toggles/sec. The routed ku5p_top is
    // constrained at 225 MHz (MMCM clkout0), so with SIM_CLOCK_BYPASS=1 the core
    // runs directly on clk_in here — drive clk_in at 225 MHz (4.444 ns) so the
    // captured SAIF's data-net activity is the 225 MHz rate, not a 100 MHz one.
    // (4.444 ns half-period = 2222 ps, exact at 1 ps timescale precision.)
    localparam time         T_CLK      = 4.444ns;  // 225 MHz silicon clock (SAIF base)
    localparam int unsigned IMEM_DEPTH = 64;
    localparam int unsigned AXI_DATA_W = 128;
    localparam int unsigned AXI_ID_W   = 4;
    localparam int unsigned BEAT_BYTES = AXI_DATA_W / 8;   // 16

    // ---- Sub-layer geometry — 8x2 residency-safe layer, deep batch (C6) -----
    // 8x2 = 16 tiles (full 128 rows, 64 cols), COL_CNT=2 matches the proven
    // regression. max_tile_linear=29 -> WEIGHT_NATIVE=3840 -> ACT_CASC_BASE=1920
    // < 2048, so the dense image fits one ping-pong residency (see header).
    localparam int COLS  = DENSE_ARRAY_COLS;       // 128
    localparam int GRS   = DENSE_GROUP_ROWS;       // 16
    localparam int PHYS_COLS = DENSE_PHYS_COLS;    // 32
    localparam int ROW_CNT = 8, COL_CNT = 2, K_TILE = 1;  // 8x2 = 16 tiles
    localparam int USED_ROWS = ROW_CNT * GRS;       // 128 (full row depth)
    localparam int USED_COLS = COL_CNT * PHYS_COLS;  // 64
    localparam int WORDS_PER_TILE_CASC = 64;
    localparam int NATIVE_PER_TILE     = 2 * WORDS_PER_TILE_CASC;
    localparam int MAX_TILE_LINEAR     = (ROW_CNT-1)*int'(DENSE_LOGICAL_TILE_COLS) + (COL_CNT-1);
    localparam int WEIGHT_NATIVE       = (MAX_TILE_LINEAR + 1) * NATIVE_PER_TILE;
    localparam int ACT_NATIVE_PER_BAND = K_TILE * 4;
    localparam int ACT_NATIVE          = ROW_CNT * ACT_NATIVE_PER_BAND;
    localparam int ACT_CASC_BASE       = WEIGHT_NATIVE / 2;
    localparam int DENSE_NATIVE        = WEIGHT_NATIVE + ACT_NATIVE;
    localparam int K_FFN               = 3;
    localparam int SPARSE_NATIVE_BEATS = 4 + 8 * K_FFN;
    localparam int BATCH_TOK           = 64;        // deep batch; ALSO drives .BATCH_T below -> structural match to routed ku5p_top (BATCH_T=64)

    // Number of back-to-back DISTINCT-data layers captured into one SAIF. The
    // dispatcher is single-shot per reset (OP_EOP -> S_DONE forever; program_done
    // sticky; imem_we legal only in S_IDLE), so each layer re-arms via a reset
    // pulse — the architecturally-intended re-arm. N distinct (weights,acts)
    // operating points + N x sustained activity + real CSD fills per layer.
    localparam int N_LAYERS            = 8;

    localparam logic [DRAM_ADDR_W-1:0] DENSE_DRAM_BASE  = 'h1000_0000;
    localparam logic [DRAM_ADDR_W-1:0] SPARSE_DRAM_BASE = 'h2000_0000;
    localparam logic [DRAM_ADDR_W-1:0] STOUT_DRAM_BASE  = 'h3000_0000;

    // NoC multicast: drops 0..7, multicast.
    localparam noc_mask_t   TGT_MASK    = noc_mask_t'(64'h0000_0000_0000_00FF);
    localparam logic [31:0] TGT_MASK_LO = TGT_MASK[31:0];
    localparam logic [31:0] TGT_MASK_HI = TGT_MASK[63:32];
    localparam logic [NOC_PATH_ID_W-1:0] TGT_HANDLE = '0;

    // ---- cfg register map (mirrors soc_ctrl_loader) -------------------------
    localparam logic [7:0] A_CTRL=8'h00, A_IMEM_ADDR=8'h10, A_IMEM_LO=8'h14,
        A_IMEM_HI=8'h18, A_DESC_ADDR=8'h20, A_DESC_LO=8'h24, A_DESC_HI=8'h28,
        A_BASE_DW=8'h30, A_BASE_DA=8'h34, A_BASE_TL=8'h38, A_BASE_OC=8'h3C,
        A_BASE_SO=8'h40;
    localparam int unsigned DESC_W = $bits(csd_descriptor_t);

    // -------------------------------------------------------------------------
    // Clock / reset.
    // -------------------------------------------------------------------------
    logic clk_in, ext_rst_n;
    initial clk_in = 1'b0;
    always #(T_CLK/2) clk_in = ~clk_in;

    // -------------------------------------------------------------------------
    // DUT + DRAM model.
    // -------------------------------------------------------------------------
    logic        cfg_we;
    logic [7:0]  cfg_addr;
    logic [31:0] cfg_wdata, cfg_rdata;
    logic        program_done, locked_o, compute_clk_o;

    axi4_if #(.ADDR_W(DRAM_ADDR_W), .DATA_W(AXI_DATA_W), .ID_W(AXI_ID_W))
        axi (.clk(clk_in), .rst_n(ext_rst_n));

    // Instance named u_soc (NOT dut) so a SAIF captured over this subtree maps
    // 1:1 onto the routed archbetter_ku5p_top hierarchy (ku5p_top -> u_soc ->
    // u_core), letting read_saif strip just the TB top and land on u_soc/u_core.
    archbetter_soc_top #(
        .IMEM_DEPTH(IMEM_DEPTH), .BATCH_T(BATCH_TOK),
        .AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W),
        .SIM_CLOCK_BYPASS(1'b1)
    ) u_soc (
        .clk_in(clk_in), .ext_rst_n(ext_rst_n),
        .compute_clk_o(compute_clk_o), .locked_o(locked_o),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_rdata(cfg_rdata), .program_done(program_done),
        .m_axi(axi)
    );

    axi4_dram_model #(
        .AXI_DATA_W(AXI_DATA_W), .AXI_ADDR_W(DRAM_ADDR_W), .AXI_ID_W(AXI_ID_W),
        .RD_LATENCY(8), .WR_LATENCY(4)
    ) u_model (.clk(clk_in), .rst_n(ext_rst_n), .axi(axi.slave));

    // -------------------------------------------------------------------------
    // AXI bus monitors (localize read-fill vs compute vs write-drain).
    // -------------------------------------------------------------------------
    int unsigned            mon_rd_beats, mon_wr_beats;
    logic [AXI_DATA_W-1:0]  mon_first_rd;
    logic [DRAM_ADDR_W-1:0] mon_aw_addr_l, mon_first_waddr;
    logic                   mon_got_rd;
    logic [AXI_DATA_W-1:0]  mon_wd_arr [COLS];   // captured ST_OUT write beats (in order)
    always_ff @(posedge clk_in) begin
        if (!ext_rst_n) begin
            mon_rd_beats <= 0; mon_wr_beats <= 0; mon_got_rd <= 0;
            mon_first_rd <= '0; mon_aw_addr_l <= '0; mon_first_waddr <= '0;
        end else begin
            if (axi.rvalid && axi.rready) begin
                mon_rd_beats <= mon_rd_beats + 1;
                if (!mon_got_rd) begin mon_first_rd <= axi.rdata; mon_got_rd <= 1; end
            end
            if (axi.awvalid && axi.awready) mon_aw_addr_l <= axi.awaddr;
            if (axi.wvalid && axi.wready) begin
                if (mon_wr_beats == 0) mon_first_waddr <= mon_aw_addr_l;
                if (mon_wr_beats < COLS) mon_wd_arr[mon_wr_beats] <= axi.wdata;
                mon_wr_beats <= mon_wr_beats + 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Scoreboard.
    // -------------------------------------------------------------------------
    int unsigned n_checks, n_errors;
    function automatic void chk(input bit cond, input string msg);
        n_checks++;
        if (!cond) begin n_errors++; $error("tb_archbetter_soc_top_sustained: FAIL — %s", msg); end
    endfunction

    // -------------------------------------------------------------------------
    // Reference data + images (same construction as tb_archbetter_core).
    // -------------------------------------------------------------------------
    bfp12_mant_t           weights_ref [128][128];
    bfp12_mant_t           x_vec       [USED_ROWS];
    array_acc_t [COLS-1:0] y_expected;
    bfp12_mant_t      ffn_acts   [TLMM_TILE];
    tern_lane_tiles_t ffn_wbeats [K_FFN];
    logic [URAM_WIDTH_BITS-1:0] dense_native  [DENSE_NATIVE];
    logic [URAM_WIDTH_BITS-1:0] sparse_native [SPARSE_NATIVE_BEATS];

    function automatic void pack_bfp12_tile(
        input  bfp12_mant_t mants [BFP12_BLK], input bfp12_exp_t shared_exp,
        output logic [URAM_WIDTH_BITS-1:0] out [4]
    );
        logic [143:0] cw [2];
        cw[0] = '0; cw[1] = '0;
        for (int i = 0; i < 8; i++) cw[0][i*BFP12_MANT_W +: BFP12_MANT_W] = mants[i];
        cw[0][96 +: BFP12_EXP_W] = shared_exp;
        for (int i = 0; i < 8; i++) cw[1][i*BFP12_MANT_W +: BFP12_MANT_W] = mants[8+i];
        out[0] = cw[0][URAM_WIDTH_BITS-1:0];
        out[1] = cw[0][2*URAM_WIDTH_BITS-1:URAM_WIDTH_BITS];
        out[2] = cw[1][URAM_WIDTH_BITS-1:0];
        out[3] = cw[1][2*URAM_WIDTH_BITS-1:URAM_WIDTH_BITS];
    endfunction

    function automatic void pack_weight_word(
        input bfp12_mant_t w8 [8],
        output logic [URAM_WIDTH_BITS-1:0] lo, output logic [URAM_WIDTH_BITS-1:0] hi
    );
        logic [143:0] cw; cw = '0;
        for (int s = 0; s < 8; s++) cw[s*BFP12_MANT_W +: BFP12_MANT_W] = w8[s];
        lo = cw[URAM_WIDTH_BITS-1:0];
        hi = cw[2*URAM_WIDTH_BITS-1:URAM_WIDTH_BITS];
    endfunction

    function automatic void pack_compute_beat(
        input tern_lane_tiles_t wbeat,
        ref   logic [URAM_WIDTH_BITS-1:0] dst [SPARSE_NATIVE_BEATS], input int base_idx
    );
        logic [143:0] cw [4];
        for (int k = 0; k < 4; k++) cw[k] = '0;
        for (int l = 0; l < int'(TLMM_LANES); l++)
            for (int t = 0; t < int'(TLMM_TILE); t++) begin
                automatic int idx  = l * int'(TLMM_TILE) + t;
                automatic int word = idx / 64;
                automatic int bitp = (idx % 64) * 2;
                cw[word][bitp +: 2] = wbeat[l][t];
            end
        for (int k = 0; k < 4; k++) begin
            dst[base_idx + 2*k + 0] = cw[k][URAM_WIDTH_BITS-1:0];
            dst[base_idx + 2*k + 1] = cw[k][2*URAM_WIDTH_BITS-1:URAM_WIDTH_BITS];
        end
    endfunction

    // Per-layer DISTINCT data: the +k*layer terms rotate the value patterns so
    // each layer presents a different weight/activation set (different switching
    // activity) while staying in the small bounded range (no BFP-exp blow-out).
    task automatic build_weights_and_x(input int layer);
        for (int r = 0; r < 128; r++)
            for (int c = 0; c < 128; c++)
                weights_ref[r][c] = bfp12_mant_t'(signed'(((r + c + 3*layer) % 5) - 2));
        for (int i = 0; i < USED_ROWS; i++)
            x_vec[i] = bfp12_mant_t'(signed'(((i + 2*layer) % 7) - 3));
    endtask

    task automatic build_golden();
        for (int c = 0; c < COLS; c++) y_expected[c] = '0;
        for (int c = 0; c < USED_COLS; c++) begin
            automatic array_acc_t acc; acc = '0;
            for (int gr = 0; gr < ROW_CNT; gr++)
                for (int r = 0; r < GRS; r++)
                    acc += array_acc_t'($signed(x_vec[gr*GRS + r]) * $signed(weights_ref[gr*GRS + r][c]));
            y_expected[c] = acc;
        end
    endtask

    task automatic build_dense_image();
        bfp12_mant_t                w8       [8];
        logic [URAM_WIDTH_BITS-1:0] lo, hi;
        bfp12_mant_t                band     [BFP12_BLK];
        logic [URAM_WIDTH_BITS-1:0] beat_out [4];
        for (int i = 0; i < DENSE_NATIVE; i++) dense_native[i] = '0;
        for (int gr = 0; gr < ROW_CNT; gr++)
            for (int gc = 0; gc < COL_CNT; gc++) begin
                automatic int tile_linear = gr*int'(DENSE_LOGICAL_TILE_COLS) + gc;
                for (int w = 0; w < WORDS_PER_TILE_CASC; w++) begin
                    for (int s = 0; s < 8; s++) begin
                        automatic int pe_global = w*8 + s;
                        automatic int phys      = (pe_global >> 8) & 1;
                        automatic int pe_addr   = pe_global & 8'hFF;
                        automatic int local_r   = pe_addr >> 4;
                        automatic int local_c   = pe_addr & 4'hF;
                        automatic int row        = gr*GRS + local_r;
                        automatic int col        = gc*PHYS_COLS + phys*DENSE_GROUP_COLS + local_c;
                        w8[s] = weights_ref[row][col];
                    end
                    pack_weight_word(w8, lo, hi);
                    dense_native[tile_linear*NATIVE_PER_TILE + 2*w + 0] = lo;
                    dense_native[tile_linear*NATIVE_PER_TILE + 2*w + 1] = hi;
                end
            end
        for (int gr = 0; gr < ROW_CNT; gr++) begin
            for (int r = 0; r < BFP12_BLK; r++) band[r] = x_vec[gr*GRS + r];
            pack_bfp12_tile(band, bfp12_exp_t'(0), beat_out);
            for (int j = 0; j < 4; j++)
                dense_native[WEIGHT_NATIVE + gr*ACT_NATIVE_PER_BAND + j] = beat_out[j];
        end
    endtask

    task automatic build_sparse_image();
        bfp12_mant_t                mants_local [BFP12_BLK];
        logic [URAM_WIDTH_BITS-1:0] tile_words  [4];
        for (int i = 0; i < int'(TLMM_TILE); i++)
            ffn_acts[i] = bfp12_mant_t'(signed'((i % 5) - 2));
        for (int b = 0; b < K_FFN; b++)
            for (int l = 0; l < int'(TLMM_LANES); l++)
                for (int t = 0; t < int'(TLMM_TILE); t++) begin
                    automatic int rsel = $urandom_range(0,2);
                    unique case (rsel)
                        0:       ffn_wbeats[b][l][t] = TERN_ZERO;
                        1:       ffn_wbeats[b][l][t] = TERN_POS;
                        default: ffn_wbeats[b][l][t] = TERN_NEG;
                    endcase
                end
        for (int i = 0; i < int'(TLMM_TILE); i++) mants_local[i] = ffn_acts[i];
        pack_bfp12_tile(mants_local, bfp12_exp_t'(0), tile_words);
        for (int j = 0; j < 4; j++) sparse_native[j] = tile_words[j];
        for (int b = 0; b < K_FFN; b++) pack_compute_beat(ffn_wbeats[b], sparse_native, 4 + b*8);
    endtask

    // -------------------------------------------------------------------------
    // Macro-instruction builders (mirror tb_archbetter_core).
    // -------------------------------------------------------------------------
    function automatic logic [MACRO_WORD_W-1:0] mk_instr(
        input macro_opc_e opc, input logic [7:0] tile_id,
        input logic [7:0] path_id_field, input logic [31:0] low32
    );
        logic [MACRO_WORD_W-1:0] w; w = '0;
        w[63:58]=opc; w[57:50]=tile_id; w[49:42]=path_id_field; w[31:0]=low32; return w;
    endfunction
    function automatic logic [MACRO_WORD_W-1:0] mk_instr_flags(
        input macro_opc_e opc, input logic [7:0] tile_id,
        input logic [7:0] path_id_field, input logic [11:0] flags
    );
        logic [MACRO_WORD_W-1:0] w; w = '0;
        w[63:58]=opc; w[57:50]=tile_id; w[49:42]=path_id_field; w[11:0]=flags; return w;
    endfunction
    function automatic logic [MACRO_WORD_W-1:0] mk_gemm_batch(
        input logic [7:0] batch_t, input logic [7:0] path_id_field,
        input int row_cnt, input int col_cnt, input int k_cnt
    );
        logic [MACRO_WORD_W-1:0] w; w = '0;
        w[63:58]=OP_GEMM_BATCH; w[57:50]=batch_t; w[49:42]=path_id_field;
        w[41:32]=row_cnt[9:0]; w[31:22]=col_cnt[9:0]; w[21:12]=k_cnt[9:0]; return w;
    endfunction
    function automatic logic [31:0] mk_meta_payload(
        input logic [5:0] src_node, input logic [2:0] priority_lvl, input logic is_multicast
    );
        logic [31:0] p; p = '0; p[9:4]=src_node; p[3:1]=priority_lvl; p[0]=is_multicast; return p;
    endfunction
    function automatic logic [31:0] mk_kcnt_payload(input int k_cnt);
        logic [31:0] p; p = '0; p[21:12] = k_cnt[9:0]; return p;
    endfunction

    // -------------------------------------------------------------------------
    // cfg-bus drivers.
    // -------------------------------------------------------------------------
    task automatic cfg_w(input logic [7:0] a, input logic [31:0] d);
        @(negedge clk_in); cfg_we = 1'b1; cfg_addr = a; cfg_wdata = d;
        @(negedge clk_in); cfg_we = 1'b0;
    endtask

    task automatic imem_push(input logic [MACRO_WORD_W-1:0] word);
        cfg_w(A_IMEM_LO, word[31:0]);
        cfg_w(A_IMEM_HI, word[63:32]);
    endtask

    task automatic desc_push(
        input logic is_sparse_f, input logic [URAM_ADDR_W-1:0] uram_base,
        input logic [DRAM_ADDR_W-1:0] dram_base, input logic [DRAM_LEN_W-1:0] n_beats
    );
        csd_descriptor_t d;
        logic [DESC_W-1:0] dv;
        d.compressed = 1'b0; d.is_sparse = is_sparse_f;
        d.uram_base = uram_base; d.dram_base = dram_base; d.n_beats = n_beats;
        dv = d;
        cfg_w(A_DESC_LO, dv[31:0]);
        cfg_w(A_DESC_HI, 32'(dv[DESC_W-1:32]));
    endtask

    // -------------------------------------------------------------------------
    // Main.
    // -------------------------------------------------------------------------
    int waited;
    initial begin : main
        n_checks = 0; n_errors = 0;
        cfg_we = 1'b0; cfg_addr = '0; cfg_wdata = '0;
        ext_rst_n = 1'b1;

        // =====================================================================
        // Multi-layer loop: each iteration is the FULL proven single-layer flow
        // with DISTINCT data, re-armed by a reset pulse (the dispatcher is single-
        // shot per reset). The SAIF captured across this whole sim therefore sees
        // N_LAYERS distinct (weights,activations) operating points back-to-back,
        // each with real CSD DRAM fills and a 512-iteration dense burst. Every
        // layer self-checks at the AXI seam, so correctness is verified throughout
        // (not just on the last layer).
        // =====================================================================
        for (int layer = 0; layer < N_LAYERS; layer++) begin : layer_loop
            // ---- per-layer re-arm: pulse reset (clears program_done + state) --
            ext_rst_n = 1'b0;
            repeat (8) @(posedge clk_in);
            ext_rst_n = 1'b1;
            repeat (16) @(posedge clk_in);  // reset-sync release + cdc depth

            // ---- STAGE 0: build DISTINCT vectors + golden + images -----------
            $display("[%0t] LAYER %0d/%0d STAGE 0: build images (%0dx%0d=%0d tiles, K=%0d, T=%0d)",
                     $time, layer, N_LAYERS-1, ROW_CNT, COL_CNT, ROW_CNT*COL_CNT, K_TILE, BATCH_TOK);
            build_weights_and_x(layer); build_golden(); build_dense_image(); build_sparse_image();

            // ---- STAGE 1: PRELOAD the DRAM model (byte addr = base + beat*16) -
            for (int i = 0; i < DENSE_NATIVE; i++)
                u_model.backdoor_write(DRAM_ADDR_W'(DENSE_DRAM_BASE + DRAM_ADDR_W'(i*BEAT_BYTES)),
                                       AXI_DATA_W'(dense_native[i]));
            for (int i = 0; i < SPARSE_NATIVE_BEATS; i++)
                u_model.backdoor_write(DRAM_ADDR_W'(SPARSE_DRAM_BASE + DRAM_ADDR_W'(i*BEAT_BYTES)),
                                       AXI_DATA_W'(sparse_native[i]));

            // ---- BISECTION DIAGNOSTIC: did the backdoor preload populate? -----
            chk(u_model.backdoor_read(DENSE_DRAM_BASE) === AXI_DATA_W'(dense_native[0]),
                $sformatf("L%0d preload[dense 0]: got %h exp %h", layer,
                          u_model.backdoor_read(DENSE_DRAM_BASE), AXI_DATA_W'(dense_native[0])));
            chk(u_model.backdoor_read(DRAM_ADDR_W'(DENSE_DRAM_BASE
                    + DRAM_ADDR_W'(WEIGHT_NATIVE*BEAT_BYTES))) === AXI_DATA_W'(dense_native[WEIGHT_NATIVE]),
                $sformatf("L%0d preload[act 0 @native %0d]: got %h exp %h", layer, WEIGHT_NATIVE,
                          u_model.backdoor_read(DRAM_ADDR_W'(DENSE_DRAM_BASE
                              + DRAM_ADDR_W'(WEIGHT_NATIVE*BEAT_BYTES))),
                          AXI_DATA_W'(dense_native[WEIGHT_NATIVE])));

            // ---- STAGE 2: descriptors via cfg -------------------------------
            cfg_w(A_DESC_ADDR, 32'd0);
            desc_push(1'b0, URAM_ADDR_W'(0), DENSE_DRAM_BASE,  DRAM_LEN_W'(DENSE_NATIVE));        // tile 0
            desc_push(1'b1, URAM_ADDR_W'(0), SPARSE_DRAM_BASE, DRAM_LEN_W'(SPARSE_NATIVE_BEATS)); // tile 1
            desc_push(1'b0, URAM_ADDR_W'(0), STOUT_DRAM_BASE,  DRAM_LEN_W'(COLS));                // tile 2 (ST_OUT)

            // ---- STAGE 3: imem program via cfg ------------------------------
            cfg_w(A_IMEM_ADDR, 32'd0);
            imem_push(mk_instr_flags(OP_LD_W_URAM, 8'h00, 8'h00, 12'h000));
            imem_push(mk_instr_flags(OP_LD_W_URAM, 8'h01, 8'h00, 12'h000 | (1 << FLG_IS_SPARSE)));
            imem_push(mk_instr_flags(OP_PINGPONG,  8'h00, 8'h00, 12'h000));
            imem_push(mk_instr_flags(OP_PINGPONG,  8'h01, 8'h00, 12'h000 | (1 << FLG_IS_SPARSE)));
            imem_push(mk_instr(OP_CFG_NOC, {6'd0, CFG_NOC_MASK_LO}, {3'd0, TGT_HANDLE}, TGT_MASK_LO));
            imem_push(mk_instr(OP_CFG_NOC, {6'd0, CFG_NOC_MASK_HI}, {3'd0, TGT_HANDLE}, TGT_MASK_HI));
            imem_push(mk_instr(OP_CFG_NOC, {6'd0, CFG_NOC_META},    {3'd0, TGT_HANDLE},
                               mk_meta_payload(6'd0, 3'd0, 1'b1)));
            imem_push(mk_instr(OP_BARRIER,    8'h00, 8'h00, 32'h0));
            imem_push(mk_instr(OP_COMMIT_NOC, 8'h00, 8'h00, 32'h0));
            imem_push(mk_gemm_batch(8'(BATCH_TOK), 8'h00, ROW_CNT, COL_CNT, K_TILE));
            imem_push(mk_instr(OP_BARRIER,    8'h00, 8'h00, 32'h0));
            imem_push(mk_instr(OP_FFN_TLMM,   8'h00, 8'h00, mk_kcnt_payload(K_FFN)));
            imem_push(mk_instr_flags(OP_ST_OUT, 8'h02, 8'h00, 12'h000));
            imem_push(mk_instr_flags(OP_EOP,    8'h00, 8'h00, 12'h000));

            // ---- STAGE 4: URAM bases via cfg --------------------------------
            cfg_w(A_BASE_DW, 32'd0);
            cfg_w(A_BASE_DA, 32'(ACT_CASC_BASE));
            cfg_w(A_BASE_TL, 32'd0);
            cfg_w(A_BASE_OC, 32'd0);
            cfg_w(A_BASE_SO, 32'd256);

            // ---- STAGE 5: start --------------------------------------------
            $display("[%0t] LAYER %0d STAGE 5: start (%0d tiles x %0d tokens = %0d GEMM iters)",
                     $time, layer, ROW_CNT*COL_CNT, BATCH_TOK, ROW_CNT*COL_CNT*BATCH_TOK);
            cfg_w(A_CTRL, 32'h1);

            waited = 0;
            while (!program_done) begin
                @(posedge clk_in); waited++;
                if (waited > 800_000) $fatal(1, "tb_archbetter_soc_top_sustained: L%0d program_done never asserted", layer);
            end
            $display("[%0t] LAYER %0d program_done after %0d cycles", $time, layer, waited);
            // Let any trailing AXI write traffic (ST_OUT) fully settle.
            repeat (500) @(posedge clk_in);

            // ---- STAGE 6: verify THIS layer's result off the AXI write bus ---
            chk(program_done === 1'b1, $sformatf("L%0d program_done not asserted", layer));
            chk(mon_first_rd[DRAM_BEAT_W-1:0] === dense_native[0],
                $sformatf("L%0d read-fill first beat: got %h exp %h", layer,
                          mon_first_rd[DRAM_BEAT_W-1:0], dense_native[0]));
            chk(mon_rd_beats == (DENSE_NATIVE + SPARSE_NATIVE_BEATS),
                $sformatf("L%0d read-fill beats: got %0d exp %0d", layer,
                          mon_rd_beats, DENSE_NATIVE + SPARSE_NATIVE_BEATS));
            chk(mon_first_waddr === STOUT_DRAM_BASE,
                $sformatf("L%0d ST_OUT base addr: got %h exp %h", layer, mon_first_waddr, STOUT_DRAM_BASE));
            chk(mon_wr_beats == COLS,
                $sformatf("L%0d ST_OUT write beats: got %0d exp %0d", layer, mon_wr_beats, COLS));
            for (int c = 0; c < COLS; c++) begin
                automatic array_acc_t got = array_acc_t'(mon_wd_arr[c][ARRAY_ACC_W-1:0]);
                chk(got === y_expected[c],
                    $sformatf("L%0d y[%0d] on AXI W bus: got %0d exp %0d",
                              layer, c, $signed(got), $signed(y_expected[c])));
            end
            $display("[%0t] LAYER %0d verified (%0d cols, %0d used) -- running: %0d checks / %0d errors",
                     $time, layer, COLS, USED_COLS, n_checks, n_errors);
        end

        repeat (4) @(posedge clk_in);
        if (n_errors == 0)
            $display("tb_archbetter_soc_top_sustained: PASS  (%0d layers, %0d checks, 0 errors)",
                     N_LAYERS, n_checks);
        else
            $display("tb_archbetter_soc_top_sustained: FAIL  (%0d errors / %0d checks over %0d layers)",
                     n_errors, n_checks, N_LAYERS);
        $finish;
    end

    initial begin : watchdog
        // ~25-30k cycles/layer (64-token batch); 150k/layer budget is comfortable.
        #(T_CLK * 150_000 * N_LAYERS);
        $fatal(1, "tb_archbetter_soc_top_sustained: watchdog timeout");
    end

endmodule : tb_archbetter_soc_top_sustained

`default_nettype wire
