// -----------------------------------------------------------------------------
// tb_csd_wide_fill.sv  (R6.8b.2)
//
// Unit test for csd_wide_fill: the narrow-72b -> wide-288b fill assembler for
// the WIDE dense ping-pong. Drives a contiguous native fill stream and checks
// that every WIDE-th beat emits one wide write whose leaves carry the WIDE
// preceding natives in order, at wide_addr = native_addr / WIDE.
//
// Coverage:
//   CASE 1: contiguous stream, no gaps (8 wide words from base 0).
//   CASE 2: stream with idle gaps between beats (models background fill pacing);
//           grouping must be unaffected (adapter acts only on in_wr_en).
//   CASE 3: a second WIDE-aligned descriptor at a different base (restart leaf 0).
//   Negative coverage of the mid-group-jump assertion is left to inspection (the
//   workload is aligned by construction); driving a deliberate gap would trip the
//   a_no_midgroup_jump $error, which is the intended fail-loud behaviour.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_csd_wide_fill;
    import types_pkg::*;

    localparam int unsigned WIDE   = DENSE_PP_URAM_WIDE;   // 4
    localparam int unsigned LEAF_W = URAM_WIDTH_BITS;      // 72
    localparam int unsigned ADDR_W = URAM_ADDR_W;          // 12
    localparam int unsigned WIDE_W = WIDE * LEAF_W;        // 288

    logic clk;
    logic rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    logic              in_wr_en;
    logic [ADDR_W-1:0] in_wr_addr;
    logic [LEAF_W-1:0] in_wr_data;

    logic              out_wr_en;
    logic [ADDR_W-1:0] out_wr_addr;
    logic [WIDE_W-1:0] out_wr_data;

    csd_wide_fill #(
        .WIDE  (WIDE),
        .LEAF_W(LEAF_W),
        .ADDR_W(ADDR_W)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_wr_en   (in_wr_en),
        .in_wr_addr (in_wr_addr),
        .in_wr_data (in_wr_data),
        .out_wr_en  (out_wr_en),
        .out_wr_addr(out_wr_addr),
        .out_wr_data(out_wr_data)
    );

    // Scoreboard: native address -> driven data.
    logic [LEAF_W-1:0] nat [int];

    int unsigned checks = 0;
    int unsigned errors = 0;
    int unsigned wide_writes = 0;

    // Build a distinct 72b word per (addr) so a swapped/dropped leaf mismatches.
    function automatic logic [LEAF_W-1:0] mk(input int unsigned a);
        logic [LEAF_W-1:0] v;
        v = '0;
        for (int unsigned b = 0; b < LEAF_W/8; b++) begin
            v[b*8 +: 8] = 8'(a*3 + b*5 + 8'h21);
        end
        return v;
    endfunction

    // Compare a fired wide write against the scoreboard.
    task automatic check_wide();
        logic [WIDE_W-1:0] exp;
        int unsigned w;
        exp = '0;
        w   = out_wr_addr;
        for (int unsigned l = 0; l < WIDE; l++) begin
            exp[l*LEAF_W +: LEAF_W] = nat[w*WIDE + l];
        end
        checks++;
        wide_writes++;
        if (out_wr_data !== exp) begin
            errors++;
            $display("[%0t] WIDE-DATA MISMATCH waddr=0x%0h\n  exp=0x%0h\n  got=0x%0h",
                     $time, w, exp, out_wr_data);
        end
    endtask

    // Drive one native beat (in_wr_en stays high across consecutive beat() calls).
    task automatic beat(input logic [ADDR_W-1:0] a, input logic [LEAF_W-1:0] d);
        @(negedge clk);
        in_wr_en   = 1'b1;
        in_wr_addr = a;
        in_wr_data = d;
        nat[a]     = d;
        #1;  // let combinational outputs settle
        // out_wr_en must fire exactly on the last leaf of a group.
        checks++;
        if (out_wr_en !== ((a[$clog2(WIDE)-1:0]) == ($clog2(WIDE))'(WIDE-1))) begin
            errors++;
            $display("[%0t] out_wr_en=%0b unexpected for addr=0x%0h (leaf=%0d)",
                     $time, out_wr_en, a, a[$clog2(WIDE)-1:0]);
        end
        if (out_wr_en) begin
            if (out_wr_addr !== ADDR_W'(a >> $clog2(WIDE))) begin
                errors++;
                $display("[%0t] WIDE-ADDR MISMATCH exp=0x%0h got=0x%0h",
                         $time, ADDR_W'(a >> $clog2(WIDE)), out_wr_addr);
            end
            check_wide();
        end
    endtask

    task automatic idle(input int unsigned n);
        @(negedge clk);
        in_wr_en = 1'b0;
        repeat (n) @(posedge clk);
    endtask

    initial begin : main
        in_wr_en   = 1'b0;
        in_wr_addr = '0;
        in_wr_data = '0;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ------------------------------------------------------------------
        $display("[%0t] CASE 1: contiguous stream, 8 wide words from base 0", $time);
        for (int unsigned a = 0; a < 8*WIDE; a++) begin
            beat(ADDR_W'(a), mk(a));
        end
        idle(2);

        // ------------------------------------------------------------------
        $display("[%0t] CASE 2: gapped stream (idle between every beat)", $time);
        // Base 64 (WIDE-aligned). One idle cycle between each native beat.
        for (int unsigned a = 64; a < 64 + 6*WIDE; a++) begin
            beat(ADDR_W'(a), mk(a));
            idle(1);
        end
        idle(2);

        // ------------------------------------------------------------------
        $display("[%0t] CASE 3: second aligned descriptor at base 512", $time);
        for (int unsigned a = 512; a < 512 + 4*WIDE; a++) begin
            beat(ADDR_W'(a), mk(a));
        end
        idle(2);

        // ------------------------------------------------------------------
        // Expected wide writes: 8 (case1) + 6 (case2) + 4 (case3) = 18.
        if (wide_writes != 18) begin
            errors++;
            $display("[%0t] wide_writes=%0d, expected 18", $time, wide_writes);
        end

        $display("=========================================================");
        if (errors == 0) begin
            $display(" tb_csd_wide_fill: PASS  (%0d checks, %0d wide writes, 0 errors)",
                     checks, wide_writes);
        end else begin
            $display(" tb_csd_wide_fill: FAIL  (%0d checks, %0d errors)", checks, errors);
        end
        $display("=========================================================");
        $finish;
    end

    initial begin : watchdog
        #(200_000);
        $fatal(1, "tb_csd_wide_fill: watchdog expired");
    end

endmodule : tb_csd_wide_fill

`default_nettype wire
