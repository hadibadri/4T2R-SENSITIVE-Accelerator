
`timescale 1ns/1ps
`default_nettype none

module tb_sparse_out_collector;
    import types_pkg::*;
    localparam time CLK_PERIOD = 10ns;
    logic clk = 1'b0;
    logic rst_n;
    initial forever #(CLK_PERIOD/2) clk = ~clk;
    localparam int unsigned WR_DATA_W     = URAM_WIDTH_BITS;
    localparam int unsigned URAM_DEPTH_TB = 1024;
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
    logic [WR_DATA_W-1:0] uram [URAM_DEPTH_TB];

    int unsigned          n_checks;
    int unsigned          n_errors;
    int unsigned            write_cnt;
    logic [URAM_ADDR_W-1:0] op_base_q;
    logic                   addr_order_bad;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            write_cnt      <= 0;
            op_base_q      <= '0;
            addr_order_bad <= 1'b0;
        end else begin
            if (result_valid && !busy_o) begin
                write_cnt <= 0;
                op_base_q <= wr_base_addr;
            end else if (wr_en) begin
                uram[wr_addr] <= wr_data;
                if (wr_addr !== URAM_ADDR_W'(op_base_q + URAM_ADDR_W'(write_cnt))) begin
                    $error("tb_sparse_out_collector: write %0d landed at addr %0d, expected %0d",
                           write_cnt, wr_addr, op_base_q + write_cnt);
                    addr_order_bad <= 1'b1;
                end
                write_cnt <= write_cnt + 1;
            end
        end
    end
    tlmm_acc_t exp_acc [TLMM_LANES];

    function automatic void chk(input bit cond, input string msg);
        n_checks++;
        if (!cond) begin
            n_errors++;
            $error("tb_sparse_out_collector: CHECK FAILED — %s", msg);
        end
    endfunction
    task automatic run_op(input logic [URAM_ADDR_W-1:0] base, input string tag);
        @(posedge clk);
        for (int ln = 0; ln < int'(TLMM_LANES); ln++) result_acc[ln] = exp_acc[ln];
        wr_base_addr = base;
        result_valid <= 1'b1;
        @(posedge clk);
        result_valid <= 1'b0;
        begin
            int unsigned guard;
            guard = 0;
            while (!busy_o && guard < 8) begin @(posedge clk); guard++; end
            guard = 0;
            while (busy_o && guard < (TLMM_LANES + 8)) begin @(posedge clk); guard++; end
        end
        @(posedge clk);
        chk(write_cnt == TLMM_LANES,
            $sformatf("%s: expected %0d writes, saw %0d", tag, TLMM_LANES, write_cnt));
        for (int ln = 0; ln < int'(TLMM_LANES); ln++) begin
            automatic logic [WR_DATA_W-1:0] got;
            got = uram[base + URAM_ADDR_W'(ln)];
            chk(got[TLMM_ACC_W-1:0] === exp_acc[ln],
                $sformatf("%s: lane %0d data mismatch got=%0h exp=%0h",
                          tag, ln, got[TLMM_ACC_W-1:0], exp_acc[ln]));
        end
    endtask
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
        for (int ln = 0; ln < int'(TLMM_LANES); ln++)
            exp_acc[ln] = tlmm_acc_t'(ln + 1);
        run_op(URAM_ADDR_W'(0), "ramp");
        for (int ln = 0; ln < int'(TLMM_LANES); ln++)
            exp_acc[ln] = tlmm_acc_t'(32'h0BAD_F00D);
        run_op(URAM_ADDR_W'(64), "const");
        for (int ln = 0; ln < int'(TLMM_LANES); ln++)
            exp_acc[ln] = -tlmm_acc_t'((ln * 7) + 3);
        run_op(URAM_ADDR_W'(128), "negative");
        for (int ln = 0; ln < int'(TLMM_LANES); ln++) begin
            case (ln % 4)
                0: exp_acc[ln] = tlmm_acc_t'(32'h7FFF_FFFF);
                1: exp_acc[ln] = tlmm_acc_t'(32'h8000_0000);
                2: exp_acc[ln] = '0;
                default: exp_acc[ln] = -tlmm_acc_t'(ln * 12345);
            endcase
        end
        run_op(URAM_ADDR_W'(200), "extremes");
        for (int op = 0; op < 16; op++) begin
            automatic logic [URAM_ADDR_W-1:0] rb;
            rb = URAM_ADDR_W'($urandom_range(0, URAM_DEPTH_TB - TLMM_LANES - 1));
            for (int ln = 0; ln < int'(TLMM_LANES); ln++)
                exp_acc[ln] = tlmm_acc_t'($urandom);
            run_op(rb, $sformatf("rand[%0d]", op));
        end
        repeat (4) @(posedge clk);
        if (n_errors == 0 && !addr_order_bad)
            $display("tb_sparse_out_collector: PASS  (%0d / %0d checks)", n_checks, n_checks);
        else
            $display("tb_sparse_out_collector: FAIL  (%0d errors / %0d checks, addr_order_bad=%0b)",
                     n_errors, n_checks, addr_order_bad);
        $finish;
    end
    initial begin : watchdog
        #(CLK_PERIOD * 5000);
        $fatal(1, "tb_sparse_out_collector: watchdog timeout");
    end

endmodule : tb_sparse_out_collector

`default_nettype wire
