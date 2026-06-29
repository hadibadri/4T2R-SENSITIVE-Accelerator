
`timescale 1ns/1ps
`default_nettype none

module tb_dense_act_streamer;
    import types_pkg::*;
    localparam time CLK_PERIOD = 10ns;

    logic clk = 1'b0;
    logic rst_n;

    initial forever #(CLK_PERIOD/2) clk = ~clk;
    localparam int unsigned PP_DATA_W   = DENSE_PP_URAM_W;
    localparam int unsigned CASC_W      = PP_DATA_W / 2;
    localparam int unsigned NOC_DW      = NOC_DATA_W;
    localparam int unsigned NOC_UW      = NOC_USER_W;
    localparam int unsigned MANT_HALF_W = BFP12_BLK * BFP12_MANT_W / 2;
    localparam int unsigned URAM_DEPTH_TB = 1024;
    gemm_issue_if          gemm (clk, rst_n);
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_DATA_W)) pp (clk, rst_n);
    strm_if     #(.DATA_W(NOC_DW),      .USER_W(NOC_UW))    src (clk, rst_n);
    logic [URAM_ADDR_W-1:0] base_addr;
    logic [URAM_ADDR_W-1:0] token_stride;

    dense_act_streamer #(
        .PP_DATA_W (PP_DATA_W),
        .NOC_DW    (NOC_DW),
        .NOC_UW    (NOC_UW)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .base_addr    (base_addr),
        .token_stride (token_stride),
        .gemm         (gemm.drv),
        .pp           (pp.core),
        .src          (src.src)
    );
    logic [PP_DATA_W-1:0] mem_q [0:URAM_DEPTH_TB-1];
    bank_sel_e          mgr_active_side;
    logic               mgr_side_valid;
    logic [PP_DATA_W-1:0] mgr_rd_data;
    logic               mgr_rd_valid;
    logic               mgr_drain_req;

    assign pp.active_side = mgr_active_side;
    assign pp.side_valid  = mgr_side_valid;
    assign pp.rd_data     = mgr_rd_data;
    assign pp.rd_valid    = mgr_rd_valid;
    assign pp.drain_req   = mgr_drain_req;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mgr_rd_valid <= 1'b0;
            mgr_rd_data  <= '0;
        end else begin
            mgr_rd_valid <= pp.rd_en;
            if (pp.rd_en) begin
                mgr_rd_data <= mem_q[pp.rd_addr[$clog2(URAM_DEPTH_TB)-1:0]];
            end
        end
    end

    initial begin
        mgr_active_side = BANK_A;
        mgr_side_valid  = 1'b1;
        mgr_drain_req   = 1'b0;
    end
    logic                 sink_ready;
    assign src.ready = sink_ready;
    logic [NOC_PATH_ID_W-1:0] disp_path_id;
    logic [MACRO_CNT_W-1:0]   disp_k_cnt;
    logic                     disp_busy;
    logic                     disp_acc_clr;
    logic                     disp_acc_snap;
    gemm_stream_mode_e        disp_stream_mode;
    logic [BATCH_TOK_W-1:0]   disp_batch_n;

    assign gemm.path_id     = disp_path_id;
    assign gemm.k_cnt       = disp_k_cnt;
    assign gemm.busy        = disp_busy;
    assign gemm.acc_clr     = disp_acc_clr;
    assign gemm.acc_snap    = disp_acc_snap;
    assign gemm.stream_mode = disp_stream_mode;
    assign gemm.batch_n     = disp_batch_n;
    logic first_beat_seen_q;
    logic last_beat_fired_q;
    logic snap_armed_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            first_beat_seen_q <= 1'b0;
            last_beat_fired_q <= 1'b0;
            snap_armed_q      <= 1'b0;
        end else if (!disp_busy) begin
            first_beat_seen_q <= 1'b0;
            last_beat_fired_q <= 1'b0;
            snap_armed_q      <= 1'b0;
        end else begin
            if (gemm.beat_fire) begin
                first_beat_seen_q <= 1'b1;
                if (src.last) last_beat_fired_q <= 1'b1;
            end
            if (last_beat_fired_q && !disp_acc_snap) begin
                snap_armed_q <= 1'b1;
            end
            if (disp_acc_snap) begin
                snap_armed_q <= 1'b0;
            end
        end
    end
    always_comb begin
        disp_acc_clr  = disp_busy && !first_beat_seen_q && gemm.beat_fire;
        disp_acc_snap = disp_busy && snap_armed_q;
    end
    typedef struct {
        logic [NOC_DW-1:0] data;
        logic [NOC_UW-1:0] user;
        logic              last;
    } beat_t;

    beat_t obs_q [$];

    always_ff @(posedge clk) begin
        if (rst_n && src.valid && src.ready) begin
            beat_t b;
            b.data = src.data;
            b.user = src.user;
            b.last = src.last;
            obs_q.push_back(b);
        end
    end
    int n_checks  = 0;
    int n_errors  = 0;

    function automatic void check_eq_data(
        input logic [NOC_DW-1:0] got, exp,
        input string             label
    );
        n_checks++;
        if (got !== exp) begin
            n_errors++;
            $error("[%0t] %s: data mismatch got=%h exp=%h", $time, label, got, exp);
        end
    endfunction

    function automatic void check_eq_user(
        input logic [NOC_UW-1:0] got, exp,
        input string             label
    );
        n_checks++;
        if (got !== exp) begin
            n_errors++;
            $error("[%0t] %s: user mismatch got=%h exp=%h", $time, label, got, exp);
        end
    endfunction

    function automatic void check_eq_bool(
        input logic  got, exp,
        input string label
    );
        n_checks++;
        if (got !== exp) begin
            n_errors++;
            $error("[%0t] %s: bool mismatch got=%0b exp=%0b", $time, label, got, exp);
        end
    endfunction
    function automatic void program_op(
        input logic [URAM_ADDR_W-1:0] op_base,
        input int                     op_k,
        input logic [7:0]             seed
    );
        for (int b = 0; b < op_k; b++) begin
            logic [CASC_W-1:0] w0, w1;
            logic [BFP12_EXP_W-1:0] exp_v;
            logic [MANT_HALF_W-1:0] mant_lo, mant_hi;
            mant_lo = '0;
            mant_hi = '0;
            for (int i = 0; i < BFP12_BLK/2; i++) begin
                automatic logic [BFP12_MANT_W-1:0] m_lo, m_hi;
                m_lo = BFP12_MANT_W'(seed + b*16 + i);
                m_hi = BFP12_MANT_W'(seed + b*16 + (BFP12_BLK/2 + i));
                mant_lo[i*BFP12_MANT_W +: BFP12_MANT_W] = m_lo;
                mant_hi[i*BFP12_MANT_W +: BFP12_MANT_W] = m_hi;
            end
            exp_v = BFP12_EXP_W'(seed + b);
            w0 = '0;
            w1 = '0;
            w0[0 +: MANT_HALF_W]              = mant_lo;
            w0[MANT_HALF_W +: BFP12_EXP_W]    = exp_v;
            w1[0 +: MANT_HALF_W]              = mant_hi;
            mem_q[(op_base + 2*b) >> 1] = {w1, w0};
        end
    endfunction

    function automatic beat_t expected_beat(
        input logic [URAM_ADDR_W-1:0] op_base,
        input int                     b,
        input int                     op_k
    );
        beat_t e;
        logic [PP_DATA_W-1:0] ww;
        ww = mem_q[(op_base + 2*b) >> 1];
        e.data = { ww[CASC_W +: MANT_HALF_W], ww[0 +: MANT_HALF_W] };
        e.user = ww[MANT_HALF_W +: BFP12_EXP_W];
        e.last = (b == op_k - 1);
        return e;
    endfunction
    task automatic run_op (
        input logic [URAM_ADDR_W-1:0] op_base,
        input int                     op_k,
        input bit                     random_backpressure,
        input string                  label
    );
        int n_to_check;
        @(posedge clk);
        base_addr        = op_base;
        token_stride     = URAM_ADDR_W'(2);
        disp_stream_mode = GEMM_SNAP_PER_TOKEN;
        disp_batch_n     = BATCH_TOK_W'(1);
        disp_path_id     = '0;
        disp_k_cnt       = MACRO_CNT_W'(op_k);
        disp_busy        = 1'b1;
        n_to_check = obs_q.size() + op_k;
        while (obs_q.size() < n_to_check) begin
            @(posedge clk);
            if (random_backpressure) begin
                sink_ready <= ($urandom_range(0, 3) != 0);
            end
        end
        @(posedge clk);
        while (!disp_acc_snap) @(posedge clk);
        @(posedge clk);
        disp_busy <= 1'b0;
        @(posedge clk);
        for (int b = 0; b < op_k; b++) begin
            beat_t got, exp;
            got = obs_q[obs_q.size() - op_k + b];
            exp = expected_beat(op_base, b, op_k);
            check_eq_data(got.data, exp.data, $sformatf("%s beat[%0d].data", label, b));
            check_eq_user(got.user, exp.user, $sformatf("%s beat[%0d].user", label, b));
            check_eq_bool(got.last, exp.last, $sformatf("%s beat[%0d].last", label, b));
        end
    endtask
    function automatic void program_op_cont(
        input logic [URAM_ADDR_W-1:0] op_base,
        input int                     op_t,
        input logic [URAM_ADDR_W-1:0] stride,
        input logic [7:0]             seed
    );
        for (int t = 0; t < op_t; t++) begin
            logic [CASC_W-1:0] w0, w1;
            logic [BFP12_EXP_W-1:0] exp_v;
            logic [MANT_HALF_W-1:0] mant_lo, mant_hi;
            mant_lo = '0;
            mant_hi = '0;
            for (int i = 0; i < BFP12_BLK/2; i++) begin
                mant_lo[i*BFP12_MANT_W +: BFP12_MANT_W] =
                    BFP12_MANT_W'(seed + t*32 + i);
                mant_hi[i*BFP12_MANT_W +: BFP12_MANT_W] =
                    BFP12_MANT_W'(seed + t*32 + (BFP12_BLK/2 + i));
            end
            exp_v = BFP12_EXP_W'(seed + t);
            w0 = '0;
            w1 = '0;
            w0[0 +: MANT_HALF_W]           = mant_lo;
            w0[MANT_HALF_W +: BFP12_EXP_W] = exp_v;
            w1[0 +: MANT_HALF_W]           = mant_hi;
            mem_q[(op_base + t*stride) >> 1] = {w1, w0};
        end
    endfunction

    function automatic beat_t expected_beat_cont(
        input logic [URAM_ADDR_W-1:0] op_base,
        input int                     t,
        input int                     op_t,
        input logic [URAM_ADDR_W-1:0] stride
    );
        beat_t e;
        logic [PP_DATA_W-1:0] ww;
        ww = mem_q[(op_base + t*stride) >> 1];
        e.data = { ww[CASC_W +: MANT_HALF_W], ww[0 +: MANT_HALF_W] };
        e.user = ww[MANT_HALF_W +: BFP12_EXP_W];
        e.last = (t == op_t - 1);
        return e;
    endfunction

    task automatic run_op_cont (
        input logic [URAM_ADDR_W-1:0] op_base,
        input int                     op_t,
        input logic [URAM_ADDR_W-1:0] stride,
        input bit                     random_backpressure,
        input string                  label
    );
        int n_to_check;
        @(posedge clk);
        base_addr        = op_base;
        token_stride     = stride;
        disp_stream_mode = GEMM_SNAP_CONTINUOUS;
        disp_batch_n     = BATCH_TOK_W'(op_t);
        disp_path_id     = '0;
        disp_k_cnt       = MACRO_CNT_W'(1);
        disp_busy        = 1'b1;

        n_to_check = obs_q.size() + op_t;
        while (obs_q.size() < n_to_check) begin
            @(posedge clk);
            if (random_backpressure)
                sink_ready <= ($urandom_range(0, 3) != 0);
        end

        @(posedge clk);
        while (!disp_acc_snap) @(posedge clk);
        @(posedge clk);
        disp_busy <= 1'b0;
        @(posedge clk);

        for (int t = 0; t < op_t; t++) begin
            beat_t got, exp;
            got = obs_q[obs_q.size() - op_t + t];
            exp = expected_beat_cont(op_base, t, op_t, stride);
            check_eq_data(got.data, exp.data, $sformatf("%s tok[%0d].data", label, t));
            check_eq_user(got.user, exp.user, $sformatf("%s tok[%0d].user", label, t));
            check_eq_bool(got.last, exp.last, $sformatf("%s tok[%0d].last", label, t));
        end
    endtask
    initial begin
        #50us;
        $fatal(1, "tb_dense_act_streamer: watchdog timeout");
    end
    initial begin
        rst_n        = 1'b0;
        sink_ready   = 1'b1;
        disp_path_id = '0;
        disp_k_cnt   = '0;
        disp_busy    = 1'b0;
        disp_stream_mode = GEMM_SNAP_PER_TOKEN;
        disp_batch_n = BATCH_TOK_W'(1);
        base_addr    = '0;
        token_stride = URAM_ADDR_W'(2);
        for (int i = 0; i < URAM_DEPTH_TB; i++) mem_q[i] = '0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        program_op(URAM_ADDR_W'(0),  4, 8'h10);
        run_op(URAM_ADDR_W'(0), 4, 1'b0, "T1.K4_no_bp");
        program_op(URAM_ADDR_W'(64), 1, 8'h20);
        run_op(URAM_ADDR_W'(64), 1, 1'b0, "T2.K1");
        program_op(URAM_ADDR_W'(128), 8, 8'h30);
        run_op(URAM_ADDR_W'(128), 8, 1'b1, "T3.K8_bp");
        sink_ready = 1'b1;
        program_op(URAM_ADDR_W'(256), 3, 8'h40);
        run_op(URAM_ADDR_W'(256), 3, 1'b0, "T4a.K3");
        program_op(URAM_ADDR_W'(320), 5, 8'h50);
        run_op(URAM_ADDR_W'(320), 5, 1'b0, "T4b.K5");
        program_op_cont(URAM_ADDR_W'(384), 8, URAM_ADDR_W'(16), 8'h60);
        run_op_cont(URAM_ADDR_W'(384), 8, URAM_ADDR_W'(16), 1'b0, "T5.cont_T8_s16");
        program_op_cont(URAM_ADDR_W'(640), 4, URAM_ADDR_W'(8), 8'h78);
        run_op_cont(URAM_ADDR_W'(640), 4, URAM_ADDR_W'(8), 1'b1, "T6.cont_T4_s8_bp");
        sink_ready = 1'b1;
        repeat (8) @(posedge clk);
        if (n_errors == 0) begin
            $display("=========================================================");
            $display("tb_dense_act_streamer: PASS  (%0d / %0d checks)", n_checks, n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display("tb_dense_act_streamer: FAIL  (%0d errors / %0d checks)",
                     n_errors, n_checks);
            $display("=========================================================");
        end
        $finish;
    end

endmodule : tb_dense_act_streamer

`default_nettype wire
