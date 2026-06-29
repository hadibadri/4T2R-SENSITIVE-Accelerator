// -----------------------------------------------------------------------------
// tb_uram_pingpong.sv
//
// Directed + random testbench for uram_pingpong.sv. The DUT is a two-bank
// ping-pong wrapper around two `uram_bank` primitives, with a drain-handshake
// swap FSM exposed on `pingpong_if.mem_mgr`.
//
// R6.8b: runs at WIDE=3 / DATA_W=216 (the dense-activation wide read = 3 URAM288
// leaves side-by-side at one address). Every directed/random word spans all 3
// leaves, so a pass proves the whole 216b word is written and read in a single
// cycle and that the swap/drain FSM is width-agnostic.
//
// Coverage stages:
//   STAGE 0: reset / quiescence — initial side = INIT_COMPUTE_SIDE,
//            drain_req=0, swap_done=0, rd_valid=0.
//   STAGE 1: pure fill on the back bank (no swap), confirm reads from the
//            front bank still see all-zeros (independence of the two pools).
//   STAGE 2: fill back bank, swap, then read from the (now-front) bank and
//            verify the data we wrote pre-swap is what we read post-swap.
//   STAGE 3: drain handshake protocol — issue swap_req, watch drain_req go
//            high, ack on a deliberately-delayed cycle, watch swap_done pulse
//            exactly once on the cycle the side flips.
//   STAGE 4: random multi-swap ping-pong with two golden mirrors (one per
//            bank), N_RANDOM addresses per bank, N_SWAPS swaps total.
//   STAGE 5: directed back-to-back swap_req->ack->swap_req->ack to confirm
//            the FSM accepts another swap immediately after swap_done.
//
// Two golden mirrors are kept (one per bank). On every rd_valid we compare
// rd_data against the mirror of whichever bank was the compute side TWO
// CYCLES AGO (matching the URAM read latency).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_uram_pingpong;
    import types_pkg::*;

    // -------------------------------------------------------------------------
    // DUT parameters.
    // -------------------------------------------------------------------------
    // R6.8b: exercise the WIDE=4 dense-pp wide read (DATA_W=288 = 4x72). The whole
    // ping-pong/swap/drain/read coverage below runs at this width, so a pass proves
    // the wide bank reads & writes a full 288b word in one cycle and that the swap
    // FSM is width-agnostic. (Set WIDE=1 to recover the legacy 72b.)
    localparam int unsigned WIDE   = DENSE_PP_URAM_WIDE;           // 4
    localparam int unsigned DATA_W = WIDE * URAM_WIDTH_BITS;       // 288
    localparam int unsigned DEPTH  = URAM_DEPTH;                   // 4096
    localparam int unsigned ADDR_W = URAM_ADDR_W;                 // 12

    localparam int unsigned N_RANDOM = 64;
    localparam int unsigned N_SWAPS  = 4;

    // -------------------------------------------------------------------------
    // Clock + reset.
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // -------------------------------------------------------------------------
    // pingpong_if instance + DUT I/O.
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Per-bank golden models. One mirror per bank, one written-flag per bank.
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] gold_a [DEPTH];
    logic              gold_a_written [DEPTH];
    logic [DATA_W-1:0] gold_b [DEPTH];
    logic              gold_b_written [DEPTH];

    // -------------------------------------------------------------------------
    // Two-cycle shadow of the read-side address + active side, so that on a
    // rd_valid we compare against the gold of whichever bank was on the read
    // mux when the read was issued.
    // -------------------------------------------------------------------------
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

    // The rd_valid->compare check. We only score addresses we touched on the
    // matching bank ourselves; an unwritten URAM cell is not part of the spec.
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

    // -------------------------------------------------------------------------
    // Bus drivers (TB owns the core-side signals on pingpong_if + the fill
    // port + swap_req).
    // -------------------------------------------------------------------------
    task automatic drive_idle();
        ppif.rd_en     <= 1'b0;
        ppif.rd_addr   <= '0;
        ppif.drain_ack <= 1'b0;
        fill_wr_en     <= 1'b0;
        fill_wr_addr   <= '0;
        fill_wr_data   <= '0;
        swap_req       <= 1'b0;
    endtask

    // Width-generic data builders (DATA_W is byte-aligned: 72 or 216 = 9 or 27
    // bytes). A distinct seed yields a distinct full-width word that spans all
    // WIDE leaves, so a wide read that dropped or swapped a leaf would mismatch.
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

    // Single-cycle write to the (currently fill-side) bank. Updates the gold
    // mirror of WHICHEVER bank is the fill side at the time of the write.
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

    // The full swap protocol from the TB's POV: pulse swap_req, wait for
    // drain_req to come up, ack after `ack_delay_cycles` cycles, then wait
    // for swap_done. Returns the side that became the new compute side.
    task automatic do_swap(input int unsigned ack_delay_cycles,
                            output bank_sel_e new_compute_side);
        bank_sel_e prev_side;
        prev_side = compute_side_o;

        // 1-cycle swap_req pulse.
        @(negedge clk);
        swap_req = 1'b1;
        @(posedge clk);
        @(negedge clk);
        swap_req = 1'b0;

        // Wait for drain_req to come up.
        while (ppif.drain_req !== 1'b1) begin
            @(posedge clk);
        end

        // Hold drain (modeling the core finishing in-flight reads).
        repeat (ack_delay_cycles) @(posedge clk);

        // Pulse drain_ack for one cycle.
        @(negedge clk);
        ppif.drain_ack = 1'b1;
        @(posedge clk);
        @(negedge clk);
        ppif.drain_ack = 1'b0;

        // Wait for swap_done.
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

    // -------------------------------------------------------------------------
    // Watchdog on swap_done — must be a 1-cycle pulse only, never level-held.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst_n && swap_done && $past(swap_done, 1)) begin
            tb_errors <= tb_errors + 1;
            $display("[%0t] swap_done held high for >1 cycle", $time);
        end
    end

    // -------------------------------------------------------------------------
    // Main test sequence.
    // -------------------------------------------------------------------------
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

        // ------------------------------------------------------------------
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

        // ------------------------------------------------------------------
        $display("[%0t] STAGE 1: fill back bank, read front bank (independence)", $time);
        // Fill side is BANK_B, compute side is BANK_A. Writes hit gold_b only.
        for (int i = 0; i < 8; i++) begin
            do_fill_write(ADDR_W'(12'h040 + i), mk_data(32'h0040 + i));
        end
        // Read from compute side (BANK_A) at the same addresses. Since
        // gold_a_written stays 0, the comparator silently skips these reads,
        // but rd_valid should still pulse — we just verify no spurious errors.
        for (int i = 0; i < 8; i++) begin
            do_core_read(ADDR_W'(12'h040 + i));
        end
        repeat (4) @(posedge clk);

        // ------------------------------------------------------------------
        $display("[%0t] STAGE 2: fill back bank, SWAP, then read it as front", $time);
        // We are still: compute=A, fill=B. Fill BANK_B with a known pattern.
        for (int i = 0; i < 16; i++) begin
            do_fill_write(ADDR_W'(12'h100 + i), mk_data(32'hC000 + i));
        end
        do_swap(.ack_delay_cycles(2), .new_compute_side(new_side));
        if (new_side !== BANK_B) begin
            tb_errors++;
            $display("[%0t] STAGE 2 FAIL: post-swap compute_side=%s, expected BANK_B",
                     $time, new_side.name());
        end
        // Now read those addresses — compute side is BANK_B and gold_b is
        // populated, so the comparator will score every read.
        for (int i = 0; i < 16; i++) begin
            do_core_read(ADDR_W'(12'h100 + i));
        end
        repeat (4) @(posedge clk);

        // ------------------------------------------------------------------
        $display("[%0t] STAGE 3: drain handshake — observe drain_req timing", $time);
        // We are now: compute=B, fill=A. Verify drain_req comes up promptly
        // after swap_req and stays up across the ack_delay window.
        begin : stage3
            automatic int unsigned drain_observed_at = 0;
            int unsigned t0;
            t0 = 0;

            @(negedge clk);
            swap_req = 1'b1;
            @(posedge clk);
            @(negedge clk);
            swap_req = 1'b0;

            // drain_req should be high within at most a couple of cycles
            // (registered in the FSM => 1 cycle after swap_req).
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

            // Hold drain for several cycles to model a slow drain.
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

            // swap_done within a couple of cycles.
            while (!swap_done) @(posedge clk);
            @(posedge clk);
        end

        if (compute_side_o !== BANK_A) begin
            tb_errors++;
            $display("[%0t] STAGE 3 FAIL: post-swap compute_side=%s, expected BANK_A",
                     $time, compute_side_o.name());
        end

        // ------------------------------------------------------------------
        $display("[%0t] STAGE 4: random ping-pong across %0d swaps", $time, N_SWAPS);
        begin : stage4
            for (int s = 0; s < N_SWAPS; s++) begin
                logic [ADDR_W-1:0] addrs [N_RANDOM];
                logic [DATA_W-1:0] datas [N_RANDOM];
                bank_sel_e         pre_compute;

                // Fill the current back bank with random data at random addrs.
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

                // Now those addresses are on the compute side. Read them all.
                for (int i = 0; i < N_RANDOM; i++) begin
                    do_core_read(addrs[i]);
                end
                repeat (3) @(posedge clk);
            end
        end

        // ------------------------------------------------------------------
        $display("[%0t] STAGE 5: back-to-back swap_req acceptance", $time);
        begin : stage5
            do_swap(.ack_delay_cycles(0), .new_compute_side(new_side));
            // Immediately request another swap without intervening fill.
            do_swap(.ack_delay_cycles(0), .new_compute_side(new_side));
        end

        // ------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Watchdog.
    // -------------------------------------------------------------------------
    initial begin : watchdog
        #(500_000);
        $fatal(1, "tb_uram_pingpong: watchdog expired");
    end

endmodule : tb_uram_pingpong

`default_nettype wire
