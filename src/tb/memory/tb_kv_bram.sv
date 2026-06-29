// -----------------------------------------------------------------------------
// tb_kv_bram.sv
//
// Directed + random testbench for kv_bram.sv. Wires the DUT to a kv_access_if
// instance whose master signals are driven by the TB.
//
// Stages:
//   STAGE 0: reset / quiescence (rd_valid stays low)
//   STAGE 1: directed write then read, verify the 1-cycle read latency
//   STAGE 2: pipelined back-to-back writes, then back-to-back reads
//   STAGE 3: simultaneous write + read at DISTINCT addresses on the same
//            cycle (the simple-dual-port discipline)
//   STAGE 4: random N writes then N reads vs a golden array
//   STAGE 5: interleaved random writes + reads (different addresses), the
//            stress test for the dual-port behavior
//
// The golden mirror is an `[KV_DATA_W-1:0]` array sized to KV_DEPTH; we mark
// addresses we touched so the comparator only scores "known" cells.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_kv_bram;
    import types_pkg::*;

    // -------------------------------------------------------------------------
    // Params.
    // -------------------------------------------------------------------------
    localparam int unsigned DATA_W = KV_DATA_W;   // 144
    localparam int unsigned DEPTH  = KV_DEPTH;    // 16384
    localparam int unsigned ADDR_W = KV_ADDR_W;   // 14

    localparam int unsigned N_RANDOM = 256;

    // -------------------------------------------------------------------------
    // Clock + reset.
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // -------------------------------------------------------------------------
    // Interface + DUT.
    // -------------------------------------------------------------------------
    kv_access_if kvif (.clk(clk), .rst_n(rst_n));

    kv_bram #(
        .DATA_W(DATA_W),
        .DEPTH (DEPTH),
        .ADDR_W(ADDR_W)
    ) dut (
        .clk  (clk),
        .rst_n(rst_n),
        .kv   (kvif.slave)
    );

    // -------------------------------------------------------------------------
    // Golden mirror.
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] gold [DEPTH];
    logic              gold_written [DEPTH];

    int unsigned checks    = 0;
    int unsigned errors    = 0;
    int unsigned tb_errors = 0;

    // 2-cycle shadow of rd_addr so the comparator can look up gold for the
    // address that issued the read TWO cycles earlier (BRAM latch + OREG; see
    // kv_bram latency contract).
    logic [ADDR_W-1:0] rd_addr_q1, rd_addr_q2;
    logic              rd_en_q1,   rd_en_q2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_addr_q1 <= '0;
            rd_addr_q2 <= '0;
            rd_en_q1   <= 1'b0;
            rd_en_q2   <= 1'b0;
        end else begin
            rd_addr_q1 <= kvif.rd_addr;
            rd_addr_q2 <= rd_addr_q1;
            rd_en_q1   <= kvif.rd_en;
            rd_en_q2   <= rd_en_q1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && kvif.rd_valid && gold_written[rd_addr_q2]) begin
            checks <= checks + 1;
            if (kvif.rd_data !== gold[rd_addr_q2]) begin
                errors <= errors + 1;
                $display("[%0t] MISMATCH addr=0x%0h exp=0x%0h got=0x%0h",
                         $time, rd_addr_q2, gold[rd_addr_q2], kvif.rd_data);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Drivers.
    // -------------------------------------------------------------------------
    task automatic drive_idle();
        kvif.wr_en   <= 1'b0;
        kvif.wr_addr <= '0;
        kvif.wr_data <= '0;
        kvif.rd_en   <= 1'b0;
        kvif.rd_addr <= '0;
    endtask

    task automatic do_write(input logic [ADDR_W-1:0] a,
                             input logic [DATA_W-1:0] d);
        @(negedge clk);
        kvif.wr_en   = 1'b1;
        kvif.wr_addr = a;
        kvif.wr_data = d;
        kvif.rd_en   = 1'b0;
        gold[a]         = d;
        gold_written[a] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        kvif.wr_en   = 1'b0;
    endtask

    task automatic do_read(input logic [ADDR_W-1:0] a);
        @(negedge clk);
        kvif.rd_en   = 1'b1;
        kvif.rd_addr = a;
        kvif.wr_en   = 1'b0;
        @(posedge clk);
        @(negedge clk);
        kvif.rd_en   = 1'b0;
    endtask

    // Same-cycle write + read at DISTINCT addresses (legal SDP discipline).
    task automatic do_write_and_read(input logic [ADDR_W-1:0] wa,
                                      input logic [DATA_W-1:0] wd,
                                      input logic [ADDR_W-1:0] ra);
        @(negedge clk);
        kvif.wr_en   = 1'b1;
        kvif.wr_addr = wa;
        kvif.wr_data = wd;
        kvif.rd_en   = 1'b1;
        kvif.rd_addr = ra;
        gold[wa]         = wd;
        gold_written[wa] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        kvif.wr_en   = 1'b0;
        kvif.rd_en   = 1'b0;
    endtask

    function automatic logic [DATA_W-1:0] rand_data();
        logic [DATA_W-1:0] d;
        d = {$urandom(), $urandom(), $urandom(), $urandom(), $urandom()};
        return d;
    endfunction

    // -------------------------------------------------------------------------
    // Main test sequence.
    // -------------------------------------------------------------------------
    initial begin : main
        for (int i = 0; i < DEPTH; i++) begin
            gold[i]         = '0;
            gold_written[i] = 1'b0;
        end

        rst_n = 1'b0;
        drive_idle();
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ------------------------------------------------------------------
        $display("[%0t] STAGE 0: reset quiescent", $time);
        if (kvif.rd_valid !== 1'b0) begin
            tb_errors++;
            $display("[%0t] STAGE 0 FAIL: rd_valid=%0b after reset", $time, kvif.rd_valid);
        end

        // ------------------------------------------------------------------
        $display("[%0t] STAGE 1: directed write then read (2-cycle latency)", $time);
        do_write(14'h0010, {16'hFEED, 128'hAAAA_5555_AAAA_5555_AAAA_5555_AAAA_5555});
        do_read (14'h0010);
        repeat (3) @(posedge clk); // let rd_valid land (2-cyc) + comparator fire

        // ------------------------------------------------------------------
        $display("[%0t] STAGE 2: pipelined back-to-back writes + reads", $time);
        @(negedge clk);
        kvif.wr_en = 1'b1;
        for (int i = 0; i < 16; i++) begin
            kvif.wr_addr = ADDR_W'(14'h0100 + i);
            kvif.wr_data = {16'(i), 128'hC0FFEE_DECAF_BAD_F00D_C0FFEE_DECAF_F00D};
            gold[kvif.wr_addr]         = kvif.wr_data;
            gold_written[kvif.wr_addr] = 1'b1;
            @(posedge clk);
            @(negedge clk);
        end
        kvif.wr_en = 1'b0;
        @(posedge clk);

        @(negedge clk);
        kvif.rd_en = 1'b1;
        for (int i = 0; i < 16; i++) begin
            kvif.rd_addr = ADDR_W'(14'h0100 + i);
            @(posedge clk);
            @(negedge clk);
        end
        kvif.rd_en = 1'b0;
        repeat (3) @(posedge clk);

        // ------------------------------------------------------------------
        $display("[%0t] STAGE 3: simultaneous write+read, distinct addresses", $time);
        for (int i = 0; i < 16; i++) begin
            do_write_and_read(.wa(ADDR_W'(14'h0200 + i)),
                              .wd(rand_data()),
                              .ra(ADDR_W'(14'h0100 + (i % 16))));   // pre-written
        end
        repeat (3) @(posedge clk);

        // ------------------------------------------------------------------
        $display("[%0t] STAGE 4: random %0d writes then %0d reads", $time, N_RANDOM, N_RANDOM);
        begin : stage4
            logic [ADDR_W-1:0] addrs [N_RANDOM];
            for (int i = 0; i < N_RANDOM; i++) begin
                addrs[i] = ADDR_W'($urandom_range(0, DEPTH-1));
            end

            for (int i = 0; i < N_RANDOM; i++) begin
                do_write(addrs[i], rand_data());
            end

            for (int i = 0; i < N_RANDOM; i++) begin
                do_read(addrs[i]);
            end
            repeat (3) @(posedge clk);
        end

        // ------------------------------------------------------------------
        $display("[%0t] STAGE 5: interleaved random write+read, distinct addrs", $time);
        begin : stage5
            for (int i = 0; i < 128; i++) begin
                logic [ADDR_W-1:0] wa, ra;
                wa = ADDR_W'($urandom_range(0, DEPTH-1));
                do begin
                    ra = ADDR_W'($urandom_range(0, DEPTH-1));
                end while (ra == wa);   // never same-cycle same-address (SDP rule)
                do_write_and_read(.wa(wa), .wd(rand_data()), .ra(ra));
            end
            repeat (3) @(posedge clk);
        end

        // ------------------------------------------------------------------
        $display("=========================================================");
        if (errors == 0 && tb_errors == 0) begin
            $display(" tb_kv_bram: PASS  (%0d checks, 0 errors)", checks);
        end else begin
            $display(" tb_kv_bram: FAIL  (%0d checks, %0d compare errors, %0d tb errors)",
                     checks, errors, tb_errors);
        end
        $display("=========================================================");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Watchdog.
    // -------------------------------------------------------------------------
    initial begin : watchdog
        #(500_000);
        $fatal(1, "tb_kv_bram: watchdog expired");
    end

endmodule : tb_kv_bram

`default_nettype wire
