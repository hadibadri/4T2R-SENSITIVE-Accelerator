
`timescale 1ns/1ps
`default_nettype none

module tb_dense2sparse_fifo;
    import types_pkg::*;
    localparam time CLK_PERIOD = 10ns;
    logic clk = 1'b0;
    logic rst_n;
    initial forever #(CLK_PERIOD/2) clk = ~clk;
    localparam int unsigned DATA_W             = NOC_DATA_W;
    localparam int unsigned USER_W             = NOC_USER_W;
    localparam int unsigned FIFO_DEPTH         = 64;
    localparam int unsigned ALMOST_FULL_THRESH = FIFO_DEPTH - 8;
    dense2sparse_if #(.DATA_W(DATA_W), .USER_W(USER_W), .FIFO_DEPTH(FIFO_DEPTH))
        in_d2s (clk, rst_n);
    dense2sparse_if #(.DATA_W(DATA_W), .USER_W(USER_W), .FIFO_DEPTH(FIFO_DEPTH))
        out_d2s (clk, rst_n);
    assign out_d2s.almost_full = 1'b0;
    dense2sparse_fifo #(
        .DATA_W            (DATA_W),
        .USER_W            (USER_W),
        .FIFO_DEPTH        (FIFO_DEPTH),
        .ALMOST_FULL_THRESH(ALMOST_FULL_THRESH)
    ) dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .in_d2s (in_d2s.sparse),
        .out_d2s(out_d2s.dense)
    );
    typedef struct {
        logic [DATA_W-1:0] data;
        logic [USER_W-1:0] user;
        logic              last;
    } beat_t;

    beat_t sent_q [$];
    beat_t recv_q [$];
    logic [DATA_W-1:0] p_data;
    logic [USER_W-1:0] p_user;
    logic              p_valid;
    logic              p_last;

    assign in_d2s.data  = p_data;
    assign in_d2s.user  = p_user;
    assign in_d2s.valid = p_valid;
    assign in_d2s.last  = p_last;
    logic c_ready;
    assign out_d2s.ready = c_ready;
    always_ff @(posedge clk) begin
        if (rst_n && out_d2s.valid && out_d2s.ready) begin
            beat_t b;
            b.data = out_d2s.data;
            b.user = out_d2s.user;
            b.last = out_d2s.last;
            recv_q.push_back(b);
        end
    end
    logic saw_prog_full = 1'b0;
    logic saw_full      = 1'b0;
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (in_d2s.almost_full)        saw_prog_full <= 1'b1;
            if (in_d2s.valid && !in_d2s.ready) saw_full  <= 1'b1;
        end
    end
    int n_checks = 0;
    int n_errors = 0;

    function automatic logic [DATA_W-1:0] mk_data(input int unsigned seq);
        logic [DATA_W-1:0] d;
        d = '0;
        for (int i = 0; i < int'(BFP12_BLK); i++) begin
            d[i*BFP12_MANT_W +: BFP12_MANT_W] =
                bfp12_mant_t'(seq + 32'(i) * 32'h13);
        end
        return d;
    endfunction
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
            if (!have_pending) begin
                if ($urandom_range(1, 100) <= send_rate_pct) begin
                    cur.data = mk_data(seq_base + i);
                    cur.user = USER_W'(seq_base + i);
                    cur.last = (i == n - 1);
                    have_pending = 1'b1;
                end
            end
            if (have_pending && !(in_d2s.almost_full && !in_d2s.ready)) begin
                p_data  = cur.data;
                p_user  = cur.user;
                p_last  = cur.last;
                p_valid = 1'b1;
            end else begin
                p_valid = 1'b0;
            end

            @(posedge clk);
            if (have_pending && p_valid && in_d2s.ready) begin
                sent_q.push_back(cur);
                i++;
                have_pending = 1'b0;
            end
        end
        @(negedge clk);
        p_valid = 1'b0;
        p_last  = 1'b0;
    endtask
    task automatic run_consumer(input int unsigned cycles,
                                 input int unsigned ready_rate_pct);
        for (int i = 0; i < int'(cycles); i++) begin
            @(negedge clk);
            c_ready = ($urandom_range(1, 100) <= ready_rate_pct);
        end
        @(negedge clk);
        c_ready = 1'b1;
    endtask
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
    task automatic run_one(input int unsigned n,
                            input int unsigned send_rate_pct,
                            input int unsigned ready_rate_pct,
                            input int unsigned seq_base,
                            input string       label);
        fork : par
            send_stream(n, send_rate_pct, seq_base);
            run_consumer(n * 8 + 64, ready_rate_pct);
        join_any
        disable par;
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
    initial begin
        #500us;
        $fatal(1, "tb_dense2sparse_fifo: watchdog timeout");
    end
    initial begin
        rst_n   = 1'b0;
        p_data  = '0;
        p_user  = '0;
        p_valid = 1'b0;
        p_last  = 1'b0;
        c_ready = 1'b0;

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (8) @(posedge clk);
        run_one(.n(32), .send_rate_pct(100), .ready_rate_pct(100),
                 .seq_base(32'h0000_1000), .label("T1.fast/fast"));
        run_one(.n(40), .send_rate_pct(40), .ready_rate_pct(100),
                 .seq_base(32'h0000_2000), .label("T2.slow/fast"));
        run_one(.n(80), .send_rate_pct(100), .ready_rate_pct(20),
                 .seq_base(32'h0000_3000), .label("T3.fast/slow"));
        run_one(.n(80), .send_rate_pct(50), .ready_rate_pct(50),
                 .seq_base(32'h0000_4000), .label("T4.rand"));
        begin : stress
            int unsigned target;
            target = FIFO_DEPTH + 8;
            c_ready = 1'b0;
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
        if (!saw_prog_full) begin
            n_errors++;
            $error("Coverage: never observed almost_full -- T5 stress did not fill the FIFO");
        end
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
