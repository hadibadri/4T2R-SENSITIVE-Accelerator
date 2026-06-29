// -----------------------------------------------------------------------------
// tb_cim_cell_4t2r.sv  (Phase-8: fused-MACC)
//
// Directed + random testbench for the fused-MACC cim_cell_4t2r with a golden-
// reference scoreboard. The cell now contains the whole multiply-accumulate in
// one DSP48E2 (AREG/BREG/MREG/PREG); acc_out is the LIVE accumulator and acc_clr
// makes the first product of a reduction LOAD instead of accumulate.
//
// The golden model mirrors the exact 4-stage pipeline (A1 -> A2 -> M -> P) in
// pure SV, so acc_out / acc_valid are compared bit-exact against it every cycle.
// (Phase-8b: the DSP48E2's second input register A2/B2 is modeled explicitly.)
//
// Directed corners (each a single-beat reduction, acc_clr=1):
//   * zero weight
//   * +1 / -1 weight
//   * sign-extreme inputs (-2048 * -2048, -2048 * +2047, +2047 * +2047)
// Plus a K=4 accumulation to exercise the load-then-accumulate P path.
//
// Random phase:
//   * many random-length reductions of random activations against a weight that
//     is rewritten between reductions. Weight writes and activations are
//     strictly non-concurrent (dispatcher contract; DUT-asserted).
//
// Exit: prints PASS / FAIL banner and $finish. A watchdog $fatal guards a hang.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_TB_CIM_CELL_4T2R_SV
`define ARCHBETTER_TB_CIM_CELL_4T2R_SV
`default_nettype none
`timescale 1ns/1ps

module tb_cim_cell_4t2r
    import types_pkg::*;
();

    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------
    localparam time T_CLK            = 10ns;   // 100 MHz
    localparam int  N_RANDOM_REDS    = 2_000;
    localparam int  K_MAX            = 32;

    // -------------------------------------------------------------------------
    // DUT nets
    // -------------------------------------------------------------------------
    logic         clk;
    logic         rst_n;

    bfp12_mant_t  a_in;
    logic         a_valid;
    logic         w_we;
    bfp12_mant_t  w_in;
    bfp12_mant_t  noise_rd_in;
    logic         acc_clr;

    dense_acc_t   acc_out;
    logic         acc_valid;

    // -------------------------------------------------------------------------
    // DUT: noise hooks off for baseline correctness.
    // -------------------------------------------------------------------------
    cim_cell_4t2r #(
        .ENABLE_NOISE_HOOKS (1'b0),
        .CELL_ID            (32'd0)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .a_in       (a_in),
        .a_valid    (a_valid),
        .w_we       (w_we),
        .w_in       (w_in),
        .noise_rd_in(noise_rd_in),
        .acc_clr    (acc_clr),
        .acc_out    (acc_out),
        .acc_valid  (acc_valid)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always  #(T_CLK/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Golden scoreboard — a pure-SV mirror of the DUT's 4-stage MACC pipeline.
    //   Stage A1 : ref_a1 / ref_b1 / ref_va1 / ref_clra1  (DSP A1/B1)
    //   Stage A2 : ref_a2 / ref_b2 / ref_va2 / ref_clra2  (DSP A2/B2)
    //   Stage M  : ref_m  / ref_vm  / ref_clrm            (MREG)
    //   Stage P  : ref_p (accumulator) / ref_pvalid       (PREG)
    // -------------------------------------------------------------------------
    bfp12_mant_t ref_w;
    bfp12_mant_t ref_a1, ref_b1;
    logic        ref_va1, ref_clra1;
    bfp12_mant_t ref_a2, ref_b2;
    logic        ref_va2, ref_clra2;
    bfp12_prod_t ref_m;
    logic        ref_vm, ref_clrm;
    dense_acc_t  ref_p;
    logic        ref_pvalid;

    int n_checks;
    int n_errors;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ref_w      <= '0;
            ref_a1     <= '0; ref_b1   <= '0; ref_va1 <= 1'b0; ref_clra1 <= 1'b0;
            ref_a2     <= '0; ref_b2   <= '0; ref_va2 <= 1'b0; ref_clra2 <= 1'b0;
            ref_m      <= '0; ref_vm   <= 1'b0; ref_clrm <= 1'b0;
            ref_p      <= '0; ref_pvalid <= 1'b0;
        end else begin
            if (w_we) ref_w <= w_in;
            // Stage A1 (DSP A1/B1)
            ref_a1    <= a_in;
            ref_b1    <= ref_w;
            ref_va1   <= a_valid;
            ref_clra1 <= acc_clr;
            // Stage A2 (DSP A2/B2)
            ref_a2    <= ref_a1;
            ref_b2    <= ref_b1;
            ref_va2   <= ref_va1;
            ref_clra2 <= ref_clra1;
            // Stage M
            ref_m    <= bfp12_prod_t'($signed(ref_a2) * $signed(ref_b2));
            ref_vm   <= ref_va2;
            ref_clrm <= ref_clra2;
            // Stage P
            ref_pvalid <= ref_vm;
            if (ref_vm) begin
                ref_p <= ref_clrm ? dense_acc_t'(ref_m)
                                  : ref_p + dense_acc_t'(ref_m);
            end
        end
    end

    // Continuous compare: acc_out / acc_valid must track the golden every cycle.
    always_ff @(posedge clk) begin
        if (rst_n) begin
            n_checks <= n_checks + 1;
            if (acc_out !== ref_p) begin
                n_errors <= n_errors + 1;
                $error("[%0t] cim_cell acc_out mismatch: dut=%0d ref=%0d",
                       $time, $signed(acc_out), $signed(ref_p));
            end
            if (acc_valid !== ref_pvalid) begin
                n_errors <= n_errors + 1;
                $error("[%0t] cim_cell acc_valid mismatch: dut=%0b ref=%0b",
                       $time, acc_valid, ref_pvalid);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stimulus primitives. Weight writes and activations are non-concurrent.
    // -------------------------------------------------------------------------
    task automatic drive_weight_write(input bfp12_mant_t w);
        @(posedge clk);
        w_in <= w;
        w_we <= 1'b1;
        @(posedge clk);
        w_in <= '0;
        w_we <= 1'b0;
    endtask

    task automatic drive_idle(input int cycles);
        repeat (cycles) @(posedge clk);
    endtask

    // Drive a K-beat reduction (acc_clr co-fires the first beat).
    task automatic drive_reduction(input bfp12_mant_t acts[$]);
        for (int i = 0; i < acts.size(); i++) begin
            @(posedge clk);
            a_in    <= acts[i];
            a_valid <= 1'b1;
            acc_clr <= (i == 0);
        end
        @(posedge clk);
        a_in    <= '0;
        a_valid <= 1'b0;
        acc_clr <= 1'b0;
        drive_idle(5);   // let the 4-deep pipeline drain; accumulator then holds
    endtask

    task automatic one_beat(input bfp12_mant_t w, input bfp12_mant_t a, input string label);
        bfp12_mant_t acts[$];
        $display("[%0t] DIRECTED: %s  (w=%0d a=%0d)", $time, label, $signed(w), $signed(a));
        drive_weight_write(w);
        drive_idle(1);
        acts.push_back(a);
        drive_reduction(acts);
    endtask

    // -------------------------------------------------------------------------
    // Directed corner cases
    // -------------------------------------------------------------------------
    task automatic run_directed();
        one_beat(12'sd0,    12'sd1234, "zero weight");
        one_beat(12'sd1,    12'sd777,  "weight +1");
        one_beat(-12'sd1,   12'sd777,  "weight -1");
        one_beat(12'sh800,  12'sh800,  "-2048 * -2048");
        one_beat(12'sh800,  12'sh7FF,  "-2048 *  2047");
        one_beat(12'sh7FF,  12'sh7FF,  " 2047 *  2047");

        // K=4 accumulation against weight = +3.
        begin
            bfp12_mant_t acts[$];
            $display("[%0t] DIRECTED: K=4 accumulate, w=+3", $time);
            drive_weight_write(12'sd3);
            drive_idle(1);
            for (int i = 0; i < 4; i++) acts.push_back(12'sd10 + i);
            drive_reduction(acts);
        end
    endtask

    // -------------------------------------------------------------------------
    // Random phase
    // -------------------------------------------------------------------------
    task automatic run_random();
        $display("[%0t] RANDOM: %0d reductions, K ~ U[1, %0d]",
                 $time, N_RANDOM_REDS, K_MAX);
        for (int r = 0; r < N_RANDOM_REDS; r++) begin
            int          K = $urandom_range(1, K_MAX);
            bfp12_mant_t acts[$];
            drive_weight_write(bfp12_mant_t'($urandom()));
            drive_idle(1);
            for (int i = 0; i < K; i++) acts.push_back(bfp12_mant_t'($urandom()));
            drive_reduction(acts);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin
        rst_n       = 1'b0;
        a_in        = '0;
        a_valid     = 1'b0;
        w_we        = 1'b0;
        w_in        = '0;
        noise_rd_in = '0;
        acc_clr     = 1'b0;
        n_checks    = 0;
        n_errors    = 0;

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        run_directed();
        run_random();

        // Final banner
        if (n_errors == 0 && n_checks > 0) begin
            $display("=========================================================");
            $display(" tb_cim_cell_4t2r: PASS  (%0d checks, 0 errors)", n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_cim_cell_4t2r: FAIL  (%0d checks, %0d errors)",
                     n_checks, n_errors);
            $display("=========================================================");
        end

        $finish;
    end

    // Watchdog — kills a hung sim well beyond the expected runtime.
    initial begin
        #(T_CLK * 1_000_000);
        $fatal(1, "tb_cim_cell_4t2r: watchdog timeout");
    end

endmodule : tb_cim_cell_4t2r

`default_nettype wire
`endif // ARCHBETTER_TB_CIM_CELL_4T2R_SV
