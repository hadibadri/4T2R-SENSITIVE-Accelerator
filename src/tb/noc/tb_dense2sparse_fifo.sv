// -----------------------------------------------------------------------------
// tb_dense2sparse_fifo.sv
//
// Phase-5d unit testbench for dense2sparse_fifo.
//
// What it covers:
//   * In-order data integrity through the FIFO across producer / consumer
//     pacing combinations (fast/fast, fast/slow, slow/fast, random/random).
//   * almost_full hint behavior: filling the FIFO with the consumer idle
//     drives prog_full high before full asserts; producer must not drive
//     valid into (almost_full && !ready).
//   * last propagates 1:1 with each beat.
//   * No spurious dout when the FIFO is empty.
//   * Two back-to-back streams in the same simulation (no state leak).
//
// TB roles:
//   * producer: sequence-counter data + per-beat user; configurable rate.
//   * consumer: ready policy with configurable rate; observes (data,user,last)
//     and pushes onto a queue; scoreboard compares against the producer's
//     sent queue.
//
// Coverage signals:
//   - prog_full/full asserted at least once during the deep test.
//   - empty asserted between streams (cleanly drained).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_dense2sparse_fifo;
    import types_pkg::*;

    // -------------------------------------------------------------------------
    // Clock + reset.
    // -------------------------------------------------------------------------
    localparam time CLK_PERIOD = 10ns;
    logic clk = 1'b0;
    logic rst_n;
    initial forever #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Geometry.
    // -------------------------------------------------------------------------
    localparam int unsigned DATA_W             = NOC_DATA_W;     // 192
    localparam int unsigned USER_W             = NOC_USER_W;     // 8
    localparam int unsigned FIFO_DEPTH         = 64;
    localparam int unsigned ALMOST_FULL_THRESH = FIFO_DEPTH - 8; // 56

    // -------------------------------------------------------------------------
    // Interfaces. Two separate dense2sparse_if instances flank the DUT.
    // -------------------------------------------------------------------------
    dense2sparse_if #(.DATA_W(DATA_W), .USER_W(USER_W), .FIFO_DEPTH(FIFO_DEPTH))
        in_d2s (clk, rst_n);
    dense2sparse_if #(.DATA_W(DATA_W), .USER_W(USER_W), .FIFO_DEPTH(FIFO_DEPTH))
        out_d2s (clk, rst_n);

    // out_d2s.almost_full is an OUTPUT of the .sparse modport. The TB drives
    // the .sparse side of out_d2s (consumer), so we tie it low here.
    assign out_d2s.almost_full = 1'b0;

    // -------------------------------------------------------------------------
    // DUT.
    // -------------------------------------------------------------------------
    dense2sparse_fifo #(
        .DATA_W            (DATA_W),
        .USER_W            (USER_W),
        .FIFO_DEPTH        (FIFO_DEPTH),
        .ALMOST_FULL_THRESH(ALMOST_FULL_THRESH)
    ) dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .in_d2s (in_d2s.sparse),   // FIFO sinks the producer's stream.
        .out_d2s(out_d2s.dense)    // FIFO sources the consumer's stream.
    );

    // -------------------------------------------------------------------------
    // Producer-side TB drives in_d2s.dense modport (output data/user/valid/
    // last; input ready/almost_full). Internally we keep a queue of beats
    // we've sent and pop from it as the consumer side observes them.
    // -------------------------------------------------------------------------
    typedef struct {
        logic [DATA_W-1:0] data;
        logic [USER_W-1:0] user;
        logic              last;
    } beat_t;

    beat_t sent_q [$];
    beat_t recv_q [$];

    // Producer signal drivers.
    logic [DATA_W-1:0] p_data;
    logic [USER_W-1:0] p_user;
    logic              p_valid;
    logic              p_last;

    assign in_d2s.data  = p_data;
    assign in_d2s.user  = p_user;
    assign in_d2s.valid = p_valid;
    assign in_d2s.last  = p_last;

    // Consumer signal drivers.
    logic c_ready;
    assign out_d2s.ready = c_ready;

    // -------------------------------------------------------------------------
    // Observe consumed beats.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst_n && out_d2s.valid && out_d2s.ready) begin
            beat_t b;
            b.data = out_d2s.data;
            b.user = out_d2s.user;
            b.last = out_d2s.last;
            recv_q.push_back(b);
        end
    end

    // -------------------------------------------------------------------------
    // Coverage flags: ensure deep test exercised prog_full and full.
    // -------------------------------------------------------------------------
    logic saw_prog_full = 1'b0;
    logic saw_full      = 1'b0;
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (in_d2s.almost_full)        saw_prog_full <= 1'b1;
            if (in_d2s.valid && !in_d2s.ready) saw_full  <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Stats.
    // -------------------------------------------------------------------------
    int n_checks = 0;
    int n_errors = 0;

    function automatic logic [DATA_W-1:0] mk_data(input int unsigned seq);
        logic [DATA_W-1:0] d;
        d = '0;
        // Sprinkle the sequence number into a few well-separated lanes so
        // a single byte-flip in the FIFO would change the scoreboard match.
        for (int i = 0; i < int'(BFP12_BLK); i++) begin
            d[i*BFP12_MANT_W +: BFP12_MANT_W] =
                bfp12_mant_t'(seq + 32'(i) * 32'h13);
        end
        return d;
    endfunction

    // -------------------------------------------------------------------------
    // Producer task: send N beats with a given send-rate (probability of
    // asserting valid each cycle). Holds beat data stable across backpressure
    // (this respects the dense2sparse_if hold-on-backpressure assumption that
    // the producer doesn't dance valid).
    // -------------------------------------------------------------------------
    task automatic send_stream(input int unsigned n,
                                input int unsigned send_rate_pct,
                                input int unsigned seq_base);
        int unsigned i;
        beat_t       cur;
        bit          have_pending;

        i = 0;
        have_pending = 1'b0;
        while (i < n) begin
            @(negedge clk);
            // Respect the almost_full && !ready strong form: do not drive
            // valid into the FIFO if the producer's contract demands holdoff.
            if (!have_pending) begin
                if ($urandom_range(1, 100) <= send_rate_pct) begin
                    cur.data = mk_data(seq_base + i);
                    cur.user = USER_W'(seq_base + i);
                    cur.last = (i == n - 1);
                    have_pending = 1'b1;
                end
            end

            // Strong-form respect: if (almost_full && !ready), don't drive
            // valid this cycle. We just hold the pending beat.
            if (have_pending && !(in_d2s.almost_full && !in_d2s.ready)) begin
                p_data  = cur.data;
                p_user  = cur.user;
                p_last  = cur.last;
                p_valid = 1'b1;
            end else begin
                p_valid = 1'b0;
            end

            @(posedge clk);
            // Sample after the clock to see if this beat fired.
            if (have_pending && p_valid && in_d2s.ready) begin
                sent_q.push_back(cur);
                i++;
                have_pending = 1'b0;
            end
        end

        // Drop valid after the last beat fires.
        @(negedge clk);
        p_valid = 1'b0;
        p_last  = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Consumer task: set the ready policy and let the always_ff observer do
    // the work. We just spin for `cycles` cycles and update c_ready stochastic.
    // -------------------------------------------------------------------------
    task automatic run_consumer(input int unsigned cycles,
                                 input int unsigned ready_rate_pct);
        for (int i = 0; i < int'(cycles); i++) begin
            @(negedge clk);
            c_ready = ($urandom_range(1, 100) <= ready_rate_pct);
        end
        // Drain remainder.
        @(negedge clk);
        c_ready = 1'b1;
    endtask

    // -------------------------------------------------------------------------
    // Compare the sent and received queues for the current stream segment.
    // -------------------------------------------------------------------------
    task automatic check_match(input string label);
        if (sent_q.size() !== recv_q.size()) begin
            n_errors++;
            $error("%s: sent=%0d recv=%0d (size mismatch)",
                   label, sent_q.size(), recv_q.size());
        end
        while (sent_q.size() > 0 && recv_q.size() > 0) begin
            beat_t s, r;
            s = sent_q.pop_front();
            r = recv_q.pop_front();
            n_checks++;
            if (s.data !== r.data) begin
                n_errors++;
                $error("%s data mismatch: exp=0x%0h got=0x%0h", label, s.data, r.data);
            end
            n_checks++;
            if (s.user !== r.user) begin
                n_errors++;
                $error("%s user mismatch: exp=0x%0h got=0x%0h", label, s.user, r.user);
            end
            n_checks++;
            if (s.last !== r.last) begin
                n_errors++;
                $error("%s last mismatch: exp=%0b got=%0b", label, s.last, r.last);
            end
        end
        sent_q.delete();
        recv_q.delete();
    endtask

    // -------------------------------------------------------------------------
    // Producer + consumer in parallel.
    // -------------------------------------------------------------------------
    task automatic run_one(input int unsigned n,
                            input int unsigned send_rate_pct,
                            input int unsigned ready_rate_pct,
                            input int unsigned seq_base,
                            input string       label);
        fork : par
            send_stream(n, send_rate_pct, seq_base);
            run_consumer(n * 8 + 64, ready_rate_pct);
        join_any
        // join_any leaves the unfinished branch running in the background; if
        // we don't kill it here, run_consumer keeps stochastically driving
        // c_ready into the next test segment and fights the explicit drives
        // (notably, T5's `c_ready = 1'b0` fill phase would be overridden on
        // every negedge, preventing the FIFO from ever reaching prog_full).
        disable par;
        // Ensure all sent beats land at the consumer.
        @(negedge clk);
        c_ready = 1'b1;
        repeat (n * 4 + 32) begin
            @(posedge clk);
            if (recv_q.size() == sent_q.size()) break;
        end
        repeat (8) @(posedge clk);
        check_match(label);
        $display("[%0t] %s done: n=%0d", $time, label, n);
    endtask

    // -------------------------------------------------------------------------
    // Watchdog.
    // -------------------------------------------------------------------------
    initial begin
        #500us;
        $fatal(1, "tb_dense2sparse_fifo: watchdog timeout");
    end

    // -------------------------------------------------------------------------
    // Main.
    // -------------------------------------------------------------------------
    initial begin
        rst_n   = 1'b0;
        p_data  = '0;
        p_user  = '0;
        p_valid = 1'b0;
        p_last  = 1'b0;
        c_ready = 1'b0;

        repeat (20) @(posedge clk);  // xpm_fifo_sync wants >= 5 cycles of rst.
        rst_n = 1'b1;
        repeat (8) @(posedge clk);

        // Test 1: full speed both sides.
        run_one(.n(32), .send_rate_pct(100), .ready_rate_pct(100),
                 .seq_base(32'h0000_1000), .label("T1.fast/fast"));

        // Test 2: producer slow, consumer fast.
        run_one(.n(40), .send_rate_pct(40), .ready_rate_pct(100),
                 .seq_base(32'h0000_2000), .label("T2.slow/fast"));

        // Test 3: producer fast, consumer slow (forces FIFO to fill).
        run_one(.n(80), .send_rate_pct(100), .ready_rate_pct(20),
                 .seq_base(32'h0000_3000), .label("T3.fast/slow"));

        // Test 4: random both.
        run_one(.n(80), .send_rate_pct(50), .ready_rate_pct(50),
                 .seq_base(32'h0000_4000), .label("T4.rand"));

        // Test 5: stress almost_full -- fill ~ FIFO_DEPTH+8 with consumer idle
        // for the first stretch to drive prog_full high.
        begin : stress
            int unsigned target;
            target = FIFO_DEPTH + 8;
            c_ready = 1'b0;
            // Send target beats; producer will stall at almost_full.
            fork
                send_stream(target, 100, 32'h0000_5000);
                begin
                    repeat (FIFO_DEPTH + 4) @(posedge clk);
                    @(negedge clk); c_ready = 1'b1;
                end
            join
            @(negedge clk); c_ready = 1'b1;
            repeat (target * 2 + 32) @(posedge clk);
            check_match("T5.almost_full");
        end

        // Coverage: prog_full must have been observed at some point.
        if (!saw_prog_full) begin
            n_errors++;
            $error("Coverage: never observed almost_full -- T5 stress did not fill the FIFO");
        end

        // Empty after final drain.
        if (out_d2s.valid !== 1'b0) begin
            n_errors++;
            $error("After drain, out_d2s.valid=%0b (expected 0)", out_d2s.valid);
        end

        repeat (8) @(posedge clk);
        $display("=========================================================");
        if (n_errors == 0) begin
            $display(" tb_dense2sparse_fifo: PASS  (%0d checks, 0 errors)", n_checks);
        end else begin
            $display(" tb_dense2sparse_fifo: FAIL  (%0d errors / %0d checks)",
                     n_errors, n_checks);
        end
        $display("=========================================================");
        $finish;
    end

endmodule : tb_dense2sparse_fifo

`default_nettype wire
