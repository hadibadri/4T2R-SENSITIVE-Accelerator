// -----------------------------------------------------------------------------
// tb_dense_group.sv
//
// Golden testbench for dense_group. Programs a 16x16 weight plane, streams K
// BFP12 activation blocks through the group's strm_if sink, drives the
// acc_clr / acc_snap sideband to the group's contract, and compares the 16
// column outputs against a pure-SV reference.
//
// Directed:
//   * K=1, identity weights (W[i,j] = (i==j)) -> y = first activation vector
//   * K=1, all-zero weights                   -> y = 0
//   * K=4, small ints                         -> hand-check
//   * K=16, max-magnitude weights + activations (exercise GROUP_ACC_W)
//
// Random:
//   * Two weight epochs. Each epoch programs a new random 16x16 weight plane,
//     then runs N_RAND_PER_EPOCH reductions with random K in [1, K_MAX] and
//     random activations.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_TB_DENSE_GROUP_SV
`define ARCHBETTER_TB_DENSE_GROUP_SV
`default_nettype none
`timescale 1ns/1ps

module tb_dense_group
    import types_pkg::*;
();
    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------
    localparam time T_CLK             = 10ns;
    localparam int  K_MAX             = 16;
    localparam int  N_RAND_PER_EPOCH  = 50;
    localparam int  N_EPOCHS          = 2;

    localparam int  ROWS = DENSE_GROUP_ROWS;
    localparam int  COLS = DENSE_GROUP_COLS;

    // -------------------------------------------------------------------------
    // DUT nets
    // -------------------------------------------------------------------------
    logic clk, rst_n;

    strm_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W))
        a_strm_if (.clk(clk), .rst_n(rst_n));

    logic                                          acc_clr, acc_snap;
    gemm_stream_mode_e                             stream_mode;
    logic                                          w_we;
    logic [$clog2(DENSE_PE_PER_GROUP)-1:0]         w_addr;
    bfp12_mant_t [(BFP12_BLK/2)-1:0]               w_in;   // 8 mantissas/beat (C1.5)
    group_acc_t [DENSE_GROUP_COLS-1:0]             y_out;
    logic                                          y_valid;

    dense_group #(
        .ENABLE_NOISE_HOOKS (1'b0),
        .GROUP_ID           (32'd0)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .a_strm   (a_strm_if),
        .acc_clr  (acc_clr),
        .acc_snap (acc_snap),
        .stream_mode (stream_mode),
        .w_we     (w_we),
        .w_addr   (w_addr),
        .w_in     (w_in),
        .y_out    (y_out),
        .y_valid  (y_valid)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always  #(T_CLK/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Reference mirror of the weight matrix
    // -------------------------------------------------------------------------
    bfp12_mant_t weights_ref [ROWS][COLS];

    // -------------------------------------------------------------------------
    // Snapshot capture
    // -------------------------------------------------------------------------
    group_acc_t [DENSE_GROUP_COLS-1:0] y_snapped;
    logic                              snap_seen;
    logic                              snap_clr;   // task-driven 1-cycle clear
    int                                n_reductions;
    int                                n_errors;

    // snap_seen is driven ONLY here (single process) — the reduction task clears
    // it via the clocked snap_clr handshake rather than writing it directly,
    // which removes the prior VRFC-10-3818/10-2921 multi-driver warnings.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            snap_seen <= 1'b0;
        end else begin
            if (snap_clr) snap_seen <= 1'b0;
            if (y_valid) begin
                y_snapped <= y_out;
                snap_seen <= 1'b1;   // y_valid wins a same-cycle race with clr
            end
        end
    end

    // v2 (CONTINUOUS) capture: record every per-token y_out partial in order.
    group_acc_t [DENSE_GROUP_COLS-1:0] cont_cap [$];
    logic                              cont_capturing;
    always_ff @(posedge clk) begin
        if (rst_n && cont_capturing && y_valid)
            cont_cap.push_back(y_out);
    end

    // -------------------------------------------------------------------------
    // Weight programming — scan in all 256, mirror into weights_ref.
    // -------------------------------------------------------------------------
    // C1.5: scan a whole word (8 PEs = one row's half) per beat.
    task automatic program_weights(input bfp12_mant_t wm[ROWS][COLS]);
        localparam int WSCAN = BFP12_BLK / 2;   // 8
        for (int r = 0; r < ROWS; r++) begin
            for (int half = 0; half < COLS / WSCAN; half++) begin
                automatic int c_base = half * WSCAN;
                @(posedge clk);
                for (int s = 0; s < WSCAN; s++) begin
                    w_in[s]                  <= wm[r][c_base + s];
                    weights_ref[r][c_base+s]  = wm[r][c_base + s];
                end
                w_addr <= ($clog2(DENSE_PE_PER_GROUP))'(r * COLS + c_base);
                w_we   <= 1'b1;
            end
        end
        @(posedge clk);
        w_we <= 1'b0;
        w_in <= '0;
    endtask

    // -------------------------------------------------------------------------
    // Drive one K-beat reduction through the strm_if sink.
    // acts[k][r] = activation mantissa for row r at beat k.
    // expected[c] filled by the reference.
    // -------------------------------------------------------------------------
    task automatic run_reduction(
        input  bfp12_mant_t                 acts[$][ROWS],
        output group_acc_t                  expected[COLS]
    );
        int K = acts.size();
        logic [NOC_DATA_W-1:0] packed_data;

        for (int c = 0; c < COLS; c++) expected[c] = '0;
        snap_clr <= 1'b1;
        @(posedge clk);
        snap_clr <= 1'b0;

        for (int k = 0; k < K; k++) begin
            packed_data = '0;
            for (int r = 0; r < ROWS; r++) begin
                packed_data[r*BFP12_MANT_W +: BFP12_MANT_W] = acts[k][r];
                for (int c = 0; c < COLS; c++) begin
                    expected[c] += group_acc_t'(
                        $signed(acts[k][r]) * $signed(weights_ref[r][c])
                    );
                end
            end
            a_strm_if.data  <= packed_data;
            a_strm_if.user  <= '0;
            a_strm_if.valid <= 1'b1;
            a_strm_if.last  <= (k == K-1);
            acc_clr         <= (k == 0);
            @(posedge clk);
        end

        a_strm_if.data  <= '0;
        a_strm_if.user  <= '0;
        a_strm_if.valid <= 1'b0;
        a_strm_if.last  <= 1'b0;
        acc_clr         <= 1'b0;

        // Fused-MACC drain, then snap. The DSP P register holds the completed
        // sum once a_strm.valid drops, so a generous drain is always safe.
        repeat (4) @(posedge clk);
        acc_snap <= 1'b1;
        @(posedge clk);
        acc_snap <= 1'b0;

        // Two cycles for PE acc_out_valid -> group y_valid -> capture.
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
    endtask

    task automatic check_reduction(
        input group_acc_t expected[COLS],
        input string      label
    );
        n_reductions++;
        if (!snap_seen) begin
            n_errors++;
            $error("[%0t] %s: no y_valid observed", $time, label);
            return;
        end
        for (int c = 0; c < COLS; c++) begin
            if (y_snapped[c] !== expected[c]) begin
                n_errors++;
                $error("[%0t] %s col %0d mismatch: dut=%0d ref=%0d",
                       $time, label, c, y_snapped[c], expected[c]);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Helpers to build weight matrices and activation beat lists
    // -------------------------------------------------------------------------
    function automatic void fill_weights_zero(ref bfp12_mant_t wm[ROWS][COLS]);
        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                wm[r][c] = '0;
    endfunction

    function automatic void fill_weights_identity(ref bfp12_mant_t wm[ROWS][COLS]);
        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                wm[r][c] = (r == c) ? 12'sd1 : 12'sd0;
    endfunction

    function automatic void fill_weights_constant(
        ref bfp12_mant_t wm[ROWS][COLS],
        input bfp12_mant_t v
    );
        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                wm[r][c] = v;
    endfunction

    function automatic void fill_weights_random(ref bfp12_mant_t wm[ROWS][COLS]);
        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                wm[r][c] = bfp12_mant_t'($urandom());
    endfunction

    // -------------------------------------------------------------------------
    // Directed
    // -------------------------------------------------------------------------
    task automatic run_directed();
        bfp12_mant_t wm[ROWS][COLS];
        group_acc_t  expected[COLS];

        $display("[%0t] DIRECTED: K=1 identity weights", $time);
        begin
            bfp12_mant_t acts[$][ROWS];
            bfp12_mant_t vec[ROWS];
            fill_weights_identity(wm);
            program_weights(wm);
            for (int r = 0; r < ROWS; r++) vec[r] = 12'sd100 + r;
            acts.push_back(vec);
            run_reduction(acts, expected);
            check_reduction(expected, "K=1 identity");
        end

        $display("[%0t] DIRECTED: K=1 zero weights", $time);
        begin
            bfp12_mant_t acts[$][ROWS];
            bfp12_mant_t vec[ROWS];
            fill_weights_zero(wm);
            program_weights(wm);
            for (int r = 0; r < ROWS; r++) vec[r] = 12'sd77;
            acts.push_back(vec);
            run_reduction(acts, expected);
            check_reduction(expected, "K=1 zero");
        end

        $display("[%0t] DIRECTED: K=4 small ints", $time);
        begin
            bfp12_mant_t acts[$][ROWS];
            fill_weights_constant(wm, 12'sd2);
            program_weights(wm);
            for (int k = 0; k < 4; k++) begin
                bfp12_mant_t vec[ROWS];
                for (int r = 0; r < ROWS; r++) vec[r] = 12'sd1 + k;
                acts.push_back(vec);
            end
            run_reduction(acts, expected);
            check_reduction(expected, "K=4 small");
        end

        $display("[%0t] DIRECTED: K=16 max-magnitude (headroom check)", $time);
        begin
            bfp12_mant_t acts[$][ROWS];
            fill_weights_constant(wm, 12'sh7FF);
            program_weights(wm);
            for (int k = 0; k < 16; k++) begin
                bfp12_mant_t vec[ROWS];
                for (int r = 0; r < ROWS; r++) vec[r] = 12'sh7FF;
                acts.push_back(vec);
            end
            run_reduction(acts, expected);
            check_reduction(expected, "K=16 max");
        end
    endtask

    // -------------------------------------------------------------------------
    // v2 continuous snap: weights are programmed once, then T per-token K=1
    // activation vectors stream at II=1 with acc_clr=1 on every beat. The group
    // must emit one 16-wide partial per token, in order, each = the K=1 product
    // of that token's vector against the resident weight plane. No acc_snap is
    // pulsed; the per-beat cell valid drives a continuous y_valid. This is the
    // group-level proof of the prefill compute-bound path.
    // -------------------------------------------------------------------------
    task automatic run_continuous_group(
        input bfp12_mant_t acts[$][ROWS],     // one vector per token
        input string       label
    );
        int unsigned T = acts.size();
        logic [NOC_DATA_W-1:0] packed_data;
        group_acc_t expected[$];              // [token][col] flattened per token

        // Reference: T independent K=1 partials against weights_ref.
        expected.delete();
        for (int t = 0; t < int'(T); t++) begin
            for (int c = 0; c < COLS; c++) begin
                group_acc_t s = '0;
                for (int r = 0; r < ROWS; r++)
                    s += group_acc_t'($signed(acts[t][r]) * $signed(weights_ref[r][c]));
                expected.push_back(s);
            end
        end

        stream_mode    = GEMM_SNAP_CONTINUOUS;
        cont_cap.delete();
        cont_capturing = 1'b1;
        @(posedge clk);
        for (int t = 0; t < int'(T); t++) begin
            packed_data = '0;
            for (int r = 0; r < ROWS; r++)
                packed_data[r*BFP12_MANT_W +: BFP12_MANT_W] = acts[t][r];
            a_strm_if.data  <= packed_data;
            a_strm_if.user  <= '0;
            a_strm_if.valid <= 1'b1;
            a_strm_if.last  <= (t == int'(T)-1);
            acc_clr         <= 1'b1;          // fresh K=1 LOAD per token
            @(posedge clk);
        end
        a_strm_if.data  <= '0;
        a_strm_if.valid <= 1'b0;
        a_strm_if.last  <= 1'b0;
        acc_clr         <= 1'b0;
        // Drain so the last token's partial (a_fire + DENSE_CONT_RESULT_LAT)
        // is captured.
        repeat (DENSE_CONT_RESULT_LAT + 3) @(posedge clk);
        cont_capturing = 1'b0;

        if (cont_cap.size() != T) begin
            n_errors++;
            $error("[%0t] %s: captured %0d partials, expected %0d",
                   $time, label, cont_cap.size(), T);
        end else begin
            for (int t = 0; t < int'(T); t++) begin
                n_reductions++;
                for (int c = 0; c < COLS; c++) begin
                    if (cont_cap[t][c] !== expected[t*COLS + c]) begin
                        n_errors++;
                        $error("[%0t] %s tok %0d col %0d mismatch: dut=%0d ref=%0d",
                               $time, label, t, c, cont_cap[t][c], expected[t*COLS + c]);
                    end
                end
            end
        end
        stream_mode = GEMM_SNAP_PER_TOKEN;
    endtask

    task automatic run_continuous_cases();
        bfp12_mant_t wm[ROWS][COLS];

        $display("[%0t] CONTINUOUS: T=8 identity weights, distinct tokens", $time);
        begin
            bfp12_mant_t acts[$][ROWS];
            fill_weights_identity(wm);
            program_weights(wm);
            for (int t = 0; t < 8; t++) begin
                bfp12_mant_t vec[ROWS];
                for (int r = 0; r < ROWS; r++) vec[r] = bfp12_mant_t'(12'sd10 + t*ROWS + r);
                acts.push_back(vec);
            end
            run_continuous_group(acts, "cont T=8 identity");
        end

        $display("[%0t] CONTINUOUS: T=32 random weights, random tokens", $time);
        begin
            bfp12_mant_t acts[$][ROWS];
            fill_weights_random(wm);
            program_weights(wm);
            for (int t = 0; t < 32; t++) begin
                bfp12_mant_t vec[ROWS];
                for (int r = 0; r < ROWS; r++) vec[r] = bfp12_mant_t'($urandom());
                acts.push_back(vec);
            end
            run_continuous_group(acts, "cont T=32 random");
        end
    endtask

    // -------------------------------------------------------------------------
    // Random
    // -------------------------------------------------------------------------
    task automatic run_random_epoch(input int epoch_id);
        bfp12_mant_t wm[ROWS][COLS];
        group_acc_t  expected[COLS];

        fill_weights_random(wm);
        program_weights(wm);
        $display("[%0t] RANDOM epoch %0d: %0d reductions, K ~ U[1, %0d]",
                 $time, epoch_id, N_RAND_PER_EPOCH, K_MAX);

        for (int r = 0; r < N_RAND_PER_EPOCH; r++) begin
            int K = $urandom_range(1, K_MAX);
            bfp12_mant_t acts[$][ROWS];
            for (int k = 0; k < K; k++) begin
                bfp12_mant_t vec[ROWS];
                for (int rr = 0; rr < ROWS; rr++)
                    vec[rr] = bfp12_mant_t'($urandom());
                acts.push_back(vec);
            end
            run_reduction(acts, expected);
            check_reduction(expected, $sformatf("ep%0d r=%0d K=%0d", epoch_id, r, K));
        end
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin
        rst_n           = 1'b0;
        a_strm_if.data  = '0;
        a_strm_if.user  = '0;
        a_strm_if.valid = 1'b0;
        a_strm_if.last  = 1'b0;
        acc_clr         = 1'b0;
        acc_snap        = 1'b0;
        stream_mode     = GEMM_SNAP_PER_TOKEN;
        snap_clr        = 1'b0;
        cont_capturing  = 1'b0;
        w_we            = 1'b0;
        w_addr          = '0;
        w_in            = '0;
        n_reductions    = 0;
        n_errors        = 0;

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        run_directed();
        run_continuous_cases();
        for (int e = 0; e < N_EPOCHS; e++) run_random_epoch(e);

        if (n_errors == 0 && n_reductions > 0) begin
            $display("=========================================================");
            $display(" tb_dense_group: PASS  (%0d reductions, 0 errors)", n_reductions);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_dense_group: FAIL  (%0d reductions, %0d errors)",
                     n_reductions, n_errors);
            $display("=========================================================");
        end

        $finish;
    end

    // Watchdog: ~5ms guard on an expected ~hundreds-of-us runtime.
    initial begin
        #(T_CLK * 500_000);
        $fatal(1, "tb_dense_group: watchdog timeout");
    end

endmodule : tb_dense_group

`default_nettype wire
`endif // ARCHBETTER_TB_DENSE_GROUP_SV
