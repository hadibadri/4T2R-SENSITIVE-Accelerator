
`ifndef ARCHBETTER_TB_ARCHBETTER_TOP_SV
`define ARCHBETTER_TB_ARCHBETTER_TOP_SV
`default_nettype none
`timescale 1ns/1ps

module tb_archbetter_top
    import types_pkg::*;
();
    localparam time T_CLK       = 10ns;
    localparam int  IMEM_DEPTH  = 64;
    localparam int  IMEM_ADDR_W = $clog2(IMEM_DEPTH);

    localparam int  ROWS  = DENSE_ARRAY_ROWS;
    localparam int  COLS  = DENSE_ARRAY_COLS;
    localparam int  GROWS = DENSE_GROUPS_ROW;
    localparam int  GCOLS = DENSE_GROUPS_COL;
    localparam int  GRS   = DENSE_GROUP_ROWS;
    localparam int  GCS   = DENSE_GROUP_COLS;
    localparam int  PE_ADDR_W = $clog2(DENSE_PE_PER_GROUP);

    localparam int  K_GEMM = 2;
    localparam int  K_FFN  = 3;
    localparam int  DENSE_NATIVE_BEATS  = 4 * K_GEMM;
    localparam int  SPARSE_NATIVE_BEATS = 4 + 8 * K_FFN;

    localparam int  URAM_AW = URAM_ADDR_W;

    localparam logic [DRAM_ADDR_W-1:0] DENSE_DRAM_BASE  = 'h1000_0000;
    localparam logic [DRAM_ADDR_W-1:0] SPARSE_DRAM_BASE = 'h2000_0000;

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
    logic                                          w_we;
    logic [$clog2(GROWS)-1:0]                      w_gr;
    logic [$clog2(GCOLS)-1:0]                      w_gc;
    logic [PE_ADDR_W-1:0]                          w_pe_addr;
    bfp12_mant_t                                   w_in;
    logic [$clog2(DENSE_LOGICAL_TILE_ROWS)-1:0]    tile_gr;
    logic [$clog2(DENSE_LOGICAL_TILE_COLS)-1:0]    tile_gc;
    logic                                          tile_first;
    logic                                          tile_last;
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
    archbetter_top #(
        .IMEM_DEPTH    (IMEM_DEPTH),
        .N_NOC_SOURCES (1),
        .D2S_FIFO_DEPTH(64)
    ) dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .start                (start),
        .program_done         (program_done),
        .imem_we              (imem_we),
        .imem_wr_addr         (imem_wr_addr),
        .imem_wr_data         (imem_wr_data),
        .desc_we              (desc_we),
        .desc_wr_addr         (desc_wr_addr),
        .desc_wr_data         (desc_wr_data),
        .w_we                 (w_we),
        .w_gr                 (w_gr),
        .w_gc                 (w_gc),
        .w_pe_addr            (w_pe_addr),
        .w_in                 (w_in),
        .tile_gr              (tile_gr),
        .tile_gc              (tile_gc),
        .tile_first           (tile_first),
        .tile_last            (tile_last),
        .dense_act_base_addr  (dense_act_base_addr),
        .tlmm_base_addr       (tlmm_base_addr),
        .out_collector_base_addr (out_collector_base_addr),
        .sparse_out_base_addr (sparse_out_base_addr),
        .kv_wr_data_i         (kv_wr_data_i),
        .kv_rd_data_o         (kv_rd_data_o),
        .kv_rd_valid_o        (kv_rd_valid_o),
        .y_out                (y_out),
        .y_valid              (y_valid),
        .sparse_out_wr_en     (sparse_out_wr_en),
        .sparse_out_wr_addr   (sparse_out_wr_addr),
        .sparse_out_wr_data   (sparse_out_wr_data),
        .d2s_data_o           (d2s_data_o),
        .d2s_user_o           (d2s_user_o),
        .d2s_valid_o          (d2s_valid_o),
        .d2s_ready_i          (d2s_ready_i),
        .d2s_last_o           (d2s_last_o),
        .d2s_almost_full_i    (d2s_almost_full_i),
        .dram_req_addr        (dram_req_addr),
        .dram_req_len         (dram_req_len),
        .dram_req_valid       (dram_req_valid),
        .dram_req_ready       (dram_req_ready),
        .dram_rsp_data        (dram_rsp_data),
        .dram_rsp_valid       (dram_rsp_valid),
        .dram_rsp_ready       (dram_rsp_ready),
        .dram_rsp_last        (dram_rsp_last),
        .dram_wr_req_addr     (dram_wr_req_addr),
        .dram_wr_req_len      (dram_wr_req_len),
        .dram_wr_req_valid    (dram_wr_req_valid),
        .dram_wr_req_ready    (dram_wr_req_ready),
        .dram_wr_wd_data      (dram_wr_wd_data),
        .dram_wr_wd_valid     (dram_wr_wd_valid),
        .dram_wr_wd_ready     (dram_wr_wd_ready),
        .dram_wr_wd_last      (dram_wr_wd_last)
    );
    assign tile_gr   = '0;
    assign tile_gc   = '0;
    assign tile_last = dut.gemm_bus.acc_snap;
    bfp12_mant_t           weights_ref [ROWS][COLS];
    bfp12_mant_t           a_gemm_vec  [K_GEMM][BFP12_BLK];
    array_acc_t [COLS-1:0] y_expected;
    array_acc_t [COLS-1:0] y_snapped;
    logic                  y_snap_seen;

    bfp12_mant_t      ffn_acts   [TLMM_TILE];
    tern_lane_tiles_t ffn_wbeats [K_FFN];
    tlmm_part_vec_t   ffn_expected_q [$];
    tlmm_part_vec_t   ffn_captured_q [$];
    logic [URAM_WIDTH_BITS-1:0] dense_native  [DENSE_NATIVE_BEATS];
    logic [URAM_WIDTH_BITS-1:0] sparse_native [SPARSE_NATIVE_BEATS];
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            y_snapped   <= '{default: '0};
            y_snap_seen <= 1'b0;
        end else if (y_valid) begin
            y_snapped   <= y_out;
            y_snap_seen <= 1'b1;
        end
    end
    always_ff @(posedge clk) begin
        if (rst_n && dut.tlmm_ctrl.o_valid && dut.tlmm_ctrl.o_ready) begin
            ffn_captured_q.push_back(dut.tlmm_ctrl.o_parts);
        end
    end
    int unsigned d2s_beat_count;
    assign d2s_ready_i       = 1'b1;
    assign d2s_almost_full_i = 1'b0;

    always_ff @(posedge clk) begin
        if (!rst_n) d2s_beat_count <= 0;
        else if (d2s_valid_o && d2s_ready_i) d2s_beat_count <= d2s_beat_count + 1;
    end
    typedef enum logic [1:0] {
        D_IDLE = 2'b00,
        D_REQ  = 2'b01,
        D_RESP = 2'b10
    } dram_state_e;

    dram_state_e            dram_state_q;
    logic [DRAM_ADDR_W-1:0] dram_addr_q;
    logic [DRAM_LEN_W-1:0]  dram_len_q;
    logic [DRAM_LEN_W-1:0]  dram_idx_q;

    function automatic logic [DRAM_BEAT_W-1:0] dram_pattern (
        input logic [DRAM_ADDR_W-1:0] base_addr,
        input logic [DRAM_LEN_W-1:0]  idx
    );
        logic [DRAM_BEAT_W-1:0] v;
        v = '0;
        if (base_addr == DENSE_DRAM_BASE) begin
            if (int'(idx) < DENSE_NATIVE_BEATS)
                v = dense_native[idx];
        end else if (base_addr == SPARSE_DRAM_BASE) begin
            if (int'(idx) < SPARSE_NATIVE_BEATS)
                v = sparse_native[idx];
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

    assign dram_wr_req_ready = 1'b1;
    assign dram_wr_wd_ready  = 1'b1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dram_wr_req_count  <= 0;
            dram_wr_beat_count <= 0;
        end else begin
            if (dram_wr_req_valid && dram_wr_req_ready) dram_wr_req_count++;
            if (dram_wr_wd_valid  && dram_wr_wd_ready ) dram_wr_beat_count++;
        end
    end
    logic [KV_DATA_W-1:0] kv_mirror [2**KV_ADDR_W];

    typedef struct packed {
        logic                 is_read;
        logic [KV_ADDR_W-1:0] addr;
        logic [KV_DATA_W-1:0] data;
    } kv_obs_t;

    kv_obs_t kv_exp_q [$];
    kv_obs_t kv_obs_q [$];
    logic [KV_ADDR_W-1:0] kv_rd_addr_s1, kv_rd_addr_s2;

    wire                 dut_kv_wr_en   = dut.u_dispatcher.kv.wr_en;
    wire [KV_ADDR_W-1:0] dut_kv_wr_addr = dut.u_dispatcher.kv.wr_addr;
    wire [KV_DATA_W-1:0] dut_kv_wr_data = dut.u_dispatcher.kv.wr_data;
    wire                 dut_kv_rd_en   = dut.u_dispatcher.kv.rd_en;
    wire [KV_ADDR_W-1:0] dut_kv_rd_addr = dut.u_dispatcher.kv.rd_addr;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            kv_rd_addr_s1 <= '0;
            kv_rd_addr_s2 <= '0;
        end else begin
            kv_rd_addr_s1 <= dut_kv_rd_addr;
            kv_rd_addr_s2 <= kv_rd_addr_s1;

            if (dut_kv_wr_en) begin
                kv_obs_t e;
                e.is_read = 1'b0;
                e.addr    = dut_kv_wr_addr;
                e.data    = dut_kv_wr_data;
                kv_obs_q.push_back(e);
            end
            if (kv_rd_valid_o) begin
                kv_obs_t e;
                e.is_read = 1'b1;
                e.addr    = kv_rd_addr_s2;
                e.data    = kv_rd_data_o;
                kv_obs_q.push_back(e);
            end
        end
    end

    always_comb begin
        kv_wr_data_i = '0;
        if (rst_n) begin
            automatic logic [MACRO_WORD_W-1:0] cur     = dut.u_dispatcher.imem[dut.u_dispatcher.pc];
            automatic logic [MACRO_OPC_W-1:0]  cur_opc = cur[63:58];
            automatic logic [KV_ADDR_W-1:0]    cur_addr;
            cur_addr = {cur[47:42], cur[57:50]};
            if (cur_opc == OP_KV_WRITE) begin
                kv_wr_data_i = kv_mirror[cur_addr];
            end
        end
    end
    function automatic tlmm_tile_part_t golden_lane_partial(
        input bfp12_mant_t acts [TLMM_TILE],
        input tern_tile_t  w
    );
        automatic int acc;
        acc = 0;
        for (int i = 0; i < int'(TLMM_TILE); i++) begin
            unique case (w[i])
                TERN_POS : acc += $signed(acts[i]);
                TERN_NEG : acc -= $signed(acts[i]);
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
                v[l] = golden_lane_partial(ffn_acts, ffn_wbeats[b][l]);
            end
            ffn_expected_q.push_back(v);
        end
    endtask
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
    function automatic void pack_compute_beat(
        input  tern_lane_tiles_t      wbeat,
        ref    logic [URAM_WIDTH_BITS-1:0] dst [SPARSE_NATIVE_BEATS],
        input  int                    base_idx
    );
        logic [143:0] cw [4];
        for (int k = 0; k < 4; k++) cw[k] = '0;
        for (int l = 0; l < int'(TLMM_LANES); l++) begin
            for (int t = 0; t < int'(TLMM_TILE); t++) begin
                automatic int idx = l * int'(TLMM_TILE) + t;
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

    task automatic build_dense_uram();
        bfp12_mant_t                mants_local [BFP12_BLK];
        logic [URAM_WIDTH_BITS-1:0] tile_words  [4];
        for (int k = 0; k < K_GEMM; k++) begin
            for (int i = 0; i < BFP12_BLK; i++)
                mants_local[i] = a_gemm_vec[k][i];
            pack_bfp12_tile(mants_local, bfp12_exp_t'(0), tile_words);
            for (int j = 0; j < 4; j++)
                dense_native[k * 4 + j] = tile_words[j];
        end
    endtask

    task automatic build_sparse_uram();
        bfp12_mant_t                mants_local [BFP12_BLK];
        logic [URAM_WIDTH_BITS-1:0] tile_words  [4];
        for (int i = 0; i < BFP12_BLK; i++) mants_local[i] = ffn_acts[i];
        pack_bfp12_tile(mants_local, bfp12_exp_t'(0), tile_words);
        for (int j = 0; j < 4; j++)
            sparse_native[j] = tile_words[j];
        for (int b = 0; b < K_FFN; b++) begin
            pack_compute_beat(ffn_wbeats[b], sparse_native, 4 + b*8);
        end
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
            for (int r = 0; r < BFP12_BLK; r++) begin
                a_gemm_vec[k][r] = bfp12_mant_t'(signed'(k*10 + r + 1));
            end
        end
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
    task automatic program_weights();
        for (int local_r = 0; local_r < GRS; local_r++) begin
            for (int local_c = 0; local_c < GCS; local_c++) begin
                @(posedge clk);
                w_we      <= 1'b1;
                w_gr      <= '0;
                w_gc      <= ($clog2(GCOLS))'(0);
                w_pe_addr <= PE_ADDR_W'(local_r * GCS + local_c);
                w_in      <= weights_ref[local_r][local_c];
                @(posedge clk);
                w_we      <= 1'b1;
                w_gr      <= '0;
                w_gc      <= ($clog2(GCOLS))'(1);
                w_pe_addr <= PE_ADDR_W'(local_r * GCS + local_c);
                w_in      <= weights_ref[local_r][GCS + local_c];
            end
        end
        @(posedge clk);
        w_we <= 1'b0;
        w_in <= '0;
    endtask
    int n_errors;
    int n_checks;

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
    initial begin : main
        logic [IMEM_ADDR_W-1:0] a;
        int waited;
        logic [KV_DATA_W-1:0]   kv_val_0, kv_val_1, kv_val_2;
        logic [KV_ADDR_W-1:0]   kv_addr_0, kv_addr_1, kv_addr_2;

        n_errors      = 0;
        n_checks      = 0;
        rst_n         = 1'b0;
        start         = 1'b0;
        imem_we       = 1'b0;
        imem_wr_addr  = '0;
        imem_wr_data  = '0;
        desc_we       = 1'b0;
        desc_wr_addr  = '0;
        desc_wr_data  = '0;
        w_we          = 1'b0;
        w_gr          = '0;
        w_gc          = '0;
        w_pe_addr     = '0;
        w_in          = '0;
        tile_first    = 1'b0;
        dense_act_base_addr     = '0;
        tlmm_base_addr          = '0;
        out_collector_base_addr = '0;
        sparse_out_base_addr    = URAM_ADDR_W'(256);

        for (int i = 0; i < 2**KV_ADDR_W; i++) kv_mirror[i] = '0;
        for (int i = 0; i < DENSE_NATIVE_BEATS; i++)  dense_native[i]  = '0;
        for (int i = 0; i < SPARSE_NATIVE_BEATS; i++) sparse_native[i] = '0;

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
        $display("[%0t] STAGE 0: fill weight plane + build vectors + pack URAM", $time);
        fill_weights_diag_mix();
        build_gemm_vectors();
        build_ffn_vectors();
        build_dense_uram();
        build_sparse_uram();

        $display("[%0t] STAGE 1: scan tile(0,0) 16x32 dense weights", $time);
        program_weights();

        $display("[%0t] STAGE 2: load CSD descriptors", $time);
        write_desc(8'd0, 1'b0, URAM_AW'(0),
                   DENSE_DRAM_BASE,
                   DRAM_LEN_W'(DENSE_NATIVE_BEATS));
        write_desc(8'd1, 1'b1, URAM_AW'(0),
                   SPARSE_DRAM_BASE,
                   DRAM_LEN_W'(SPARSE_NATIVE_BEATS));
        write_desc(8'd2, 1'b0, URAM_AW'(0),
                   DRAM_ADDR_W'(32'h3000_0000),
                   DRAM_LEN_W'(DENSE_ARRAY_COLS));
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
        imem_write(a, mk_instr_flags(OP_ST_OUT,     8'h02, 8'h00, 12'h000)); a++;
        imem_write(a, mk_instr_flags(OP_EOP,        8'h00, 8'h00, 12'h000)); a++;
        kv_exp_q.push_back('{is_read:1'b0, addr:kv_addr_0, data:kv_val_0});
        kv_exp_q.push_back('{is_read:1'b0, addr:kv_addr_1, data:kv_val_1});
        kv_exp_q.push_back('{is_read:1'b0, addr:kv_addr_2, data:kv_val_2});
        kv_exp_q.push_back('{is_read:1'b1, addr:kv_addr_0, data:kv_val_0});
        kv_exp_q.push_back('{is_read:1'b1, addr:kv_addr_2, data:kv_val_2});
        kv_exp_q.push_back('{is_read:1'b1, addr:kv_addr_1, data:kv_val_1});
        $display("[%0t] STAGE 4: start dispatcher", $time);
        @(negedge clk);
        tile_first = 1'b1;
        @(negedge clk);
        tile_first = 1'b0;

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        waited = 0;
        while (!program_done) begin
            @(posedge clk);
            waited++;
            if (waited > 100_000) begin
                $fatal(1, "tb_archbetter_top: program_done never asserted after %0d cycles",
                       waited);
            end
        end
        $display("[%0t] program_done asserted after %0d cycles", $time, waited);

        repeat (32) @(posedge clk);
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
        $display("[%0t] STAGE 7: check KV sequence", $time);
        compare_kv_queues();
        $display("[%0t] STAGE 8: check DRAM write activity from OP_ST_OUT", $time);
        n_checks++;
        if (dram_wr_req_count == 0) begin
            n_errors++;
            $error("ST_OUT: no DRAM write request observed");
        end else if (dram_wr_beat_count == 0) begin
            n_errors++;
            $error("ST_OUT: write request observed but no beats fired");
        end else begin
            $display("[%0t] ST_OUT: %0d req(s), %0d beat(s) drained",
                     $time, dram_wr_req_count, dram_wr_beat_count);
        end
        $display("[%0t] STAGE 9: check d2s forwarding beats", $time);
        n_checks++;
        if (d2s_beat_count != int'(DENSE_ARRAY_COLS / BFP12_BLK)) begin
            n_errors++;
            $error("D2S: observed %0d beats, expected %0d",
                   d2s_beat_count, DENSE_ARRAY_COLS / BFP12_BLK);
        end else begin
            $display("[%0t] D2S: %0d beats forwarded", $time, d2s_beat_count);
        end
        if (n_errors == 0 && n_checks > 0) begin
            $display("=========================================================");
            $display(" tb_archbetter_top: PASS  (%0d checks, 0 errors)", n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_archbetter_top: FAIL  (%0d checks, %0d errors)",
                     n_checks, n_errors);
            $display("=========================================================");
        end
        $finish;
    end
    initial begin : watchdog
        #(T_CLK * 2_000_000);
        $fatal(1, "tb_archbetter_top: watchdog timeout");
    end

endmodule : tb_archbetter_top

`default_nettype wire
`endif
