// -----------------------------------------------------------------------------
// tb_dense_pe.sv
//
// Directed + random testbench for dense_pe. Each "reduction" drives K
// activations against a stationary weight, pulses acc_snap after the drain
// cycle, and compares the snapshotted INT32 sum against a pure-SV reference.
//
// Directed cases:
//   * K=1  weight=+1      -- simplest passthrough
//   * K=16 weight=-1      -- matches BFP12_BLK, exercises sign flip
//   * K=64 weight=max     -- max-magnitude saturation check on acc headroom
//
// Random phase:
//   * N_RANDOM_REDUCTIONS reductions
//   * K ~ U[1, K_MAX]
//   * weight and activations uniformly random in signed 12b range
//
// All reductions run back-to-back on the same PE, rewriting the weight before
// each one. This indirectly exercises the w_we vs a_valid mutex contract.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_TB_DENSE_PE_SV
`define ARCHBETTER_TB_DENSE_PE_SV
`default_nettype none
`timescale 1ns/1ps

module tb_dense_pe
    import types_pkg::*;
();

    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------
    localparam time T_CLK               = 10ns;
    localparam int  N_RANDOM_REDUCTIONS = 500;
    localparam int  K_MAX               = 64;

    // -------------------------------------------------------------------------
    // DUT nets
    // -------------------------------------------------------------------------
    logic         clk, rst_n;
    bfp12_mant_t  a_in;
    logic         a_valid;
    logic         w_we;
    bfp12_mant_t  w_in;
    bfp12_mant_t  noise_rd_in;
    logic         acc_clr, acc_snap;
    gemm_stream_mode_e stream_mode;
    dense_acc_t   acc_out;
    logic         acc_out_valid;

    dense_pe #(
        .ENABLE_NOISE_HOOKS (1'b0),
        .PE_ID              (32'd0)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .a_in          (a_in),
        .a_valid       (a_valid),
        .w_we          (w_we),
        .w_in          (w_in),
        .noise_rd_in   (noise_rd_in),
        .acc_clr       (acc_clr),
        .acc_snap      (acc_snap),
        .stream_mode   (stream_mode),
        .acc_out       (acc_out),
        .acc_out_valid (acc_out_valid)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always  #(T_CLK/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Snapshot capture — one-shot per reduction, armed by the caller.
    // -------------------------------------------------------------------------
    dense_acc_t snapped;
    logic       snap_seen;
    logic       snap_clr;   // task-driven 1-cycle clear (keeps snap_seen 1-driver)
    int         n_reductions;
    int         n_errors;

    // snap_seen driven only here (single process); the reduction task clears it
    // via the clocked snap_clr handshake, not a direct write — removes the
    // VRFC-10-3818/10-2921 multi-driver warning the v1 pattern carried.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            snap_seen <= 1'b0;
        end else begin
            if (snap_clr) snap_seen <= 1'b0;
            if (acc_out_valid) begin
                snapped   <= acc_out;
                snap_seen <= 1'b1;   // valid wins a same-cycle race with clr
            end
        end
    end

    // v2 (CONTINUOUS) capture: record every per-beat acc_out in stream order.
    dense_acc_t cont_cap [$];
    logic       cont_capturing;
    always_ff @(posedge clk) begin
        if (rst_n && cont_capturing && acc_out_valid)
            cont_cap.push_back(acc_out);
    end

    // -------------------------------------------------------------------------
    // Stimulus primitives — respect the w_we vs a_valid mutex, and observe
    // the fused-MACC drain rule before acc_snap (3 cycles minimum; we over-drain).
    // -------------------------------------------------------------------------
    task automatic drive_weight(input bfp12_mant_t w);
        @(posedge clk);
        w_in <= w;
        w_we <= 1'b1;
        @(posedge clk);
        w_in <= '0;
        w_we <= 1'b0;
    endtask

    task automatic run_reduction(
        input  bfp12_mant_t  w,
        input  bfp12_mant_t  acts[$],
        output dense_acc_t   expected
    );
        expected  = '0;
        snap_clr <= 1'b1;
        @(posedge clk);
        snap_clr <= 1'b0;

        for (int i = 0; i < acts.size(); i++) begin
            a_in    <= acts[i];
            a_valid <= 1'b1;
            acc_clr <= (i == 0);
            @(posedge clk);
            expected += dense_acc_t'($signed(acts[i]) * $signed(w));
        end

        a_in    <= '0;
        a_valid <= 1'b0;
        acc_clr <= 1'b0;

        // Drain: the fused MACC (A1+A2+MREG+PREG) is 4 cycles deep. Once a_valid
        // drops, the DSP P register HOLDS the completed sum, so a generous drain
        // is always safe (and insensitive to the exact pipeline depth). 4 idle
        // cycles + the snap cycle = 5 >= 4-cycle latency, so this stays valid.
        repeat (4) @(posedge clk);

        // Snap.
        acc_snap <= 1'b1;
        @(posedge clk);
        acc_snap <= 1'b0;

        // Let acc_out_valid pulse through the capture always_ff.
        @(posedge clk);
        @(posedge clk);
    endtask

    task automatic check_reduction(input dense_acc_t expected, input string label);
        n_reductions++;
        if (!snap_seen) begin
            n_errors++;
            $error("[%0t] %s: no acc_out_valid observed", $time, label);
        end else if (snapped !== expected) begin
            n_errors++;
            $error("[%0t] %s mismatch: dut=%0d expected=%0d (diff=%0d)",
                   $time, label, snapped, expected, snapped - expected);
        end
    endtask

    // -------------------------------------------------------------------------
    // Directed
    // -------------------------------------------------------------------------
    task automatic run_directed();
        dense_acc_t expected;

        $display("[%0t] DIRECTED: K=1  w=+1  a=123", $time);
        begin
            bfp12_mant_t acts[$];
            acts.push_back(12'sd123);
            drive_weight(12'sd1);
            run_reduction(12'sd1, acts, expected);
            check_reduction(expected, "K=1  w=+1");
        end

        $display("[%0t] DIRECTED: K=16 w=-1  a=10..25", $time);
        begin
            bfp12_mant_t acts[$];
            for (int i = 0; i < 16; i++) acts.push_back(12'sd10 + i);
            drive_weight(-12'sd1);
            run_reduction(-12'sd1, acts, expected);
            check_reduction(expected, "K=16 w=-1");
        end

        $display("[%0t] DIRECTED: K=64 w=+2047 a=+2047 (acc headroom)", $time);
        begin
            bfp12_mant_t acts[$];
            for (int i = 0; i < 64; i++) acts.push_back(12'sh7FF);
            drive_weight(12'sh7FF);
            run_reduction(12'sh7FF, acts, expected);
            check_reduction(expected, "K=64 max+");
        end

        $display("[%0t] DIRECTED: K=64 w=-2048 a=-2048 (sign extreme)", $time);
        begin
            bfp12_mant_t acts[$];
            for (int i = 0; i < 64; i++) acts.push_back(12'sh800);
            drive_weight(12'sh800);
            run_reduction(12'sh800, acts, expected);
            check_reduction(expected, "K=64 max-*max-");
        end
    endtask

    // -------------------------------------------------------------------------
    // v2 continuous snap: stream T K=1 token-beats at II=1 with acc_clr=1 on
    // EVERY beat (each beat is a fresh LOAD = an independent token). The PE must
    // emit one result per beat, in order, each = a[t]*w. This is the prefill
    // compute-bound path (no per-token drain). Validates the +5 PE result
    // latency and the do_snap-based valid contract.
    // -------------------------------------------------------------------------
    task automatic run_continuous(input bfp12_mant_t w, input bfp12_mant_t acts[$],
                                  input string label);
        int unsigned T = acts.size();
        stream_mode = GEMM_SNAP_CONTINUOUS;
        drive_weight(w);                 // stationary weight (no beats during load)
        cont_cap.delete();
        cont_capturing = 1'b1;
        @(posedge clk);
        for (int t = 0; t < int'(T); t++) begin
            a_in    <= acts[t];
            a_valid <= 1'b1;
            acc_clr <= 1'b1;             // fresh K=1 LOAD every beat (new token)
            @(posedge clk);
        end
        a_in    <= '0;
        a_valid <= 1'b0;
        acc_clr <= 1'b0;
        // Drain the fused-MACC pipe so the final beats' results are captured
        // (last beat emerges DENSE_MACC_LAT + PE snap reg cycles after it enters).
        repeat (DENSE_MACC_LAT + 4) @(posedge clk);
        cont_capturing = 1'b0;

        if (cont_cap.size() != T) begin
            n_errors++;
            $error("[%0t] %s: captured %0d outputs, expected %0d",
                   $time, label, cont_cap.size(), T);
        end else begin
            for (int t = 0; t < int'(T); t++) begin
                dense_acc_t expd = dense_acc_t'($signed(acts[t]) * $signed(w));
                n_reductions++;
                if (cont_cap[t] !== expd) begin
                    n_errors++;
                    $error("[%0t] %s t=%0d mismatch: dut=%0d expected=%0d",
                           $time, label, t, cont_cap[t], expd);
                end
            end
        end
        stream_mode = GEMM_SNAP_PER_TOKEN;   // restore v1 default
    endtask

    task automatic run_continuous_cases();
        $display("[%0t] CONTINUOUS: T=8 w=+3 distinct tokens", $time);
        begin
            bfp12_mant_t acts[$];
            for (int t = 0; t < 8; t++) acts.push_back(bfp12_mant_t'(12'sd5 + t));
            run_continuous(12'sd3, acts, "cont T=8 w=+3");
        end
        $display("[%0t] CONTINUOUS: T=32 w=-7 distinct tokens", $time);
        begin
            bfp12_mant_t acts[$];
            for (int t = 0; t < 32; t++)
                acts.push_back(bfp12_mant_t'($signed(12'sd100) - 4*t));
            run_continuous(-12'sd7, acts, "cont T=32 w=-7");
        end
        $display("[%0t] CONTINUOUS: T=16 random tokens, w=max", $time);
        begin
            bfp12_mant_t acts[$];
            for (int t = 0; t < 16; t++) acts.push_back(bfp12_mant_t'($urandom()));
            run_continuous(12'sh7FF, acts, "cont T=16 wmax");
        end
    endtask

    // -------------------------------------------------------------------------
    // Random
    // -------------------------------------------------------------------------
    task automatic run_random();
        dense_acc_t expected;
        $display("[%0t] RANDOM: %0d reductions, K ~ U[1, %0d]",
                 $time, N_RANDOM_REDUCTIONS, K_MAX);
        for (int r = 0; r < N_RANDOM_REDUCTIONS; r++) begin
            int          K = $urandom_range(1, K_MAX);
            bfp12_mant_t w = bfp12_mant_t'($urandom());
            bfp12_mant_t acts[$];
            for (int i = 0; i < K; i++) acts.push_back(bfp12_mant_t'($urandom()));
            drive_weight(w);
            run_reduction(w, acts, expected);
            check_reduction(expected, $sformatf("rand r=%0d K=%0d", r, K));
        end
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin
        rst_n        = 1'b0;
        a_in         = '0;
        a_valid      = 1'b0;
        w_we         = 1'b0;
        w_in         = '0;
        noise_rd_in  = '0;
        acc_clr      = 1'b0;
        acc_snap     = 1'b0;
        stream_mode  = GEMM_SNAP_PER_TOKEN;
        cont_capturing = 1'b0;
        snap_clr     = 1'b0;
        n_reductions = 0;
        n_errors     = 0;
        // snap_seen / snapped are driven solely by the capture always_ff
        // (snap_seen reset via !rst_n) — no init write keeps them single-driver.

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        run_directed();
        run_continuous_cases();
        run_random();

        if (n_errors == 0 && n_reductions > 0) begin
            $display("=========================================================");
            $display(" tb_dense_pe: PASS  (%0d reductions, 0 errors)", n_reductions);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_dense_pe: FAIL  (%0d reductions, %0d errors)",
                     n_reductions, n_errors);
            $display("=========================================================");
        end

        $finish;
    end

    // Watchdog: 500us upper bound on the expected ~200us runtime.
    initial begin
        #(T_CLK * 50_000);
        $fatal(1, "tb_dense_pe: watchdog timeout");
    end

endmodule : tb_dense_pe

`default_nettype wire
`endif // ARCHBETTER_TB_DENSE_PE_SV
