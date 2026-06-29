// -----------------------------------------------------------------------------
// tb_uram_bank.sv
//
// Directed + random testbench for uram_bank.sv. Covers:
//   STAGE 0: reset & quiescence (rd_valid stays low, no spurious pulses)
//   STAGE 1: directed write then read, verifying the 2-cycle read latency
//   STAGE 2: back-to-back writes, back-to-back reads (pipelined)
//   STAGE 3: random 256 writes then 256 reads vs a golden model
//   STAGE 4: interleaved write/read with no same-address collision
//
// A golden model lives in an `logic [DATA_W-1:0] gold [URAM_DEPTH]` array that
// mirrors every accepted write; reads are checked on the rd_valid cycle
// against gold[rd_addr_q2] where rd_addr_q2 is the read address from two
// cycles earlier (matching the DUT's 2-cycle pipeline).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_uram_bank;
    import types_pkg::*;

    // -------------------------------------------------------------------------
    // DUT parameters (defaults lifted from types_pkg).
    // -------------------------------------------------------------------------
    localparam int unsigned DATA_W = URAM_WIDTH_BITS; // 72
    localparam int unsigned DEPTH  = URAM_DEPTH;      // 4096
    localparam int unsigned ADDR_W = URAM_ADDR_W;     // 12

    localparam int unsigned N_RANDOM = 256;

    // -------------------------------------------------------------------------
    // Clock + reset.
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // -------------------------------------------------------------------------
    // DUT I/O.
    // -------------------------------------------------------------------------
    logic              wr_en;
    logic [ADDR_W-1:0] wr_addr;
    logic [DATA_W-1:0] wr_data;

    logic              rd_en;
    logic [ADDR_W-1:0] rd_addr;
    logic              rd_valid;
    logic [DATA_W-1:0] rd_data;

    uram_bank #(
        .DATA_W(DATA_W),
        .DEPTH (DEPTH),
        .ADDR_W(ADDR_W)
    ) dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .wr_en  (wr_en),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .rd_en  (rd_en),
        .rd_addr(rd_addr),
        .rd_valid(rd_valid),
        .rd_data(rd_data)
    );

    // -------------------------------------------------------------------------
    // Golden model + error / check counters.
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] gold [DEPTH];
    logic              gold_written [DEPTH];

    // Variable-declaration initializers so that `checks` / `errors` have
    // exactly one procedural driver (the always_ff block below); Vivado's
    // VRFC-10-2921 fires if the `initial` block also writes them.
    int unsigned checks    = 0;
    int unsigned errors    = 0;
    int unsigned tb_errors = 0;  // only ever written from the initial block

    // Shadow the last two read addresses so we can compare rd_data against the
    // golden entry for the read that issued 2 cycles ago. MUST use NBA so the
    // two-stage pipeline doesn't collapse (blocking in source order would make
    // rd_addr_q2 track the current cycle's rd_addr).
    logic [ADDR_W-1:0] rd_addr_q1, rd_addr_q2;
    logic              rd_en_q1,   rd_en_q2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_addr_q1 <= '0;
            rd_addr_q2 <= '0;
            rd_en_q1   <= 1'b0;
            rd_en_q2   <= 1'b0;
        end else begin
            rd_addr_q1 <= rd_addr;
            rd_addr_q2 <= rd_addr_q1;
            rd_en_q1   <= rd_en;
            rd_en_q2   <= rd_en_q1;
        end
    end

    // On every rd_valid, compare against gold[rd_addr_q2]. The check only
    // applies when the address was written at some prior point; unwritten
    // URAM entries are init-zero after config, but to keep the TB independent
    // of init state we only score addresses we touched ourselves.
    always_ff @(posedge clk) begin
        if (rst_n && rd_valid && gold_written[rd_addr_q2]) begin
            checks <= checks + 1;
            if (rd_data !== gold[rd_addr_q2]) begin
                errors <= errors + 1;
                $display("[%0t] MISMATCH addr=0x%0h expected=0x%0h got=0x%0h",
                         $time, rd_addr_q2, gold[rd_addr_q2], rd_data);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Test tasks.
    // -------------------------------------------------------------------------
    task automatic drive_idle();
        wr_en   <= 1'b0;
        wr_addr <= '0;
        wr_data <= '0;
        rd_en   <= 1'b0;
        rd_addr <= '0;
    endtask

    task automatic do_write(input logic [ADDR_W-1:0] a,
                             input logic [DATA_W-1:0] d);
        @(negedge clk);
        wr_en   = 1'b1;
        wr_addr = a;
        wr_data = d;
        rd_en   = 1'b0;
        rd_addr = '0;
        gold[a]         = d;
        gold_written[a] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        wr_en   = 1'b0;
    endtask

    task automatic do_read(input logic [ADDR_W-1:0] a);
        @(negedge clk);
        wr_en   = 1'b0;
        rd_en   = 1'b1;
        rd_addr = a;
        @(posedge clk);
        @(negedge clk);
        rd_en   = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Main test sequence.
    // -------------------------------------------------------------------------
    initial begin : main
        for (int i = 0; i < DEPTH; i++) begin
            gold[i]         = '0;
            gold_written[i] = 1'b0;
        end

        // Reset.
        rst_n = 1'b0;
        drive_idle();
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("[%0t] STAGE 0: reset quiescent", $time);
        if (rd_valid !== 1'b0) begin
            tb_errors++;
            $display("[%0t] STAGE 0 FAIL: rd_valid=%0b after reset", $time, rd_valid);
        end

        // -----------------------------------------------------------------
        $display("[%0t] STAGE 1: directed write then read (2-cycle latency)", $time);
        do_write(12'h010, 72'hAA_5555_5555_5555_5555);
        do_read (12'h010);
        // After do_read, rd_en is high for one posedge; rd_valid lands 2 cycles
        // later. Wait them out so the rd_valid-driven check fires.
        @(posedge clk); @(posedge clk); @(posedge clk);

        // -----------------------------------------------------------------
        $display("[%0t] STAGE 2: back-to-back writes + back-to-back reads", $time);
        @(negedge clk);
        wr_en = 1'b1;
        for (int i = 0; i < 8; i++) begin
            wr_addr = 12'(12'h100 + i);
            wr_data = {56'hC0FFEE_CAFEBABE_1234, 16'(i)};
            gold[wr_addr]         = wr_data;
            gold_written[wr_addr] = 1'b1;
            @(posedge clk);
            @(negedge clk);
        end
        wr_en = 1'b0;
        @(posedge clk);

        @(negedge clk);
        rd_en = 1'b1;
        for (int i = 0; i < 8; i++) begin
            rd_addr = 12'(12'h100 + i);
            @(posedge clk);
            @(negedge clk);
        end
        rd_en = 1'b0;
        repeat (3) @(posedge clk);

        // -----------------------------------------------------------------
        $display("[%0t] STAGE 3: random %0d writes then %0d reads",
                 $time, N_RANDOM, N_RANDOM);
        begin : stage3
            logic [ADDR_W-1:0] addrs [N_RANDOM];
            for (int i = 0; i < N_RANDOM; i++) begin
                addrs[i] = ADDR_W'($urandom_range(0, DEPTH-1));
            end

            for (int i = 0; i < N_RANDOM; i++) begin
                logic [DATA_W-1:0] d;
                d = {$urandom(), $urandom(), $urandom()};
                do_write(addrs[i], d[DATA_W-1:0]);
            end

            for (int i = 0; i < N_RANDOM; i++) begin
                do_read(addrs[i]);
            end
            repeat (3) @(posedge clk);
        end

        // -----------------------------------------------------------------
        $display("[%0t] STAGE 4: interleaved write/read, distinct addresses", $time);
        begin : stage4
            for (int i = 0; i < 64; i++) begin
                logic [ADDR_W-1:0] wa, ra;
                logic [DATA_W-1:0] d;
                wa = ADDR_W'(12'h200 + i);
                ra = ADDR_W'(12'h100 + (i % 8)); // previously written block
                d  = {$urandom(), $urandom(), $urandom()};

                @(negedge clk);
                wr_en   = 1'b1;
                wr_addr = wa;
                wr_data = d;
                rd_en   = 1'b1;
                rd_addr = ra;
                gold[wa]         = d;
                gold_written[wa] = 1'b1;
                @(posedge clk);
                @(negedge clk);
                wr_en   = 1'b0;
                rd_en   = 1'b0;
            end
            repeat (3) @(posedge clk);
        end

        // -----------------------------------------------------------------
        $display("=========================================================");
        if (errors == 0 && tb_errors == 0) begin
            $display(" tb_uram_bank: PASS  (%0d checks, 0 errors)", checks);
        end else begin
            $display(" tb_uram_bank: FAIL  (%0d checks, %0d compare errors, %0d tb errors)",
                     checks, errors, tb_errors);
        end
        $display("=========================================================");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Watchdog: this TB should finish in well under 200 us.
    // -------------------------------------------------------------------------
    initial begin : watchdog
        #(200_000);
        $fatal(1, "tb_uram_bank: watchdog expired");
    end

endmodule : tb_uram_bank

`default_nettype wire
