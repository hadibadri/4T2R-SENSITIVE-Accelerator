
`timescale 1ns/1ps
`default_nettype none

module tb_dense_out_collector;
    import types_pkg::*;
    localparam time CLK_PERIOD = 10ns;
    logic clk = 1'b0;
    logic rst_n;
    initial forever #(CLK_PERIOD/2) clk = ~clk;
    localparam int unsigned WR_DATA_W      = URAM_WIDTH_BITS;
    localparam int unsigned NUM_D2S_BEATS  = DENSE_ARRAY_COLS / BFP12_BLK;
    localparam int unsigned URAM_DEPTH_TB  = 1024;
    dense2sparse_if #(.DATA_W(BFP12_BLK*BFP12_MANT_W), .USER_W(BFP12_EXP_W))
        d2s (clk, rst_n);
    logic                                        y_valid;
    array_acc_t [DENSE_ARRAY_COLS-1:0]           y_out;
    logic [URAM_ADDR_W-1:0]                      wr_base_addr;
    logic                                        wr_en;
    logic [URAM_ADDR_W-1:0]                      wr_addr;
    logic [WR_DATA_W-1:0]                        wr_data;

    logic                                        busy_o;

    dense_out_collector #(.WR_DATA_W(WR_DATA_W)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .y_valid     (y_valid),
        .y_out       (y_out),
        .wr_base_addr(wr_base_addr),
        .wr_en       (wr_en),
        .wr_addr     (wr_addr),
        .wr_data     (wr_data),
        .d2s         (d2s.dense),
        .busy_o      (busy_o)
    );
    logic sink_ready;
    assign d2s.ready       = sink_ready;
    assign d2s.almost_full = 1'b0;

    typedef struct {
        logic [BFP12_BLK*BFP12_MANT_W-1:0] data;
        logic [BFP12_EXP_W-1:0]             user;
        logic                               last;
    } d2s_beat_t;

    d2s_beat_t d2s_obs [$];

    always_ff @(posedge clk) begin
        if (rst_n && d2s.valid && d2s.ready) begin
            d2s_beat_t b;
            b.data = d2s.data;
            b.user = d2s.user;
            b.last = d2s.last;
            d2s_obs.push_back(b);
        end
    end
    logic [WR_DATA_W-1:0] uram_mem [0:URAM_DEPTH_TB-1];

    always_ff @(posedge clk) begin
        if (rst_n && wr_en) begin
            uram_mem[wr_addr[$clog2(URAM_DEPTH_TB)-1:0]] <= wr_data;
        end
    end
    int n_checks = 0;
    int n_errors = 0;

    function automatic void check_eq_44 (
        input array_acc_t got, exp,
        input string      label
    );
        n_checks++;
        if (got !== exp) begin
            n_errors++;
            $error("[%0t] %s: 44b mismatch got=%0d exp=%0d",
                   $time, label, $signed(got), $signed(exp));
        end
    endfunction

    function automatic void check_eq_12 (
        input bfp12_mant_t got, exp,
        input string       label
    );
        n_checks++;
        if (got !== exp) begin
            n_errors++;
            $error("[%0t] %s: mant mismatch got=%0d exp=%0d",
                   $time, label, $signed(got), $signed(exp));
        end
    endfunction

    function automatic void check_eq_exp (
        input bfp12_exp_t got, exp,
        input string      label
    );
        n_checks++;
        if (got !== exp) begin
            n_errors++;
            $error("[%0t] %s: exp mismatch got=%0d exp=%0d",
                   $time, label, $signed(got), $signed(exp));
        end
    endfunction
    function automatic logic [ARRAY_ACC_W-1:0] golden_abs_val (
        input array_acc_t v
    );
        logic [ARRAY_ACC_W-1:0] raw;
        raw = v;
        return (v < 0) ? ((~raw) + 1'b1) : raw;
    endfunction

    function automatic int golden_msb_pos (
        input logic [ARRAY_ACC_W-1:0] w
    );
        int pos;
        pos = 0;
        for (int b = 0; b < int'(ARRAY_ACC_W); b++) begin
            if (w[b]) pos = b;
        end
        return pos;
    endfunction

    function automatic bfp12_exp_t golden_shared_exp (
        input array_acc_t blk [BFP12_BLK]
    );
        logic [ARRAY_ACC_W-1:0] mx;
        int                     p;
        mx = '0;
        for (int i = 0; i < int'(BFP12_BLK); i++) begin
            automatic logic [ARRAY_ACC_W-1:0] a;
            a = golden_abs_val(blk[i]);
            if (a > mx) mx = a;
        end
        p = golden_msb_pos(mx);
        return (p > int'(BFP12_MANT_W) - 2)
             ? bfp12_exp_t'(p - (int'(BFP12_MANT_W) - 2))
             : '0;
    endfunction

    function automatic bfp12_mant_t golden_mant (
        input array_acc_t v,
        input bfp12_exp_t shared_exp
    );
        return bfp12_mant_t'(v >>> shared_exp);
    endfunction
    task automatic run_snap (
        input logic [URAM_ADDR_W-1:0]       base,
        input array_acc_t                    v [DENSE_ARRAY_COLS],
        input bit                            random_bp,
        input string                         label
    );
        int d2s_prev_size;
        @(posedge clk);
        wr_base_addr = base;
        for (int i = 0; i < int'(DENSE_ARRAY_COLS); i++) begin
            y_out[i] = v[i];
        end
        d2s_prev_size = d2s_obs.size();
        y_valid <= 1'b1;
        @(posedge clk);
        y_valid <= 1'b0;
        @(posedge clk);
        while (busy_o || d2s.valid) begin
            @(posedge clk);
            if (random_bp) sink_ready <= ($urandom_range(0, 3) != 0);
        end
        sink_ready <= 1'b1;
        @(posedge clk);
        for (int i = 0; i < int'(DENSE_ARRAY_COLS); i++) begin
            array_acc_t got, exp_v;
            logic [WR_DATA_W-1:0] word;
            word = uram_mem[(base + i) % URAM_DEPTH_TB];
            got  = array_acc_t'(word[ARRAY_ACC_W-1:0]);
            exp_v = v[i];
            check_eq_44(got, exp_v, $sformatf("%s.uram[%0d]", label, i));
        end
        if ((d2s_obs.size() - d2s_prev_size) != int'(NUM_D2S_BEATS)) begin
            n_errors++;
            $error("%s: expected %0d d2s beats, got %0d",
                   label, NUM_D2S_BEATS, d2s_obs.size() - d2s_prev_size);
        end else begin
            for (int k = 0; k < int'(NUM_D2S_BEATS); k++) begin
                array_acc_t blk [BFP12_BLK];
                bfp12_exp_t exp_sh;
                d2s_beat_t  got_beat;
                got_beat = d2s_obs[d2s_prev_size + k];
                for (int i = 0; i < int'(BFP12_BLK); i++) begin
                    blk[i] = v[k*int'(BFP12_BLK) + i];
                end
                exp_sh = golden_shared_exp(blk);
                check_eq_exp(got_beat.user, exp_sh,
                             $sformatf("%s.beat[%0d].exp", label, k));
                for (int i = 0; i < int'(BFP12_BLK); i++) begin
                    bfp12_mant_t got_m, exp_m;
                    got_m = got_beat.data[i*BFP12_MANT_W +: BFP12_MANT_W];
                    exp_m = golden_mant(blk[i], exp_sh);
                    check_eq_12(got_m, exp_m,
                                $sformatf("%s.beat[%0d].mant[%0d]", label, k, i));
                end
                n_checks++;
                if (got_beat.last !== (k == int'(NUM_D2S_BEATS) - 1)) begin
                    n_errors++;
                    $error("%s.beat[%0d].last: got=%0b exp=%0b",
                           label, k, got_beat.last, (k == int'(NUM_D2S_BEATS) - 1));
                end
            end
        end
    endtask
    initial begin
        #200us;
        $fatal(1, "tb_dense_out_collector: watchdog timeout");
    end
    initial begin
        rst_n        = 1'b0;
        y_valid      = 1'b0;
        y_out        = '{default: '0};
        wr_base_addr = '0;
        sink_ready   = 1'b1;
        for (int i = 0; i < URAM_DEPTH_TB; i++) uram_mem[i] = '0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        begin
            array_acc_t v [DENSE_ARRAY_COLS];
            for (int i = 0; i < int'(DENSE_ARRAY_COLS); i++) begin
                v[i] = array_acc_t'((i % 2) ? -(i + 1) : (i + 1));
            end
            run_snap(URAM_ADDR_W'(0), v, 1'b0, "T1.small");
        end
        begin
            array_acc_t v [DENSE_ARRAY_COLS];
            for (int i = 0; i < int'(DENSE_ARRAY_COLS); i++) begin
                v[i] = array_acc_t'($signed(44'sh1A2B3C4D0) + i);
            end
            run_snap(URAM_ADDR_W'(256), v, 1'b0, "T2.large");
        end
        begin
            array_acc_t v [DENSE_ARRAY_COLS];
            for (int i = 0; i < int'(DENSE_ARRAY_COLS); i++) begin
                if (i % int'(BFP12_BLK) == 0) begin
                    v[i] = array_acc_t'($signed(44'sh7FFFFFFFF00));
                end else begin
                    v[i] = array_acc_t'(i - 64);
                end
            end
            run_snap(URAM_ADDR_W'(512), v, 1'b0, "T3.outliers");
        end
        begin
            array_acc_t v [DENSE_ARRAY_COLS];
            for (int i = 0; i < int'(DENSE_ARRAY_COLS); i++) v[i] = '0;
            run_snap(URAM_ADDR_W'(768), v, 1'b0, "T4.zeros");
        end
        begin
            array_acc_t v [DENSE_ARRAY_COLS];
            for (int i = 0; i < int'(DENSE_ARRAY_COLS); i++) begin
                v[i] = array_acc_t'($urandom() & 44'hFFFFFFFFFFF);
                if ($urandom_range(0, 1)) v[i] = -v[i];
            end
            run_snap(URAM_ADDR_W'(128), v, 1'b1, "T5.rand_bp");
        end
        begin
            array_acc_t vA [DENSE_ARRAY_COLS];
            array_acc_t vB [DENSE_ARRAY_COLS];
            for (int i = 0; i < int'(DENSE_ARRAY_COLS); i++) begin
                vA[i] = array_acc_t'(i + 7);
                vB[i] = array_acc_t'(-(i + 3));
            end
            run_snap(URAM_ADDR_W'(384), vA, 1'b0, "T6a");
            run_snap(URAM_ADDR_W'(640), vB, 1'b0, "T6b");
        end
        repeat (8) @(posedge clk);
        if (n_errors == 0) begin
            $display("=========================================================");
            $display("tb_dense_out_collector: PASS  (%0d / %0d checks)",
                     n_checks, n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display("tb_dense_out_collector: FAIL  (%0d errors / %0d checks)",
                     n_errors, n_checks);
            $display("=========================================================");
        end
        $finish;
    end

endmodule : tb_dense_out_collector

`default_nettype wire
