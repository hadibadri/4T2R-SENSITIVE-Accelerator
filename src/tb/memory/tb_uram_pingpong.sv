
`timescale 1ns/1ps
`default_nettype none

module tb_uram_pingpong;
    import types_pkg::*;
    localparam int unsigned WIDE   = DENSE_PP_URAM_WIDE;
    localparam int unsigned DATA_W = WIDE * URAM_WIDTH_BITS;
    localparam int unsigned DEPTH  = URAM_DEPTH;
    localparam int unsigned ADDR_W = URAM_ADDR_W;

    localparam int unsigned N_RANDOM = 64;
    localparam int unsigned N_SWAPS  = 4;
    logic clk;
    logic rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;
    pingpong_if #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) ppif (.clk(clk), .rst_n(rst_n));

    logic              fill_wr_en;
    logic [ADDR_W-1:0] fill_wr_addr;
    logic [DATA_W-1:0] fill_wr_data;

    logic              swap_req;
    logic              swap_done;
    bank_sel_e         compute_side_o;
    bank_sel_e         fill_side_o;

    uram_pingpong #(
        .DATA_W(DATA_W),
        .DEPTH (DEPTH),
        .ADDR_W(ADDR_W),
        .WIDE  (WIDE),
        .INIT_COMPUTE_SIDE(BANK_A)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .core           (ppif.mem_mgr),
        .fill_wr_en     (fill_wr_en),
        .fill_wr_addr   (fill_wr_addr),
        .fill_wr_data   (fill_wr_data),
        .swap_req       (swap_req),
        .swap_done      (swap_done),
        .compute_side_o (compute_side_o),
        .fill_side_o    (fill_side_o)
    );
    logic [DATA_W-1:0] gold_a [DEPTH];
    logic              gold_a_written [DEPTH];
    logic [DATA_W-1:0] gold_b [DEPTH];
    logic              gold_b_written [DEPTH];
    logic [ADDR_W-1:0] rd_addr_q1, rd_addr_q2;
    logic              rd_en_q1,   rd_en_q2;
    bank_sel_e         rd_side_q1, rd_side_q2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_addr_q1 <= '0;
            rd_addr_q2 <= '0;
            rd_en_q1   <= 1'b0;
            rd_en_q2   <= 1'b0;
            rd_side_q1 <= BANK_A;
            rd_side_q2 <= BANK_A;
        end else begin
            rd_addr_q1 <= ppif.rd_addr;
            rd_addr_q2 <= rd_addr_q1;
            rd_en_q1   <= ppif.rd_en;
            rd_en_q2   <= rd_en_q1;
            rd_side_q1 <= compute_side_o;
            rd_side_q2 <= rd_side_q1;
        end
    end

    int unsigned checks    = 0;
    int unsigned errors    = 0;
    int unsigned tb_errors = 0;
    always_ff @(posedge clk) begin
        if (rst_n && ppif.rd_valid) begin
            unique case (rd_side_q2)
                BANK_A: begin
                    if (gold_a_written[rd_addr_q2]) begin
                        checks <= checks + 1;
                        if (ppif.rd_data !== gold_a[rd_addr_q2]) begin
                            errors <= errors + 1;
                            $display("[%0t] MISMATCH bank=A addr=0x%0h exp=0x%0h got=0x%0h",
                                     $time, rd_addr_q2, gold_a[rd_addr_q2], ppif.rd_data);
                        end
                    end
                end
                BANK_B: begin
                    if (gold_b_written[rd_addr_q2]) begin
                        checks <= checks + 1;
                        if (ppif.rd_data !== gold_b[rd_addr_q2]) begin
                            errors <= errors + 1;
                            $display("[%0t] MISMATCH bank=B addr=0x%0h exp=0x%0h got=0x%0h",
                                     $time, rd_addr_q2, gold_b[rd_addr_q2], ppif.rd_data);
                        end
                    end
                end
                default: ;
            endcase
        end
    end
    task automatic drive_idle();
        ppif.rd_en     <= 1'b0;
        ppif.rd_addr   <= '0;
        ppif.drain_ack <= 1'b0;
        fill_wr_en     <= 1'b0;
        fill_wr_addr   <= '0;
        fill_wr_data   <= '0;
        swap_req       <= 1'b0;
    endtask
    function automatic logic [DATA_W-1:0] mk_data(input int unsigned seed);
        logic [DATA_W-1:0] v;
        v = '0;
        for (int unsigned b = 0; b < DATA_W/8; b++) begin
            v[b*8 +: 8] = 8'(seed + b*7 + 8'h11);
        end
        return v;
    endfunction

    function automatic logic [DATA_W-1:0] mk_rand();
        logic [DATA_W-1:0] v;
        v = '0;
        for (int unsigned b = 0; b < DATA_W/8; b++) begin
            v[b*8 +: 8] = 8'($urandom());
        end
        return v;
    endfunction
    task automatic do_fill_write(input logic [ADDR_W-1:0] a,
                                  input logic [DATA_W-1:0] d);
        @(negedge clk);
        fill_wr_en   = 1'b1;
        fill_wr_addr = a;
        fill_wr_data = d;
        unique case (fill_side_o)
            BANK_A: begin gold_a[a] = d; gold_a_written[a] = 1'b1; end
            BANK_B: begin gold_b[a] = d; gold_b_written[a] = 1'b1; end
            default: ;
        endcase
        @(posedge clk);
        @(negedge clk);
        fill_wr_en   = 1'b0;
    endtask

    task automatic do_core_read(input logic [ADDR_W-1:0] a);
        @(negedge clk);
        ppif.rd_en   = 1'b1;
        ppif.rd_addr = a;
        @(posedge clk);
        @(negedge clk);
        ppif.rd_en   = 1'b0;
    endtask
    task automatic do_swap(input int unsigned ack_delay_cycles,
                            output bank_sel_e new_compute_side);
        bank_sel_e prev_side;
        prev_side = compute_side_o;
        @(negedge clk);
        swap_req = 1'b1;
        @(posedge clk);
        @(negedge clk);
        swap_req = 1'b0;
        while (ppif.drain_req !== 1'b1) begin
            @(posedge clk);
        end
        repeat (ack_delay_cycles) @(posedge clk);
        @(negedge clk);
        ppif.drain_ack = 1'b1;
        @(posedge clk);
        @(negedge clk);
        ppif.drain_ack = 1'b0;
        while (swap_done !== 1'b1) begin
            @(posedge clk);
        end
        @(posedge clk);

        new_compute_side = compute_side_o;

        if (new_compute_side === prev_side) begin
            tb_errors++;
            $display("[%0t] do_swap FAIL: side did not flip (prev=%s now=%s)",
                     $time, prev_side.name(), new_compute_side.name());
        end
    endtask
    always_ff @(posedge clk) begin
        if (rst_n && swap_done && $past(swap_done, 1)) begin
            tb_errors <= tb_errors + 1;
            $display("[%0t] swap_done held high for >1 cycle", $time);
        end
    end
    initial begin : main
        bank_sel_e new_side;

        for (int i = 0; i < DEPTH; i++) begin
            gold_a[i] = '0; gold_a_written[i] = 1'b0;
            gold_b[i] = '0; gold_b_written[i] = 1'b0;
        end

        rst_n = 1'b0;
        drive_idle();
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        $display("[%0t] STAGE 0: reset quiescent", $time);
        if (compute_side_o !== BANK_A) begin
            tb_errors++;
            $display("[%0t] STAGE 0 FAIL: initial compute_side=%s, expected BANK_A",
                     $time, compute_side_o.name());
        end
        if (fill_side_o !== BANK_B) begin
            tb_errors++;
            $display("[%0t] STAGE 0 FAIL: initial fill_side=%s, expected BANK_B",
                     $time, fill_side_o.name());
        end
        if (ppif.drain_req !== 1'b0 || swap_done !== 1'b0 || ppif.rd_valid !== 1'b0) begin
            tb_errors++;
            $display("[%0t] STAGE 0 FAIL: drain_req=%0b swap_done=%0b rd_valid=%0b",
                     $time, ppif.drain_req, swap_done, ppif.rd_valid);
        end
        $display("[%0t] STAGE 1: fill back bank, read front bank (independence)", $time);
        for (int i = 0; i < 8; i++) begin
            do_fill_write(ADDR_W'(12'h040 + i), mk_data(32'h0040 + i));
        end
        for (int i = 0; i < 8; i++) begin
            do_core_read(ADDR_W'(12'h040 + i));
        end
        repeat (4) @(posedge clk);
        $display("[%0t] STAGE 2: fill back bank, SWAP, then read it as front", $time);
        for (int i = 0; i < 16; i++) begin
            do_fill_write(ADDR_W'(12'h100 + i), mk_data(32'hC000 + i));
        end
        do_swap(.ack_delay_cycles(2), .new_compute_side(new_side));
        if (new_side !== BANK_B) begin
            tb_errors++;
            $display("[%0t] STAGE 2 FAIL: post-swap compute_side=%s, expected BANK_B",
                     $time, new_side.name());
        end
        for (int i = 0; i < 16; i++) begin
            do_core_read(ADDR_W'(12'h100 + i));
        end
        repeat (4) @(posedge clk);
        $display("[%0t] STAGE 3: drain handshake — observe drain_req timing", $time);
        begin : stage3
            automatic int unsigned drain_observed_at = 0;
            int unsigned t0;
            t0 = 0;

            @(negedge clk);
            swap_req = 1'b1;
            @(posedge clk);
            @(negedge clk);
            swap_req = 1'b0;
            for (int i = 0; i < 4; i++) begin
                if (ppif.drain_req) begin
                    drain_observed_at = i;
                    break;
                end
                @(posedge clk);
            end
            if (!ppif.drain_req) begin
                tb_errors++;
                $display("[%0t] STAGE 3 FAIL: drain_req never came up", $time);
            end else begin
                $display("[%0t] STAGE 3: drain_req asserted within %0d cycles of swap_req",
                         $time, drain_observed_at);
            end
            repeat (8) @(posedge clk);
            if (!ppif.drain_req) begin
                tb_errors++;
                $display("[%0t] STAGE 3 FAIL: drain_req dropped before ack", $time);
            end

            @(negedge clk);
            ppif.drain_ack = 1'b1;
            @(posedge clk);
            @(negedge clk);
            ppif.drain_ack = 1'b0;
            while (!swap_done) @(posedge clk);
            @(posedge clk);
        end

        if (compute_side_o !== BANK_A) begin
            tb_errors++;
            $display("[%0t] STAGE 3 FAIL: post-swap compute_side=%s, expected BANK_A",
                     $time, compute_side_o.name());
        end
        $display("[%0t] STAGE 4: random ping-pong across %0d swaps", $time, N_SWAPS);
        begin : stage4
            for (int s = 0; s < N_SWAPS; s++) begin
                logic [ADDR_W-1:0] addrs [N_RANDOM];
                logic [DATA_W-1:0] datas [N_RANDOM];
                bank_sel_e         pre_compute;
                for (int i = 0; i < N_RANDOM; i++) begin
                    addrs[i] = ADDR_W'($urandom_range(0, DEPTH-1));
                    datas[i] = mk_rand();
                    do_fill_write(addrs[i], datas[i]);
                end

                pre_compute = compute_side_o;
                do_swap(.ack_delay_cycles($urandom_range(0, 4)),
                        .new_compute_side(new_side));
                if (new_side === pre_compute) begin
                    tb_errors++;
                    $display("[%0t] STAGE 4 FAIL: side did not flip on swap %0d",
                             $time, s);
                end
                for (int i = 0; i < N_RANDOM; i++) begin
                    do_core_read(addrs[i]);
                end
                repeat (3) @(posedge clk);
            end
        end
        $display("[%0t] STAGE 5: back-to-back swap_req acceptance", $time);
        begin : stage5
            do_swap(.ack_delay_cycles(0), .new_compute_side(new_side));
            do_swap(.ack_delay_cycles(0), .new_compute_side(new_side));
        end
        $display("=========================================================");
        if (errors == 0 && tb_errors == 0) begin
            $display(" tb_uram_pingpong: PASS  (%0d checks, 0 errors)", checks);
        end else begin
            $display(" tb_uram_pingpong: FAIL  (%0d checks, %0d compare errors, %0d tb errors)",
                     checks, errors, tb_errors);
        end
        $display("=========================================================");
        $finish;
    end
    initial begin : watchdog
        #(500_000);
        $fatal(1, "tb_uram_pingpong: watchdog expired");
    end

endmodule : tb_uram_pingpong

`default_nettype wire
