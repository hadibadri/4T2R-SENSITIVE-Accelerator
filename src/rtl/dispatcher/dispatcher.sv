
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
    input  wire logic                         start,
    output logic                              program_done,
    input  wire logic                         imem_we,
    input  wire logic [IMEM_ADDR_W-1:0]       imem_wr_addr,
    input  wire logic [MACRO_WORD_W-1:0]      imem_wr_data,
    output logic [NOC_PATH_ID_W-1:0]          path_id_o [N_NOC_SOURCES],
    noc_cfg_if.master                         noc_cfg,
    gemm_issue_if.disp                        gemm,
    tlmm_issue_if.disp                        tlmm,
    dense_sched_if.walker                     sched,
    mem_issue_if.disp                         mem_issue,
    kv_access_if.master                       kv,
    input  wire logic [KV_DATA_W-1:0]         kv_wr_data_i,
    input  wire logic                         dense_drain_busy
);
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
    (* ram_style = "distributed" *)
    logic [MACRO_WORD_W-1:0] imem [IMEM_DEPTH];

    always_ff @(posedge clk) begin
        if (imem_we) begin
            imem[imem_wr_addr] <= imem_wr_data;
        end
    end
    logic [IMEM_ADDR_W-1:0] pc;
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
    assign instr_row_cnt = instr_raw[41:32];
    assign instr_col_cnt = instr_raw[31:22];
    assign instr_k_cnt   = instr_raw[21:12];
    assign cfg_chunk     = instr_tile_id[1:0];
    assign src_sel       = instr_tile_id[4:2];
    localparam int unsigned TGR_W     = $clog2(DENSE_LOGICAL_TILE_ROWS);
    localparam int unsigned TGC_W     = $clog2(DENSE_LOGICAL_TILE_COLS);
    localparam int unsigned ROW_CNT_W = $clog2(DENSE_LOGICAL_TILE_ROWS + 1);
    localparam int unsigned COL_CNT_W = $clog2(DENSE_LOGICAL_TILE_COLS + 1);
    typedef enum logic [3:0] {
        S_IDLE        = 4'd0,
        S_EXEC        = 4'd1,
        S_GEMM_ACC    = 4'd2,
        S_GEMM_DRAIN  = 4'd3,
        S_GEMM_SNAP   = 4'd4,
        S_FFN_WAIT    = 4'd5,
        S_MEM_WAIT    = 4'd6,
        S_DONE        = 4'd7,
        S_LAYER_WLOAD = 4'd8,
        S_BATCH_REARM = 4'd9,
        S_GEMM_CONT   = 4'd10,
        S_GEMM_CFLUSH = 4'd11
    } disp_state_e;

    disp_state_e state;
    logic [31:0] stg_mask_lo;
    logic [31:0] stg_mask_hi;

    logic                          cfg_pending;
    logic [NOC_PATH_ID_W-1:0]      cfg_handle_r;
    noc_path_cfg_t                 cfg_cfg_r;
    logic path_commit_r;
    logic program_done_r;
    logic [NOC_PATH_ID_W-1:0] path_id_r [N_NOC_SOURCES];
    logic [MACRO_CNT_W-1:0] gemm_k_rem;
    logic [MACRO_CNT_W-1:0] gemm_k_cnt_r;
    logic                   gemm_first_done_r;
    logic                   gemm_busy_r;
    localparam int unsigned GEMM_DRAIN_CYCLES = 3;
    logic [$clog2(GEMM_DRAIN_CYCLES)-1:0] gemm_drain_cnt;
    logic [TGR_W-1:0]     gemm_tile_gr_r;
    logic [TGC_W-1:0]     gemm_tile_gc_r;
    logic [ROW_CNT_W-1:0] gemm_row_cnt_r;
    logic [COL_CNT_W-1:0] gemm_col_cnt_r;
    logic                 gemm_is_layer_r;
    logic                 layer_first_tile_r;
    logic                 load_req_r;
    logic                 load_busy_r;
    logic                   gemm_is_batch_r;
    logic [BATCH_TOK_W-1:0] gemm_batch_n_r;
    logic [BATCH_TOK_W-1:0] gemm_tok_r;
    logic                   gemm_is_cont_r;
    localparam int unsigned GEMM_CONT_FLUSH = DENSE_CONT_RESULT_LAT;
    logic [$clog2(GEMM_CONT_FLUSH+1)-1:0] gemm_cflush_cnt;
    logic gemm_is_last_tile_c;
    assign gemm_is_last_tile_c =
        (gemm_tile_gr_r == TGR_W'(gemm_row_cnt_r - 1'b1)) &&
        (gemm_tile_gc_r == TGC_W'(gemm_col_cnt_r - 1'b1));
    logic gemm_is_last_tok_c;
    assign gemm_is_last_tok_c =
        !gemm_is_batch_r || (gemm_tok_r == (gemm_batch_n_r - BATCH_TOK_W'(1)));
    logic gemm_acc_clr_c;
    logic gemm_acc_snap_c;
    assign gemm_acc_clr_c  = ((state == S_GEMM_ACC)
                              && gemm.beat_fire
                              && !gemm_first_done_r)
                          ||  ((state == S_GEMM_CONT) && gemm.beat_fire);
    assign gemm_acc_snap_c = (state == S_GEMM_SNAP);
    logic [MACRO_CNT_W-1:0] tlmm_k_cnt_r;
    logic                   tlmm_start_r;
    logic                   tlmm_busy_r;
    logic                   mem_start_r;
    logic                   mem_busy_r;
    macro_opc_e             mem_opc_r;
    logic [7:0]             mem_tile_id_r;
    logic                   mem_is_sparse_r;
    logic                   kv_wr_en_r;
    logic                   kv_rd_en_r;
    logic [KV_ADDR_W-1:0]   kv_wr_addr_r;
    logic [KV_ADDR_W-1:0]   kv_rd_addr_r;
    logic [KV_DATA_W-1:0]   kv_wr_data_r;
    assign noc_cfg.handle      = cfg_handle_r;
    assign noc_cfg.cfg         = cfg_cfg_r;
    assign noc_cfg.cfg_valid   = cfg_pending;
    assign noc_cfg.path_commit = path_commit_r;
    assign program_done        = program_done_r;
    always_comb begin
        for (int s = 0; s < int'(N_NOC_SOURCES); s++) begin
            path_id_o[s] = path_id_r[s];
        end
    end
    assign gemm.path_id  = path_id_r[0];
    assign gemm.k_cnt    = gemm_k_cnt_r;
    assign gemm.acc_clr  = gemm_acc_clr_c;
    assign gemm.acc_snap = gemm_acc_snap_c;
    assign gemm.busy     = gemm_busy_r;
    assign gemm.stream_mode = gemm_is_cont_r ? GEMM_SNAP_CONTINUOUS
                                             : GEMM_SNAP_PER_TOKEN;
    assign gemm.batch_n  = gemm_batch_n_r;
    assign sched.tile_gr    = gemm_tile_gr_r;
    assign sched.tile_gc    = gemm_tile_gc_r;
    assign sched.tile_first = gemm_is_layer_r && layer_first_tile_r
                            && gemm.beat_fire && !gemm_first_done_r;
    assign sched.tile_last  = gemm_is_layer_r && gemm_is_last_tile_c
                            && gemm_is_last_tok_c
                            && (gemm_is_cont_r
                                ? ((state == S_GEMM_CONT) && gemm.beat_fire)
                                : gemm_acc_snap_c);
    assign sched.load_req   = load_req_r;
    assign sched.load_busy  = load_busy_r;
    assign sched.tile_tok   = gemm_tok_r;
    assign sched.batch_n    = gemm_batch_n_r;
    assign sched.stream_mode = gemm_is_cont_r ? GEMM_SNAP_CONTINUOUS
                                              : GEMM_SNAP_PER_TOKEN;
    assign tlmm.start = tlmm_start_r;
    assign tlmm.k_cnt = tlmm_k_cnt_r;
    assign tlmm.busy  = tlmm_busy_r;
    assign mem_issue.start     = mem_start_r;
    assign mem_issue.opc       = mem_opc_r;
    assign mem_issue.tile_id   = mem_tile_id_r;
    assign mem_issue.is_sparse = mem_is_sparse_r;
    assign mem_issue.busy      = mem_busy_r;
    assign kv.wr_en   = kv_wr_en_r;
    assign kv.wr_addr = kv_wr_addr_r;
    assign kv.wr_data = kv_wr_data_r;
    assign kv.rd_en   = kv_rd_en_r;
    assign kv.rd_addr = kv_rd_addr_r;
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
            path_commit_r <= 1'b0;
            tlmm_start_r  <= 1'b0;
            mem_start_r   <= 1'b0;
            kv_wr_en_r    <= 1'b0;
            kv_rd_en_r    <= 1'b0;
            load_req_r    <= 1'b0;

            unique case (state)
                S_IDLE: begin
                    if (start) begin
                        pc    <= '0;
                        state <= S_EXEC;
                    end
                end
                S_EXEC: begin
                    if (cfg_pending) begin
                        if (noc_cfg.cfg_ready) begin
                            cfg_pending <= 1'b0;
                            pc          <= pc + 1'b1;
                        end
                    end else begin
                        unique case (instr_opc)
                            OP_NOP: begin
                                pc <= pc + 1'b1;
                            end

                            OP_BARRIER: begin
                                if (!dense_drain_busy) pc <= pc + 1'b1;
                            end

                            OP_EOP: begin
                                program_done_r <= 1'b1;
                                state          <= S_DONE;
                            end
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
                                    pc <= pc + 1'b1;
                                end else begin
                                    path_id_r[0]      <= instr_path_id[NOC_PATH_ID_W-1:0];
                                    gemm_k_rem        <= instr_k_cnt;
                                    gemm_k_cnt_r      <= instr_k_cnt;
                                    gemm_first_done_r <= 1'b0;
                                    gemm_is_cont_r    <= 1'b0;
                                    gemm_busy_r       <= 1'b1;
                                    state             <= S_GEMM_ACC;
                                end
                            end
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
                                    gemm_k_cnt_r       <= instr_k_cnt;
                                    gemm_row_cnt_r     <= ROW_CNT_W'(instr_row_cnt);
                                    gemm_col_cnt_r     <= COL_CNT_W'(instr_col_cnt);
                                    gemm_tile_gr_r     <= '0;
                                    gemm_tile_gc_r     <= '0;
                                    gemm_is_layer_r    <= 1'b1;
                                    gemm_is_batch_r    <= 1'b0;
                                    gemm_is_cont_r     <= 1'b0;
                                    gemm_batch_n_r     <= BATCH_TOK_W'(1);
                                    gemm_tok_r         <= '0;
                                    layer_first_tile_r <= 1'b1;
                                    load_busy_r        <= 1'b1;
                                    load_req_r         <= 1'b1;
                                    state              <= S_LAYER_WLOAD;
                                end
                            end
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
                                    gemm_is_cont_r     <= instr_raw[FLG_GEMM_CONTINUOUS];
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
                S_LAYER_WLOAD: begin
                    if (sched.load_done) begin
                        load_busy_r       <= 1'b0;
                        gemm_first_done_r <= 1'b0;
                        gemm_busy_r       <= 1'b1;
                        if (gemm_is_cont_r) begin
                            state         <= S_GEMM_CONT;
                        end else begin
                            gemm_k_rem    <= gemm_k_cnt_r;
                            state         <= S_GEMM_ACC;
                        end
                    end
                end
                S_GEMM_ACC: begin
                    if (gemm.beat_fire) begin
                        gemm_first_done_r <= 1'b1;
                        gemm_k_rem        <= gemm_k_rem - 1'b1;
                        if (gemm_k_rem == MACRO_CNT_W'(1)) begin
                            state          <= S_GEMM_DRAIN;
                            gemm_drain_cnt <= ($clog2(GEMM_DRAIN_CYCLES))'(GEMM_DRAIN_CYCLES - 1);
                        end
                    end
                end
                S_GEMM_DRAIN: begin
                    if (gemm_drain_cnt == '0) begin
                        state <= S_GEMM_SNAP;
                    end else begin
                        gemm_drain_cnt <= gemm_drain_cnt - 1'b1;
                    end
                end
                S_GEMM_SNAP: begin
                    gemm_busy_r <= 1'b0;
                    if (gemm_is_layer_r) begin
                        layer_first_tile_r <= 1'b0;
                        if (!gemm_is_last_tok_c) begin
                            gemm_tok_r <= gemm_tok_r + BATCH_TOK_W'(1);
                            state      <= S_BATCH_REARM;
                        end else if (gemm_is_last_tile_c) begin
                            gemm_is_layer_r <= 1'b0;
                            gemm_is_batch_r <= 1'b0;
                            pc              <= pc + 1'b1;
                            state           <= S_EXEC;
                        end else begin
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
                        pc    <= pc + 1'b1;
                        state <= S_EXEC;
                    end
                end
                S_BATCH_REARM: begin
                    gemm_first_done_r <= 1'b0;
                    gemm_k_rem        <= gemm_k_cnt_r;
                    gemm_busy_r       <= 1'b1;
                    state             <= S_GEMM_ACC;
                end
                S_GEMM_CONT: begin
                    if (gemm.beat_fire) begin
                        gemm_first_done_r <= 1'b1;
                        if (gemm_tok_r == (gemm_batch_n_r - BATCH_TOK_W'(1))) begin
                            gemm_busy_r     <= 1'b0;
                            gemm_cflush_cnt <= ($clog2(GEMM_CONT_FLUSH+1))'(GEMM_CONT_FLUSH);
                            state           <= S_GEMM_CFLUSH;
                        end else begin
                            gemm_tok_r <= gemm_tok_r + BATCH_TOK_W'(1);
                        end
                    end
                end
                S_GEMM_CFLUSH: begin
                    layer_first_tile_r <= 1'b0;
                    if (gemm_cflush_cnt == '0) begin
                        if (gemm_is_last_tile_c) begin
                            gemm_is_layer_r <= 1'b0;
                            gemm_is_batch_r <= 1'b0;
                            gemm_is_cont_r  <= 1'b0;
                            pc              <= pc + 1'b1;
                            state           <= S_EXEC;
                        end else begin
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
                S_FFN_WAIT: begin
                    if (tlmm.done) begin
                        tlmm_busy_r <= 1'b0;
                        pc          <= pc + 1'b1;
                        state       <= S_EXEC;
                    end
                end
                S_MEM_WAIT: begin
                    if (mem_issue.done) begin
                        mem_busy_r <= 1'b0;
                        pc         <= pc + 1'b1;
                        state      <= S_EXEC;
                    end
                end
                S_DONE: begin
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end
`ifndef SYNTHESIS
    property p_imem_write_only_idle;
        @(posedge clk) disable iff (!rst_n)
        imem_we |-> (state == S_IDLE);
    endproperty
    a_imem_write_only_idle: assert property (p_imem_write_only_idle)
        else $error("dispatcher: imem_we asserted while state != S_IDLE");
    property p_commit_pulse;
        @(posedge clk) disable iff (!rst_n)
        path_commit_r |=> !path_commit_r;
    endproperty
    a_commit_pulse: assert property (p_commit_pulse)
        else $error("dispatcher: path_commit held high > 1 cycle");
    property p_no_commit_mid_cfg;
        @(posedge clk) disable iff (!rst_n)
        path_commit_r |-> !cfg_pending;
    endproperty
    a_no_commit_mid_cfg: assert property (p_no_commit_mid_cfg)
        else $error("dispatcher: path_commit pulsed while cfg_pending");
    property p_program_done_sticky;
        @(posedge clk) disable iff (!rst_n)
        program_done_r |=> program_done_r;
    endproperty
    a_program_done_sticky: assert property (p_program_done_sticky)
        else $error("dispatcher: program_done dropped after being set");
    property p_no_overstream_in_gemm;
        @(posedge clk) disable iff (!rst_n)
        (state == S_GEMM_ACC && gemm.beat_fire) |-> (gemm_k_rem != '0);
    endproperty
    a_no_overstream_in_gemm: assert property (p_no_overstream_in_gemm)
        else $error("dispatcher: gemm driver asserted beat_fire after k_cnt beats were counted");
    property p_no_fire_in_gemm_tail;
        @(posedge clk) disable iff (!rst_n)
        (state == S_GEMM_DRAIN || state == S_GEMM_SNAP
         || state == S_GEMM_CFLUSH) |-> !gemm.beat_fire;
    endproperty
    a_no_fire_in_gemm_tail: assert property (p_no_fire_in_gemm_tail)
        else $error("dispatcher: beat_fire asserted during GEMM drain/snap/flush (driver kept streaming)");
    a_load_req_in_layer: assert property (
        @(posedge clk) disable iff (!rst_n) load_req_r |-> gemm_is_layer_r
    ) else $error("dispatcher: sched.load_req asserted outside OP_GEMM_LAYER");
    a_tile_first_with_clr: assert property (
        @(posedge clk) disable iff (!rst_n) sched.tile_first |-> gemm.acc_clr
    ) else $error("dispatcher: tile_first without acc_clr (array bank-clear contract)");
    a_tile_last_drive: assert property (
        @(posedge clk) disable iff (!rst_n)
        sched.tile_last |-> (gemm_is_cont_r ? gemm.acc_clr : gemm.acc_snap)
    ) else $error("dispatcher: tile_last without its mode's drain trigger (acc_snap PER_TOKEN / acc_clr CONTINUOUS)");
`endif

endmodule : dispatcher

`default_nettype wire
`endif
