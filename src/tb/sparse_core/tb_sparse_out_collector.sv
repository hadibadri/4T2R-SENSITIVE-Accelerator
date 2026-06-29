// -----------------------------------------------------------------------------
// tb_sparse_out_collector.sv  (Phase-8, Stage 8d)
//
// Unit testbench for sparse_out_collector.
//
// What it covers:
//   * One-shot result_valid with a deterministic per-lane accumulator vector;
//     verify that exactly TLMM_LANES URAM writes happen at sequential addresses
//     starting from wr_base_addr, each carrying the matching INT32 accumulator
//     in the low TLMM_ACC_W bits (sign preserved).
//   * Positive ramp, constant, all-negative, and mixed-sign vectors.
//   * Random vectors with random non-zero base addresses.
//   * Back-to-back ops to verify busy_o gates a fresh snap (the DUT must reject
//     result_valid while still draining — checked by sequencing the next op
//     only after busy_o drops).
//
// TB roles:
//   * producer: drive result_acc / result_valid; the DUT owns the drain FSM.
//   * URAM sink: a simple mem array indexed by wr_addr; wr_en always accepted.
//     A per-op write counter also checks that addresses arrive in lane order
//     and that the op produces exactly TLMM_LANES writes.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_sparse_out_collector;
    import types_pkg::*;

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    localparam time CLK_PERIOD = 10ns;
    logic clk = 1'b0;
    logic rst_n;
    initial forever #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Local widths
    // -------------------------------------------------------------------------
    localparam int unsigned WR_DATA_W     = URAM_WIDTH_BITS;
    localparam int unsigned URAM_DEPTH_TB = 1024;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic                   result_valid;
    tlmm_acc_vec_t          result_acc;
    logic [URAM_ADDR_W-1:0] wr_base_addr;

    logic                   wr_en;
    logic [URAM_ADDR_W-1:0] wr_addr;
    logic [WR_DATA_W-1:0]   wr_data;
    logic                   busy_o;

    sparse_out_collector #(.WR_DATA_W(WR_DATA_W)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .result_valid(result_valid),
        .result_acc  (result_acc),
        .wr_base_addr(wr_base_addr),
        .wr_en       (wr_en),
        .wr_addr     (wr_addr),
        .wr_data     (wr_data),
        .busy_o      (busy_o)
    );

    // -------------------------------------------------------------------------
    // Behavioral URAM sink + per-op write tracking.
    // -------------------------------------------------------------------------
    logic [WR_DATA_W-1:0] uram [URAM_DEPTH_TB];

    int unsigned          n_checks;
    int unsigned          n_errors;

    // Per-op write bookkeeping. Single-driver discipline: this always_ff fully
    // owns write_cnt, op_base_q, the URAM, and the sticky address-order flag.
    // It detects the op's snap cycle itself (result_valid && !busy_o, the exact
    // condition the DUT snaps on) so the stimulus task never pokes write_cnt.
    // The task only READS write_cnt (in the gap before the next op snaps).
    int unsigned            write_cnt;
    logic [URAM_ADDR_W-1:0] op_base_q;     // base latched at the op's snap
    logic                   addr_order_bad; // sticky: a write landed off-sequence

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            write_cnt      <= 0;
            op_base_q      <= '0;
            addr_order_bad <= 1'b0;
        end else begin
            // Snap cycle: reset the per-op counter and latch the base.
            if (result_valid && !busy_o) begin
                write_cnt <= 0;
                op_base_q <= wr_base_addr;
            end else if (wr_en) begin
                uram[wr_addr] <= wr_data;
                // In-order address check: the k-th write of an op lands at
                // op_base_q + k.
                if (wr_addr !== URAM_ADDR_W'(op_base_q + URAM_ADDR_W'(write_cnt))) begin
                    $error("tb_sparse_out_collector: write %0d landed at addr %0d, expected %0d",
                           write_cnt, wr_addr, op_base_q + write_cnt);
                    addr_order_bad <= 1'b1;
                end
                write_cnt <= write_cnt + 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Expected-value model: the stimulus task fills exp_acc[] before pulsing
    // result_valid; the checker compares URAM contents after the op drains.
    // -------------------------------------------------------------------------
    tlmm_acc_t exp_acc [TLMM_LANES];

    function automatic void chk(input bit cond, input string msg);
        n_checks++;
        if (!cond) begin
            n_errors++;
            $error("tb_sparse_out_collector: CHECK FAILED — %s", msg);
        end
    endfunction

    // -------------------------------------------------------------------------
    // Run one op: load result_acc from exp_acc, pulse result_valid for 1 cycle,
    // wait for the drain to complete, then verify the URAM contents.
    // -------------------------------------------------------------------------
    task automatic run_op(input logic [URAM_ADDR_W-1:0] base, input string tag);
        @(posedge clk);
        // Present the accumulator bank and the base. The tracking always_ff
        // detects this same snap cycle (result_valid && !busy_o) and resets its
        // own write counter + latches op_base_q — the task does not poke them.
        //
        // result_valid is driven with a NON-BLOCKING assignment (project TB
        // convention, mirrors tb_tlmm_driver's control drives): a blocking drive
        // races the DUT's posedge always_ff in the same active region and can be
        // sampled a cycle early, which would leave result_valid high while
        // have_snap_q is set and (correctly) trip a_no_snap_while_busy. The
        // payload (result_acc / wr_base_addr) is set a cycle ahead and stable by
        // the snap edge, so blocking is fine for those.
        for (int ln = 0; ln < int'(TLMM_LANES); ln++) result_acc[ln] = exp_acc[ln];
        wr_base_addr = base;
        result_valid <= 1'b1;
        @(posedge clk);
        result_valid <= 1'b0;

        // Drain takes TLMM_LANES cycles; wait until busy_o drops.
        // busy_o rises the cycle after result_valid; guard with a bounded loop.
        begin
            int unsigned guard;
            guard = 0;
            // Wait for busy to assert (next cycle), then for it to clear.
            while (!busy_o && guard < 8) begin @(posedge clk); guard++; end
            guard = 0;
            while (busy_o && guard < (TLMM_LANES + 8)) begin @(posedge clk); guard++; end
        end
        // One settling edge so the last write is committed to uram[].
        @(posedge clk);

        // Exactly TLMM_LANES writes for this op.
        chk(write_cnt == TLMM_LANES,
            $sformatf("%s: expected %0d writes, saw %0d", tag, TLMM_LANES, write_cnt));

        // Each lane's INT32 accumulator landed sign-correct in the low bits.
        for (int ln = 0; ln < int'(TLMM_LANES); ln++) begin
            automatic logic [WR_DATA_W-1:0] got;
            got = uram[base + URAM_ADDR_W'(ln)];
            chk(got[TLMM_ACC_W-1:0] === exp_acc[ln],
                $sformatf("%s: lane %0d data mismatch got=%0h exp=%0h",
                          tag, ln, got[TLMM_ACC_W-1:0], exp_acc[ln]));
        end
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin : main
        n_checks     = 0;
        n_errors     = 0;
        result_valid = 1'b0;
        result_acc   = '0;
        wr_base_addr = '0;
        rst_n        = 1'b0;
        for (int i = 0; i < URAM_DEPTH_TB; i++) uram[i] = '0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- 1. Positive ramp at base 0 ------------------------------------
        for (int ln = 0; ln < int'(TLMM_LANES); ln++)
            exp_acc[ln] = tlmm_acc_t'(ln + 1);
        run_op(URAM_ADDR_W'(0), "ramp");

        // ---- 2. Constant at non-zero base ----------------------------------
        for (int ln = 0; ln < int'(TLMM_LANES); ln++)
            exp_acc[ln] = tlmm_acc_t'(32'h0BAD_F00D);
        run_op(URAM_ADDR_W'(64), "const");

        // ---- 3. All-negative (sign preservation) ---------------------------
        for (int ln = 0; ln < int'(TLMM_LANES); ln++)
            exp_acc[ln] = -tlmm_acc_t'((ln * 7) + 3);
        run_op(URAM_ADDR_W'(128), "negative");

        // ---- 4. Mixed sign + extremes --------------------------------------
        for (int ln = 0; ln < int'(TLMM_LANES); ln++) begin
            case (ln % 4)
                0: exp_acc[ln] = tlmm_acc_t'(32'h7FFF_FFFF); // max +
                1: exp_acc[ln] = tlmm_acc_t'(32'h8000_0000); // max -
                2: exp_acc[ln] = '0;
                default: exp_acc[ln] = -tlmm_acc_t'(ln * 12345);
            endcase
        end
        run_op(URAM_ADDR_W'(200), "extremes");

        // ---- 5. Random sweep with random bases -----------------------------
        for (int op = 0; op < 16; op++) begin
            automatic logic [URAM_ADDR_W-1:0] rb;
            rb = URAM_ADDR_W'($urandom_range(0, URAM_DEPTH_TB - TLMM_LANES - 1));
            for (int ln = 0; ln < int'(TLMM_LANES); ln++)
                exp_acc[ln] = tlmm_acc_t'($urandom);
            run_op(rb, $sformatf("rand[%0d]", op));
        end

        // ---- Done ----------------------------------------------------------
        repeat (4) @(posedge clk);
        if (n_errors == 0 && !addr_order_bad)
            $display("tb_sparse_out_collector: PASS  (%0d / %0d checks)", n_checks, n_checks);
        else
            $display("tb_sparse_out_collector: FAIL  (%0d errors / %0d checks, addr_order_bad=%0b)",
                     n_errors, n_checks, addr_order_bad);
        $finish;
    end

    // -------------------------------------------------------------------------
    // Watchdog
    // -------------------------------------------------------------------------
    initial begin : watchdog
        #(CLK_PERIOD * 5000);
        $fatal(1, "tb_sparse_out_collector: watchdog timeout");
    end

endmodule : tb_sparse_out_collector

`default_nettype wire
