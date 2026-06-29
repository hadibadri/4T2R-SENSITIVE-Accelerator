
`timescale 1ns/1ps
`default_nettype none

module tb_dense_array_bank;
    import types_pkg::*;

    localparam time         T_CLK     = 10ns;
    localparam int unsigned BT         = 64;
    localparam int unsigned PHYS_COLS  = DENSE_PHYS_COLS;
    localparam int unsigned COLS       = DENSE_ARRAY_COLS;
    localparam int unsigned TILE_COLS  = DENSE_LOGICAL_TILE_COLS;
    localparam int unsigned TILE_GC_W  = $clog2(DENSE_LOGICAL_TILE_COLS);

    logic clk = 1'b0;
    logic rst_n;
    always #(T_CLK/2) clk = ~clk;
    logic                          tile_first;
    logic                          upd_valid;
    logic [BATCH_TOK_W-1:0]        upd_tok;
    logic [TILE_GC_W-1:0]          upd_gc;
    logic                          upd_last;
    logic                          upd_first;
    array_acc_t [PHYS_COLS-1:0]    phys_strip;
    logic [BATCH_TOK_W-1:0]        batch_n;
    logic                          drain_busy;
    array_acc_t [COLS-1:0]         y_out;
    logic                          y_valid;
    logic                          drain_active;

    dense_array_bank #(
        .ARRAY_ID     (0),
        .BATCH_T      (BT),
        .BANK_REG_MAX (8)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .tile_first(tile_first),
        .upd_valid(upd_valid), .upd_tok(upd_tok), .upd_gc(upd_gc),
        .upd_last(upd_last), .upd_first(upd_first), .phys_strip(phys_strip),
        .batch_n(batch_n), .drain_busy(drain_busy),
        .y_out(y_out), .y_valid(y_valid), .drain_active(drain_active)
    );
    logic bp_en;
    always_ff @(posedge clk) begin
        if (!rst_n)      drain_busy <= 1'b0;
        else if (bp_en)  drain_busy <= ($urandom_range(0,3) == 0);
        else             drain_busy <= 1'b0;
    end
    array_acc_t [COLS-1:0] cap_y [BT];
    int unsigned           cap_cnt;
    logic                  cap_en;
    logic                  cap_clr;
    always_ff @(posedge clk) begin
        if (!rst_n || cap_clr) begin
            cap_cnt <= 0;
        end else if (cap_en && y_valid) begin
            cap_y[cap_cnt] <= y_out;
            cap_cnt        <= cap_cnt + 1;
        end
    end
    int unsigned n_checks, n_errors;
    function automatic void chk(input bit cond, input string msg);
        n_checks++;
        if (!cond) begin n_errors++; $error("[%0t] %s", $time, msg); end
    endfunction
    function automatic array_acc_t strip_val(int gr, int gc, int tok, int pc);
        int v;
        v = ((tok*131 + gr*37 + gc*11 + pc*3) % 4000) - 2000;
        return array_acc_t'(v);
    endfunction

    array_acc_t [COLS-1:0] y_exp [BT];

    task automatic build_golden(input int ROW_CNT, input int COL_CNT, input int T);
        for (int tok = 0; tok < T; tok++) begin
            for (int col = 0; col < int'(COLS); col++) begin
                automatic array_acc_t acc = '0;
                if (col < COL_CNT*int'(PHYS_COLS))
                    for (int gr = 0; gr < ROW_CNT; gr++)
                        acc += strip_val(gr, col/int'(PHYS_COLS), tok,
                                         col % int'(PHYS_COLS));
                y_exp[tok][col] = acc;
            end
        end
    endtask
    task automatic drive_gemm(input int ROW_CNT, input int COL_CNT, input int T);
        @(negedge clk);
        batch_n    = BATCH_TOK_W'(T);
        tile_first = 1'b1;
        upd_valid  = 1'b0;
        @(negedge clk);
        tile_first = 1'b0;

        for (int gr = 0; gr < ROW_CNT; gr++) begin
            for (int gc = 0; gc < COL_CNT; gc++) begin
                for (int tok = 0; tok < T; tok++) begin
                    @(negedge clk);
                    upd_valid = 1'b1;
                    upd_tok   = BATCH_TOK_W'(tok);
                    upd_gc    = TILE_GC_W'(gc);
                    upd_first = (gr == 0);
                    upd_last  = (gr == ROW_CNT-1) && (gc == COL_CNT-1)
                             && (tok == T-1);
                    for (int pc = 0; pc < int'(PHYS_COLS); pc++)
                        phys_strip[pc] = strip_val(gr, gc, tok, pc);
                end
                @(negedge clk);
                upd_valid = 1'b0;
                upd_last  = 1'b0;
                repeat (3) @(negedge clk);
            end
        end
        @(negedge clk);
        upd_valid = 1'b0;
    endtask

    task automatic run_case(input int ROW_CNT, input int COL_CNT, input int T,
                            input bit use_bp, input string label);
        int waited;
        @(negedge clk);
        cap_en  = 1'b0;
        cap_clr = 1'b1;
        @(negedge clk);
        cap_clr = 1'b0;
        bp_en   = use_bp;
        build_golden(ROW_CNT, COL_CNT, T);

        cap_en = 1'b1;
        drive_gemm(ROW_CNT, COL_CNT, T);
        waited = 0;
        while (cap_cnt < T) begin
            @(posedge clk);
            if (++waited > 20000)
                $fatal(1, "%s: drain stalled at %0d/%0d", label, cap_cnt, T);
        end
        repeat (4) @(posedge clk);
        cap_en = 1'b0;
        bp_en  = 1'b0;

        chk(cap_cnt == T,
            $sformatf("%s: drained %0d outputs, expected %0d", label, cap_cnt, T));
        for (int tok = 0; tok < T; tok++) begin
            automatic int bad = 0;
            for (int col = 0; col < int'(COLS); col++)
                if (cap_y[tok][col] !== y_exp[tok][col]) bad++;
            chk(bad == 0,
                $sformatf("%s: token %0d had %0d/%0d col mismatches",
                          label, tok, bad, COLS));
        end
        begin
            automatic int dpairs = 0;
            for (int tok = 1; tok < T; tok++) begin
                automatic bit diff = 1'b0;
                for (int col = 0; col < COL_CNT*int'(PHYS_COLS); col++)
                    if (cap_y[tok][col] !== cap_y[tok-1][col]) diff = 1'b1;
                if (diff) dpairs++;
            end
            chk(dpairs == T-1,
                $sformatf("%s: only %0d/%0d adjacent token pairs distinct",
                          label, dpairs, T-1));
        end
        $display("[%0t] %s: %0d tokens checked (ROW=%0d COL=%0d T=%0d, bp=%0b)",
                 $time, label, T, ROW_CNT, COL_CNT, T, use_bp);
    endtask
    initial begin
        #2ms;
        $fatal(1, "tb_dense_array_bank: watchdog timeout");
    end
    initial begin
        rst_n      = 1'b0;
        tile_first = 1'b0;
        upd_valid  = 1'b0;
        upd_tok    = '0;
        upd_gc     = '0;
        upd_last   = 1'b0;
        upd_first  = 1'b0;
        phys_strip = '0;
        batch_n    = BATCH_TOK_W'(1);
        bp_en      = 1'b0;
        cap_en     = 1'b0;
        cap_clr    = 1'b0;
        n_checks   = 0;
        n_errors   = 0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        run_case(2, 2, 8, 1'b1, "A.partial_T8_bp");
        run_case(3, 4, 64, 1'b0, "B.full_T64");

        repeat (4) @(posedge clk);
        if (n_errors == 0)
            $display("tb_dense_array_bank: PASS  (%0d checks, 0 errors)", n_checks);
        else
            $display("tb_dense_array_bank: FAIL  (%0d errors / %0d checks)",
                     n_errors, n_checks);
        $finish;
    end

endmodule : tb_dense_array_bank

`default_nettype wire
