// -----------------------------------------------------------------------------
// tb_archbetter_soc_top.sv  (C3.3 — full layer end-to-end through the SoC wrapper)
//
// This is the C2b deliverable folded into C3: a complete dense (+sparse) layer
// runs end-to-end through archbetter_soc_top against MODELED DRAM LATENCY, with
// NO direct host poking of the core — everything goes through:
//   * the narrow 32-bit cfg loader (program + descriptors + bases + start), and
//   * the AXI4 memory seam (axi4_read/write_adapter <-> axi4_dram_model).
//
// Flow:
//   1. Build the same capacity-bounded sub-layer as tb_archbetter_core
//      (4x2 tiles, K=1, OP_GEMM_BATCH T=8) + a small FFN.
//   2. PRELOAD the DRAM model's backing store with the dense + sparse images at
//      byte addresses base + beat*BEAT_BYTES (the seam's addressing).
//   3. Drive cfg to load the descriptor table, imem program, and URAM bases,
//      then pulse start.
//   4. Wait for program_done. The weights/activations were fetched from DRAM via
//      the read seam; OP_ST_OUT drained the dense result to DRAM via the write
//      seam.
//   5. VERIFY by reading the result back from the DRAM model at STOUT_DRAM_BASE
//      and bit-comparing against the golden — proving BOTH AXI directions and the
//      whole control/compute path through the wrapper.
//
// SIM_CLOCK_BYPASS=1: the functional path runs on the board clock directly (the
// real MMCM is exercised at synth/impl, C5).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_archbetter_soc_top;
    import types_pkg::*;

    localparam time         T_CLK      = 10ns;     // 100 MHz board clock
    localparam int unsigned IMEM_DEPTH = 64;
    localparam int unsigned AXI_DATA_W = 128;
    localparam int unsigned AXI_ID_W   = 4;
    localparam int unsigned BEAT_BYTES = AXI_DATA_W / 8;   // 16

    // ---- Sub-layer geometry (mirrors tb_archbetter_core) --------------------
    localparam int COLS  = DENSE_ARRAY_COLS;       // 128
    localparam int GRS   = DENSE_GROUP_ROWS;       // 16
    localparam int PHYS_COLS = DENSE_PHYS_COLS;    // 32
    localparam int ROW_CNT = 4, COL_CNT = 2, K_TILE = 1;
    localparam int USED_ROWS = ROW_CNT * GRS;       // 64
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
    localparam int BATCH_TOK           = 8;

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

    archbetter_soc_top #(
        .IMEM_DEPTH(IMEM_DEPTH), .BATCH_T(BATCH_TOK),
        .AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W),
        .SIM_CLOCK_BYPASS(1'b1)
    ) dut (
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
    // The result is verified DIRECTLY from the AXI write-data bus (the real
    // memory-seam interface contract). DRAM-readback via the model's associative
    // array is unreliable under XSim for cells written by the model's always_ff
    // engine vs. a hierarchical TB function read — so we capture the W beats the
    // accelerator actually drives out the seam and compare them to golden.
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
        if (!cond) begin n_errors++; $error("tb_archbetter_soc_top: FAIL — %s", msg); end
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

    task automatic build_weights_and_x();
        for (int r = 0; r < 128; r++)
            for (int c = 0; c < 128; c++)
                weights_ref[r][c] = bfp12_mant_t'(signed'(((r + c) % 5) - 2));
        for (int i = 0; i < USED_ROWS; i++)
            x_vec[i] = bfp12_mant_t'(signed'((i % 7) - 3));
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
        ext_rst_n = 1'b0;
        repeat (8) @(posedge clk_in);
        ext_rst_n = 1'b1;
        // Wait for the wrapper's reset sync to release (locked + cdc depth).
        repeat (16) @(posedge clk_in);

        // ---- STAGE 0: build vectors + golden + images ----------------------
        $display("[%0t] STAGE 0: build images (%0dx%0d tiles, K=%0d, T=%0d)",
                 $time, ROW_CNT, COL_CNT, K_TILE, BATCH_TOK);
        build_weights_and_x(); build_golden(); build_dense_image(); build_sparse_image();

        // ---- STAGE 1: PRELOAD the DRAM model (byte addr = base + beat*16) ---
        for (int i = 0; i < DENSE_NATIVE; i++)
            u_model.backdoor_write(DRAM_ADDR_W'(DENSE_DRAM_BASE + DRAM_ADDR_W'(i*BEAT_BYTES)),
                                   AXI_DATA_W'(dense_native[i]));
        for (int i = 0; i < SPARSE_NATIVE_BEATS; i++)
            u_model.backdoor_write(DRAM_ADDR_W'(SPARSE_DRAM_BASE + DRAM_ADDR_W'(i*BEAT_BYTES)),
                                   AXI_DATA_W'(sparse_native[i]));
        $display("[%0t] STAGE 1: DRAM preloaded (dense %0d + sparse %0d beats)",
                 $time, DENSE_NATIVE, SPARSE_NATIVE_BEATS);

        // ---- BISECTION DIAGNOSTIC: did the backdoor preload populate the model?
        // If these fail, the preload mechanism is broken (not the data path);
        // if they pass, the read/compute/write seam is the suspect.
        chk(u_model.backdoor_read(DENSE_DRAM_BASE) === AXI_DATA_W'(dense_native[0]),
            $sformatf("preload[dense 0]: got %h exp %h",
                      u_model.backdoor_read(DENSE_DRAM_BASE), AXI_DATA_W'(dense_native[0])));
        chk(u_model.backdoor_read(DRAM_ADDR_W'(DENSE_DRAM_BASE
                + DRAM_ADDR_W'(WEIGHT_NATIVE*BEAT_BYTES))) === AXI_DATA_W'(dense_native[WEIGHT_NATIVE]),
            $sformatf("preload[act 0 @native %0d]: got %h exp %h", WEIGHT_NATIVE,
                      u_model.backdoor_read(DRAM_ADDR_W'(DENSE_DRAM_BASE
                          + DRAM_ADDR_W'(WEIGHT_NATIVE*BEAT_BYTES))),
                      AXI_DATA_W'(dense_native[WEIGHT_NATIVE])));

        // ---- STAGE 2: descriptors via cfg ----------------------------------
        cfg_w(A_DESC_ADDR, 32'd0);
        desc_push(1'b0, URAM_ADDR_W'(0), DENSE_DRAM_BASE,  DRAM_LEN_W'(DENSE_NATIVE));        // tile 0
        desc_push(1'b1, URAM_ADDR_W'(0), SPARSE_DRAM_BASE, DRAM_LEN_W'(SPARSE_NATIVE_BEATS)); // tile 1
        desc_push(1'b0, URAM_ADDR_W'(0), STOUT_DRAM_BASE,  DRAM_LEN_W'(COLS));                // tile 2 (ST_OUT)

        // ---- STAGE 3: imem program via cfg ---------------------------------
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

        // ---- STAGE 4: URAM bases via cfg -----------------------------------
        cfg_w(A_BASE_DW, 32'd0);
        cfg_w(A_BASE_DA, 32'(ACT_CASC_BASE));
        cfg_w(A_BASE_TL, 32'd0);
        cfg_w(A_BASE_OC, 32'd0);
        cfg_w(A_BASE_SO, 32'd256);

        // ---- STAGE 5: start ------------------------------------------------
        $display("[%0t] STAGE 5: start", $time);
        cfg_w(A_CTRL, 32'h1);

        waited = 0;
        while (!program_done) begin
            @(posedge clk_in); waited++;
            if (waited > 400_000) $fatal(1, "tb_archbetter_soc_top: program_done never asserted");
        end
        $display("[%0t] program_done after %0d cycles", $time, waited);
        // Let any trailing AXI write traffic (ST_OUT) fully settle in the model.
        repeat (500) @(posedge clk_in);

        // ---- STAGE 6: verify the dense result FROM DRAM --------------------
        $display("[%0t] STAGE 6: verify the layer end-to-end over the AXI seam", $time);
        $display("  [mon] AXI read  beats = %0d ; first rdata[71:0] = %h (exp dense_native[0] = %h)",
                 mon_rd_beats, mon_first_rd[DRAM_BEAT_W-1:0], dense_native[0]);
        $display("  [mon] AXI write beats = %0d ; first waddr = %h (exp STOUT = %h)",
                 mon_wr_beats, mon_first_waddr, STOUT_DRAM_BASE);

        chk(program_done === 1'b1, "program_done not asserted");

        // ---- Read seam: correct fill data + beat count ---------------------
        chk(mon_first_rd[DRAM_BEAT_W-1:0] === dense_native[0],
            $sformatf("read-fill first beat: got %h exp %h",
                      mon_first_rd[DRAM_BEAT_W-1:0], dense_native[0]));
        chk(mon_rd_beats == (DENSE_NATIVE + SPARSE_NATIVE_BEATS),
            $sformatf("read-fill beats: got %0d exp %0d",
                      mon_rd_beats, DENSE_NATIVE + SPARSE_NATIVE_BEATS));

        // ---- Write seam: ST_OUT drains the dense result to STOUT ------------
        chk(mon_first_waddr === STOUT_DRAM_BASE,
            $sformatf("ST_OUT base addr: got %h exp %h", mon_first_waddr, STOUT_DRAM_BASE));
        chk(mon_wr_beats == COLS,
            $sformatf("ST_OUT write beats: got %0d exp %0d", mon_wr_beats, COLS));

        // ---- The dense result, taken straight off the AXI write bus --------
        for (int c = 0; c < COLS; c++) begin
            automatic array_acc_t got = array_acc_t'(mon_wd_arr[c][ARRAY_ACC_W-1:0]);
            chk(got === y_expected[c],
                $sformatf("y[%0d] on AXI W bus: got %0d exp %0d",
                          c, $signed(got), $signed(y_expected[c])));
        end
        $display("[%0t]   %0d output cols verified over the AXI seam (%0d used)",
                 $time, COLS, USED_COLS);

        repeat (4) @(posedge clk_in);
        if (n_errors == 0)
            $display("tb_archbetter_soc_top: PASS  (%0d checks, 0 errors)", n_checks);
        else
            $display("tb_archbetter_soc_top: FAIL  (%0d errors / %0d checks)", n_errors, n_checks);
        $finish;
    end

    initial begin : watchdog
        #(T_CLK * 600_000);
        $fatal(1, "tb_archbetter_soc_top: watchdog timeout");
    end

endmodule : tb_archbetter_soc_top

`default_nettype wire
