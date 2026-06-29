
`timescale 1ns/1ps
`default_nettype none

module tb_archbetter_core;
    import types_pkg::*;
    localparam time T_CLK       = 10ns;
    localparam int  IMEM_DEPTH  = 64;
    localparam int  IMEM_ADDR_W = $clog2(IMEM_DEPTH);

    localparam int  COLS  = DENSE_ARRAY_COLS;
    localparam int  GRS   = DENSE_GROUP_ROWS;
    localparam int  GCS   = DENSE_GROUP_COLS;
    localparam int  PHYS_COLS = DENSE_PHYS_COLS;
    localparam int  PE_ADDR_W = $clog2(DENSE_PE_PER_GROUP);
    localparam int  ROW_CNT = 4;
    localparam int  COL_CNT = 2;
    localparam int  K_TILE  = 1;

    localparam int  USED_ROWS = ROW_CNT * GRS;
    localparam int  USED_COLS = COL_CNT * PHYS_COLS;
    localparam int  WORDS_PER_TILE_CASC = 64;
    localparam int  NATIVE_PER_TILE     = 2 * WORDS_PER_TILE_CASC;
    localparam int  MAX_TILE_LINEAR     = (ROW_CNT-1)*int'(DENSE_LOGICAL_TILE_COLS) + (COL_CNT-1);
    localparam int  WEIGHT_NATIVE       = (MAX_TILE_LINEAR + 1) * NATIVE_PER_TILE;
    localparam int  ACT_NATIVE_PER_BAND = K_TILE * 4;
    localparam int  ACT_NATIVE          = ROW_CNT * ACT_NATIVE_PER_BAND;
    localparam int  ACT_CASC_BASE       = WEIGHT_NATIVE / 2;
    localparam int  DENSE_NATIVE        = WEIGHT_NATIVE + ACT_NATIVE;
    localparam int  K_FFN               = 3;
    localparam int  SPARSE_NATIVE_BEATS = 4 + 8 * K_FFN;
    localparam int  BATCH_TOK      = 8;
    localparam int  DENSE_PE_TOTAL = PHYS_COLS * GRS;
    localparam int  MACS_PER_PASS  = ROW_CNT * COL_CNT * K_TILE * DENSE_PE_TOTAL;
    localparam int  MACS_BATCH     = BATCH_TOK * MACS_PER_PASS;
    localparam real TARGET_FREQ_HZ = 250.0e6;
    initial begin : imem_cap_check
        if (14 > IMEM_DEPTH)
            $fatal(1, "tb_archbetter_core: imem program (14) overflows IMEM_DEPTH=%0d", IMEM_DEPTH);
    end

    localparam int  URAM_AW = URAM_ADDR_W;

    localparam logic [DRAM_ADDR_W-1:0] DENSE_DRAM_BASE  = 'h1000_0000;
    localparam logic [DRAM_ADDR_W-1:0] SPARSE_DRAM_BASE = 'h2000_0000;
    localparam logic [DRAM_ADDR_W-1:0] STOUT_DRAM_BASE  = 'h3000_0000;
    localparam noc_mask_t   TGT_MASK         = noc_mask_t'(64'h0000_0000_0000_00FF);
    localparam logic [31:0] TGT_MASK_LO      = TGT_MASK[31:0];
    localparam logic [31:0] TGT_MASK_HI      = TGT_MASK[63:32];
    localparam logic [5:0]  TGT_SRC_NODE     = 6'd0;
    localparam logic [2:0]  TGT_PRIORITY     = 3'd0;
    localparam logic        TGT_IS_MULTICAST = 1'b1;
    localparam logic [NOC_PATH_ID_W-1:0] TGT_HANDLE = '0;
    logic clk, rst_n;
    initial clk = 1'b0;
    always  #(T_CLK/2) clk = ~clk;
    logic                          start;
    logic                          program_done;
    logic                          imem_we;
    logic [IMEM_ADDR_W-1:0]        imem_wr_addr;
    logic [MACRO_WORD_W-1:0]       imem_wr_data;
    logic                          desc_we;
    logic [7:0]                    desc_wr_addr;
    csd_descriptor_t               desc_wr_data;

    logic [URAM_ADDR_W-1:0]        dense_weight_base_addr;
    logic [URAM_ADDR_W-1:0]        dense_act_base_addr;
    logic [URAM_ADDR_W-1:0]        tlmm_base_addr;
    logic [URAM_ADDR_W-1:0]        out_collector_base_addr;
    logic [URAM_ADDR_W-1:0]        sparse_out_base_addr;

    logic [KV_DATA_W-1:0]          kv_wr_data_i;
    logic [KV_DATA_W-1:0]          kv_rd_data_o;
    logic                          kv_rd_valid_o;

    array_acc_t [COLS-1:0]         y_out;
    logic                          y_valid;

    logic                          sparse_out_wr_en;
    logic [URAM_ADDR_W-1:0]        sparse_out_wr_addr;
    logic [URAM_WIDTH_BITS-1:0]    sparse_out_wr_data;

    logic [NOC_DATA_W-1:0]         d2s_data_o;
    logic [NOC_USER_W-1:0]         d2s_user_o;
    logic                          d2s_valid_o;
    logic                          d2s_ready_i;
    logic                          d2s_last_o;
    logic                          d2s_almost_full_i;

    logic [DRAM_ADDR_W-1:0]        dram_req_addr;
    logic [DRAM_LEN_W-1:0]         dram_req_len;
    logic                          dram_req_valid;
    logic                          dram_req_ready;
    logic [DRAM_BEAT_W-1:0]        dram_rsp_data;
    logic                          dram_rsp_valid;
    logic                          dram_rsp_ready;
    logic                          dram_rsp_last;

    logic [DRAM_ADDR_W-1:0]        dram_wr_req_addr;
    logic [DRAM_LEN_W-1:0]         dram_wr_req_len;
    logic                          dram_wr_req_valid;
    logic                          dram_wr_req_ready;
    logic [DRAM_BEAT_W-1:0]        dram_wr_wd_data;
    logic                          dram_wr_wd_valid;
    logic                          dram_wr_wd_ready;
    logic                          dram_wr_wd_last;
    archbetter_core #(
        .IMEM_DEPTH    (IMEM_DEPTH),
        .N_NOC_SOURCES (1),
        .BATCH_T       (BATCH_TOK),
        .D2S_FIFO_DEPTH(64)
    ) dut (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .start                  (start),
        .program_done           (program_done),
        .imem_we                (imem_we),
        .imem_wr_addr           (imem_wr_addr),
        .imem_wr_data           (imem_wr_data),
        .desc_we                (desc_we),
        .desc_wr_addr           (desc_wr_addr),
        .desc_wr_data           (desc_wr_data),
        .dense_weight_base_addr (dense_weight_base_addr),
        .dense_act_base_addr    (dense_act_base_addr),
        .tlmm_base_addr         (tlmm_base_addr),
        .out_collector_base_addr(out_collector_base_addr),
        .sparse_out_base_addr   (sparse_out_base_addr),
        .kv_wr_data_i           (kv_wr_data_i),
        .kv_rd_data_o           (kv_rd_data_o),
        .kv_rd_valid_o          (kv_rd_valid_o),
        .y_out                  (y_out),
        .y_valid                (y_valid),
        .sparse_out_wr_en       (sparse_out_wr_en),
        .sparse_out_wr_addr     (sparse_out_wr_addr),
        .sparse_out_wr_data     (sparse_out_wr_data),
        .d2s_data_o             (d2s_data_o),
        .d2s_user_o             (d2s_user_o),
        .d2s_valid_o            (d2s_valid_o),
        .d2s_ready_i            (d2s_ready_i),
        .d2s_last_o             (d2s_last_o),
        .d2s_almost_full_i      (d2s_almost_full_i),
        .dram_req_addr          (dram_req_addr),
        .dram_req_len           (dram_req_len),
        .dram_req_valid         (dram_req_valid),
        .dram_req_ready         (dram_req_ready),
        .dram_rsp_data          (dram_rsp_data),
        .dram_rsp_valid         (dram_rsp_valid),
        .dram_rsp_ready         (dram_rsp_ready),
        .dram_rsp_last          (dram_rsp_last),
        .dram_wr_req_addr       (dram_wr_req_addr),
        .dram_wr_req_len        (dram_wr_req_len),
        .dram_wr_req_valid      (dram_wr_req_valid),
        .dram_wr_req_ready      (dram_wr_req_ready),
        .dram_wr_wd_data        (dram_wr_wd_data),
        .dram_wr_wd_valid       (dram_wr_wd_valid),
        .dram_wr_wd_ready       (dram_wr_wd_ready),
        .dram_wr_wd_last        (dram_wr_wd_last)
    );

    assign d2s_ready_i       = 1'b1;
    assign d2s_almost_full_i = 1'b0;
    bfp12_mant_t           weights_ref [128][128];
    bfp12_mant_t           x_vec       [USED_ROWS];
    array_acc_t [COLS-1:0] y_expected;
    array_acc_t [COLS-1:0] y_snapped;
    logic                  y_snap_seen;

    bfp12_mant_t      ffn_acts   [TLMM_TILE];
    tern_lane_tiles_t ffn_wbeats [K_FFN];
    logic [URAM_WIDTH_BITS-1:0] dense_native  [DENSE_NATIVE];
    logic [URAM_WIDTH_BITS-1:0] sparse_native [SPARSE_NATIVE_BEATS];

    int unsigned n_checks;
    int unsigned n_errors;

    function automatic void chk(input bit cond, input string msg);
        n_checks++;
        if (!cond) begin
            n_errors++;
            $error("tb_archbetter_core: CHECK FAILED — %s", msg);
        end
    endfunction
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            y_snap_seen <= 1'b0;
        end else if (y_valid && !y_snap_seen) begin
            y_snapped   <= y_out;
            y_snap_seen <= 1'b1;
        end
    end
    int unsigned     cyc;
    int unsigned     start_cyc, done_cyc;
    int unsigned     yv_count;
    int unsigned     yv_first_cyc, yv_last_cyc, yv_prev_cyc;
    longint unsigned yv_interval_sum;
    logic            start_seen, done_seen, y_valid_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cyc             <= 0;
            start_cyc       <= 0;
            done_cyc        <= 0;
            yv_count        <= 0;
            yv_first_cyc    <= 0;
            yv_last_cyc     <= 0;
            yv_prev_cyc     <= 0;
            yv_interval_sum <= 0;
            start_seen      <= 1'b0;
            done_seen       <= 1'b0;
            y_valid_q       <= 1'b0;
        end else begin
            cyc       <= cyc + 1;
            y_valid_q <= y_valid;
            if (start && !start_seen) begin
                start_cyc  <= cyc;
                start_seen <= 1'b1;
            end
            if (program_done && !done_seen) begin
                done_cyc  <= cyc;
                done_seen <= 1'b1;
            end
            if (y_valid && !y_valid_q) begin
                if (yv_count == 0)
                    yv_first_cyc    <= cyc;
                else
                    yv_interval_sum <= yv_interval_sum + longint'(cyc - yv_prev_cyc);
                yv_prev_cyc <= cyc;
                yv_last_cyc <= cyc;
                yv_count    <= yv_count + 1;
            end
        end
    end
    int unsigned batch_drain_count;
    int unsigned batch_drain_bad;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            batch_drain_count <= 0;
            batch_drain_bad   <= 0;
        end else if (y_valid) begin
            automatic bit bad = 1'b0;
            for (int c = 0; c < COLS; c++)
                if (y_out[c] !== y_expected[c]) bad = 1'b1;
            batch_drain_count <= batch_drain_count + 1;
            if (bad) batch_drain_bad <= batch_drain_bad + 1;
        end
    end
    function automatic void pack_bfp12_tile(
        input  bfp12_mant_t                mants [BFP12_BLK],
        input  bfp12_exp_t                 shared_exp,
        output logic [URAM_WIDTH_BITS-1:0] out [4]
    );
        logic [143:0] cw [2];
        cw[0] = '0;
        cw[1] = '0;
        for (int i = 0; i < 8; i++)
            cw[0][i*BFP12_MANT_W +: BFP12_MANT_W] = mants[i];
        cw[0][96 +: BFP12_EXP_W] = shared_exp;
        for (int i = 0; i < 8; i++)
            cw[1][i*BFP12_MANT_W +: BFP12_MANT_W] = mants[8+i];
        out[0] = cw[0][URAM_WIDTH_BITS-1:0];
        out[1] = cw[0][2*URAM_WIDTH_BITS-1:URAM_WIDTH_BITS];
        out[2] = cw[1][URAM_WIDTH_BITS-1:0];
        out[3] = cw[1][2*URAM_WIDTH_BITS-1:URAM_WIDTH_BITS];
    endfunction
    function automatic void pack_weight_word(
        input  bfp12_mant_t                w8 [8],
        output logic [URAM_WIDTH_BITS-1:0] lo,
        output logic [URAM_WIDTH_BITS-1:0] hi
    );
        logic [143:0] cw;
        cw = '0;
        for (int s = 0; s < 8; s++)
            cw[s*BFP12_MANT_W +: BFP12_MANT_W] = w8[s];
        lo = cw[URAM_WIDTH_BITS-1:0];
        hi = cw[2*URAM_WIDTH_BITS-1:URAM_WIDTH_BITS];
    endfunction

    function automatic void pack_compute_beat(
        input  tern_lane_tiles_t      wbeat,
        ref    logic [URAM_WIDTH_BITS-1:0] dst [SPARSE_NATIVE_BEATS],
        input  int                    base_idx
    );
        logic [143:0] cw [4];
        for (int k = 0; k < 4; k++) cw[k] = '0;
        for (int l = 0; l < int'(TLMM_LANES); l++) begin
            for (int t = 0; t < int'(TLMM_TILE); t++) begin
                automatic int idx  = l * int'(TLMM_TILE) + t;
                automatic int word = idx / 64;
                automatic int bitp = (idx % 64) * 2;
                cw[word][bitp +: 2] = wbeat[l][t];
            end
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
            automatic array_acc_t acc;
            acc = '0;
            for (int gr = 0; gr < ROW_CNT; gr++) begin
                for (int r = 0; r < GRS; r++) begin
                    acc += array_acc_t'($signed(x_vec[gr*GRS + r])
                                      * $signed(weights_ref[gr*GRS + r][c]));
                end
            end
            y_expected[c] = acc;
        end
    endtask
    task automatic build_dense_image();
        bfp12_mant_t                w8       [8];
        logic [URAM_WIDTH_BITS-1:0] lo, hi;
        bfp12_mant_t                band     [BFP12_BLK];
        logic [URAM_WIDTH_BITS-1:0] beat_out [4];

        for (int i = 0; i < DENSE_NATIVE; i++) dense_native[i] = '0;
        for (int gr = 0; gr < ROW_CNT; gr++) begin
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
                        automatic int col        = gc*PHYS_COLS + phys*GCS + local_c;
                        w8[s] = weights_ref[row][col];
                    end
                    pack_weight_word(w8, lo, hi);
                    dense_native[tile_linear*NATIVE_PER_TILE + 2*w + 0] = lo;
                    dense_native[tile_linear*NATIVE_PER_TILE + 2*w + 1] = hi;
                end
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
        for (int b = 0; b < K_FFN; b++) begin
            for (int l = 0; l < int'(TLMM_LANES); l++) begin
                for (int t = 0; t < int'(TLMM_TILE); t++) begin
                    automatic int rsel = ($urandom_range(0,2));
                    unique case (rsel)
                        0:       ffn_wbeats[b][l][t] = TERN_ZERO;
                        1:       ffn_wbeats[b][l][t] = TERN_POS;
                        default: ffn_wbeats[b][l][t] = TERN_NEG;
                    endcase
                end
            end
        end
        for (int i = 0; i < int'(TLMM_TILE); i++) mants_local[i] = ffn_acts[i];
        pack_bfp12_tile(mants_local, bfp12_exp_t'(0), tile_words);
        for (int j = 0; j < 4; j++) sparse_native[j] = tile_words[j];
        for (int b = 0; b < K_FFN; b++) pack_compute_beat(ffn_wbeats[b], sparse_native, 4 + b*8);
    endtask
    typedef enum logic [1:0] { D_IDLE, D_REQ, D_RESP } dram_state_e;
    dram_state_e            dram_state_q;
    logic [DRAM_ADDR_W-1:0] dram_addr_q;
    logic [DRAM_LEN_W-1:0]  dram_len_q;
    logic [DRAM_LEN_W-1:0]  dram_idx_q;

    function automatic logic [DRAM_BEAT_W-1:0] dram_pattern(
        input logic [DRAM_ADDR_W-1:0] base_addr,
        input logic [DRAM_LEN_W-1:0]  idx
    );
        logic [DRAM_BEAT_W-1:0] v;
        v = '0;
        if (base_addr == DENSE_DRAM_BASE) begin
            if (int'(idx) < DENSE_NATIVE) v = dense_native[idx];
        end else if (base_addr == SPARSE_DRAM_BASE) begin
            if (int'(idx) < SPARSE_NATIVE_BEATS) v = sparse_native[idx];
        end
        return v;
    endfunction

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
                stub_rsp_data  = dram_pattern(dram_addr_q, dram_idx_q);
            end
            default: ;
        endcase
    end

    assign dram_req_ready = stub_req_ready;
    assign dram_rsp_valid = stub_rsp_valid;
    assign dram_rsp_last  = stub_rsp_last;
    assign dram_rsp_data  = stub_rsp_data;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dram_state_q <= D_IDLE;
            dram_addr_q  <= '0;
            dram_len_q   <= '0;
            dram_idx_q   <= '0;
        end else begin
            unique case (dram_state_q)
                D_IDLE: if (dram_req_valid) dram_state_q <= D_REQ;
                D_REQ : if (dram_req_valid) begin
                    dram_addr_q  <= dram_req_addr;
                    dram_len_q   <= dram_req_len;
                    dram_idx_q   <= '0;
                    dram_state_q <= D_RESP;
                end
                D_RESP: if (dram_rsp_ready && stub_rsp_valid) begin
                    if (stub_rsp_last) dram_state_q <= D_IDLE;
                    else               dram_idx_q   <= DRAM_LEN_W'(dram_idx_q + 1'b1);
                end
                default: dram_state_q <= D_IDLE;
            endcase
        end
    end
    int unsigned dram_wr_req_count;
    int unsigned dram_wr_beat_count;
    int unsigned sparse_wr_count;

    assign dram_wr_req_ready = 1'b1;
    assign dram_wr_wd_ready  = 1'b1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dram_wr_req_count  <= 0;
            dram_wr_beat_count <= 0;
            sparse_wr_count    <= 0;
        end else begin
            if (dram_wr_req_valid && dram_wr_req_ready) dram_wr_req_count++;
            if (dram_wr_wd_valid  && dram_wr_wd_ready ) dram_wr_beat_count++;
            if (sparse_out_wr_en)                       sparse_wr_count++;
        end
    end
    function automatic logic [MACRO_WORD_W-1:0] mk_instr(
        input macro_opc_e opc, input logic [7:0] tile_id,
        input logic [7:0] path_id_field, input logic [31:0] low32
    );
        logic [MACRO_WORD_W-1:0] w;
        w = '0; w[63:58]=opc; w[57:50]=tile_id; w[49:42]=path_id_field; w[31:0]=low32;
        return w;
    endfunction

    function automatic logic [MACRO_WORD_W-1:0] mk_instr_flags(
        input macro_opc_e opc, input logic [7:0] tile_id,
        input logic [7:0] path_id_field, input logic [11:0] flags
    );
        logic [MACRO_WORD_W-1:0] w;
        w = '0; w[63:58]=opc; w[57:50]=tile_id; w[49:42]=path_id_field; w[11:0]=flags;
        return w;
    endfunction

    function automatic logic [MACRO_WORD_W-1:0] mk_gemm_layer(
        input logic [7:0] path_id_field, input int row_cnt,
        input int col_cnt, input int k_cnt
    );
        logic [MACRO_WORD_W-1:0] w;
        w = '0; w[63:58]=OP_GEMM_LAYER; w[49:42]=path_id_field;
        w[41:32]=row_cnt[9:0]; w[31:22]=col_cnt[9:0]; w[21:12]=k_cnt[9:0];
        return w;
    endfunction
    function automatic logic [MACRO_WORD_W-1:0] mk_gemm_batch(
        input logic [7:0] batch_t, input logic [7:0] path_id_field,
        input int row_cnt, input int col_cnt, input int k_cnt
    );
        logic [MACRO_WORD_W-1:0] w;
        w = '0; w[63:58]=OP_GEMM_BATCH; w[57:50]=batch_t; w[49:42]=path_id_field;
        w[41:32]=row_cnt[9:0]; w[31:22]=col_cnt[9:0]; w[21:12]=k_cnt[9:0];
        return w;
    endfunction

    function automatic logic [31:0] mk_meta_payload(
        input logic [5:0] src_node, input logic [2:0] priority_lvl, input logic is_multicast
    );
        logic [31:0] p;
        p = '0; p[9:4]=src_node; p[3:1]=priority_lvl; p[0]=is_multicast;
        return p;
    endfunction

    function automatic logic [31:0] mk_kcnt_payload(input int k_cnt);
        logic [31:0] p;
        p = '0; p[21:12] = k_cnt[9:0];
        return p;
    endfunction

    task automatic imem_write(
        input logic [IMEM_ADDR_W-1:0] addr, input logic [MACRO_WORD_W-1:0] word
    );
        @(negedge clk); imem_we = 1'b1; imem_wr_addr = addr; imem_wr_data = word;
        @(negedge clk); imem_we = 1'b0;
    endtask

    task automatic write_desc(
        input logic [7:0] tile_id, input logic is_sparse_f,
        input logic [URAM_AW-1:0] uram_base, input logic [DRAM_ADDR_W-1:0] dram_base,
        input logic [DRAM_LEN_W-1:0] n_beats
    );
        csd_descriptor_t d;
        d.compressed = 1'b0; d.is_sparse = is_sparse_f;
        d.uram_base = uram_base; d.dram_base = dram_base; d.n_beats = n_beats;
        @(negedge clk); desc_we = 1'b1; desc_wr_addr = tile_id; desc_wr_data = d;
        @(negedge clk); desc_we = 1'b0;
    endtask
    integer a;
    int     waited;

    initial begin : main
        rst_n        = 1'b0;
        start        = 1'b0;
        imem_we      = 1'b0;
        imem_wr_addr = '0;
        imem_wr_data = '0;
        desc_we      = 1'b0;
        desc_wr_addr = '0;
        desc_wr_data = '0;
        kv_wr_data_i = '0;
        n_checks     = 0;
        n_errors     = 0;
        dense_weight_base_addr  = URAM_ADDR_W'(0);
        dense_act_base_addr     = URAM_ADDR_W'(ACT_CASC_BASE);
        tlmm_base_addr          = URAM_ADDR_W'(0);
        out_collector_base_addr = URAM_ADDR_W'(0);
        sparse_out_base_addr    = URAM_ADDR_W'(256);

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
        $display("[%0t] STAGE 0: build weights/x + golden + URAM images (%0dx%0d tiles, K=%0d)",
                 $time, ROW_CNT, COL_CNT, K_TILE);
        build_weights_and_x();
        build_golden();
        build_dense_image();
        build_sparse_image();
        $display("[%0t]   dense image = %0d native words (weights %0d + acts %0d)",
                 $time, DENSE_NATIVE, WEIGHT_NATIVE, ACT_NATIVE);
        $display("[%0t] STAGE 1: load CSD descriptors", $time);
        write_desc(8'd0, 1'b0, URAM_AW'(0), DENSE_DRAM_BASE, DRAM_LEN_W'(DENSE_NATIVE));
        write_desc(8'd1, 1'b1, URAM_AW'(0), SPARSE_DRAM_BASE, DRAM_LEN_W'(SPARSE_NATIVE_BEATS));
        write_desc(8'd2, 1'b0, URAM_AW'(0), STOUT_DRAM_BASE, DRAM_LEN_W'(COLS));
        $display("[%0t] STAGE 2: load imem program", $time);
        a = 0;
        imem_write(IMEM_ADDR_W'(a), mk_instr_flags(OP_LD_W_URAM, 8'h00, 8'h00, 12'h000)); a++;
        imem_write(IMEM_ADDR_W'(a), mk_instr_flags(OP_LD_W_URAM, 8'h01, 8'h00,
                               12'h000 | (1 << FLG_IS_SPARSE))); a++;
        imem_write(IMEM_ADDR_W'(a), mk_instr_flags(OP_PINGPONG,  8'h00, 8'h00, 12'h000)); a++;
        imem_write(IMEM_ADDR_W'(a), mk_instr_flags(OP_PINGPONG,  8'h01, 8'h00,
                               12'h000 | (1 << FLG_IS_SPARSE))); a++;
        imem_write(IMEM_ADDR_W'(a), mk_instr(OP_CFG_NOC, {6'd0, CFG_NOC_MASK_LO},
                               {3'd0, TGT_HANDLE}, TGT_MASK_LO)); a++;
        imem_write(IMEM_ADDR_W'(a), mk_instr(OP_CFG_NOC, {6'd0, CFG_NOC_MASK_HI},
                               {3'd0, TGT_HANDLE}, TGT_MASK_HI)); a++;
        imem_write(IMEM_ADDR_W'(a), mk_instr(OP_CFG_NOC, {6'd0, CFG_NOC_META},
                               {3'd0, TGT_HANDLE},
                               mk_meta_payload(TGT_SRC_NODE, TGT_PRIORITY, TGT_IS_MULTICAST))); a++;
        imem_write(IMEM_ADDR_W'(a), mk_instr(OP_BARRIER,    8'h00, 8'h00, 32'h0)); a++;
        imem_write(IMEM_ADDR_W'(a), mk_instr(OP_COMMIT_NOC, 8'h00, 8'h00, 32'h0)); a++;
        imem_write(IMEM_ADDR_W'(a),
                   mk_gemm_batch(8'(BATCH_TOK), 8'h00, ROW_CNT, COL_CNT, K_TILE)); a++;
        imem_write(IMEM_ADDR_W'(a), mk_instr(OP_BARRIER, 8'h00, 8'h00, 32'h0)); a++;
        imem_write(IMEM_ADDR_W'(a), mk_instr(OP_FFN_TLMM,   8'h00, 8'h00,
                               mk_kcnt_payload(K_FFN))); a++;
        imem_write(IMEM_ADDR_W'(a), mk_instr_flags(OP_ST_OUT, 8'h02, 8'h00, 12'h000)); a++;
        imem_write(IMEM_ADDR_W'(a), mk_instr_flags(OP_EOP,    8'h00, 8'h00, 12'h000)); a++;
        $display("[%0t] STAGE 3: start dispatcher", $time);
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;

        waited = 0;
        while (!program_done) begin
            @(posedge clk);
            waited++;
            if (waited > 200_000)
                $fatal(1, "tb_archbetter_core: program_done never asserted (%0d cycles)", waited);
        end
        $display("[%0t] program_done after %0d cycles", $time, waited);
        waited = 0;
        while (batch_drain_count < BATCH_TOK) begin
            @(posedge clk);
            waited++;
            if (waited > 50_000) begin
                $error("tb_archbetter_core: batched drain stalled at %0d/%0d",
                       batch_drain_count, BATCH_TOK);
                break;
            end
        end
        repeat (8) @(posedge clk);
        $display("[%0t] STAGE 4: checks", $time);
        chk(y_snap_seen, "dense y_valid never pulsed (layer never drained)");
        if (y_snap_seen) begin
            for (int c = 0; c < COLS; c++) begin
                chk(y_snapped[c] === y_expected[c],
                    $sformatf("y[%0d]: got %0d exp %0d", c,
                              $signed(y_snapped[c]), $signed(y_expected[c])));
            end
            $display("[%0t]   GEMM full-layer result checked (%0d cols, %0d used)",
                     $time, COLS, USED_COLS);
        end

        chk(dram_wr_req_count >= 1, "ST_OUT issued no DRAM write request");
        chk(dram_wr_beat_count == COLS,
            $sformatf("ST_OUT drained %0d beats, expected %0d", dram_wr_beat_count, COLS));
        chk(sparse_wr_count == TLMM_LANES,
            $sformatf("sparse collector wrote %0d words, expected %0d",
                      sparse_wr_count, TLMM_LANES));
        chk(batch_drain_count == BATCH_TOK,
            $sformatf("batched drain produced %0d outputs, expected %0d",
                      batch_drain_count, BATCH_TOK));
        chk(batch_drain_bad == 0,
            $sformatf("%0d batched outputs mismatched the golden", batch_drain_bad));
        $display("[%0t] STAGE 5: throughput / activity (C1.5 weight-resident batch)", $time);
        chk(yv_count == BATCH_TOK,
            $sformatf("y_valid pulsed %0d times, expected %0d tokens",
                      yv_count, BATCH_TOK));
        begin
            automatic int unsigned prog_cyc = (done_seen && start_seen)
                                            ? (done_cyc - start_cyc) : 0;
            automatic int unsigned ttft_cyc = (yv_count > 0 && start_seen)
                                            ? (yv_first_cyc - start_cyc) : 0;
            automatic int wloads_batched = ROW_CNT * COL_CNT;
            automatic int wloads_reload  = ROW_CNT * COL_CNT * BATCH_TOK;
            $display("  tokens (y_valid drains) = %0d  (expected %0d)", yv_count, BATCH_TOK);
            $display("  total program cycles    = %0d", prog_cyc);
            $display("  first-token latency     = %0d cyc", ttft_cyc);
            $display("  weight tile-loads       = %0d  (reload-per-token = %0d -> %0dx fewer)",
                     wloads_batched, wloads_reload, BATCH_TOK);
            $display("  MACs (batch)            = %0d   (peak %0d MAC/cyc)",
                     MACS_BATCH, DENSE_PE_TOTAL);
            if (prog_cyc > 0) begin
                automatic real per_tok = real'(prog_cyc) / real'(BATCH_TOK);
                automatic real mpc     = real'(MACS_BATCH) / real'(prog_cyc);
                automatic real util    = 100.0 * mpc / real'(DENSE_PE_TOTAL);
                automatic real gops    = mpc * 2.0 * TARGET_FREQ_HZ / 1.0e9;
                $display("  amortized cycles/token  = %0.1f  (incl. one-time fill+FFN; prior decode ~7306)",
                         per_tok);
                $display("  aggregate MAC/cycle     = %0.2f / %0d   (DSP util = %0.2f%%)",
                         mpc, DENSE_PE_TOTAL, util);
                $display("  aggregate GOPS @ %0.0f MHz = %0.2f", TARGET_FREQ_HZ/1.0e6, gops);
                $display("  NOTE: v1 serial-per-token snap caps util ~12.5%% (3-cyc fused-MACC drain/token); v2 pipelined snap targets compute-bound. The win HERE is %0dx fewer weight loads.",
                         BATCH_TOK);
            end
        end
        repeat (4) @(posedge clk);
        if (n_errors == 0)
            $display("tb_archbetter_core: PASS  (%0d checks, 0 errors)", n_checks);
        else
            $display("tb_archbetter_core: FAIL  (%0d errors / %0d checks)", n_errors, n_checks);
        $finish;
    end
    initial begin : watchdog
        #(T_CLK * 400_000);
        $fatal(1, "tb_archbetter_core: watchdog timeout");
    end

endmodule : tb_archbetter_core

`default_nettype wire
