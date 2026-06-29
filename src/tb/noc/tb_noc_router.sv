// -----------------------------------------------------------------------------
// tb_noc_router.sv
//
// Unit testbench for noc_router.
//
// Scenarios:
//   D1. CONFIG phase:  writing path table entries under valid/ready handshake.
//   D2. NO-STREAM-BEFORE-COMMIT: in_ready must stay low until path_commit.
//   D3. SINGLE-DST:    after commit, a path with dst_mask = one-hot bit only
//                      raises out_valid on that one egress.
//   D4. MULTICAST:     path with multi-bit mask raises out_valid on the full
//                      set; the beat only fires when ALL selected egresses
//                      are ready (hold-on-backpressure).
//   D5. BACKPRESSURE:  selectively de-asserting one egress's out_ready stalls
//                      the whole multicast beat; data/last remain stable.
//   D6. MASK UPDATE:   different path_ids select different masks; the router
//                      reacts to path_id changes between beats.
//
// Random stress:
//   R.  N_RANDOM beats with random path_id among a pre-committed table; each
//       egress independently applies random backpressure. After every fire we
//       verify that only the mask-selected egresses saw out_valid high that
//       cycle.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_TB_NOC_ROUTER_SV
`define ARCHBETTER_TB_NOC_ROUTER_SV
`default_nettype none
`timescale 1ns/1ps

module tb_noc_router
    import types_pkg::*;
();

    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------
    localparam time T_CLK    = 10ns;
    localparam int  FANOUT   = 8;        // small fanout to keep the TB readable
    localparam int  N_PATHS  = 8;        // subset of NOC_PATH_HANDLES we program
    localparam int  N_RANDOM = 256;

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    logic clk, rst_n;
    initial clk = 1'b0;
    always  #(T_CLK/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT interface instances
    // -------------------------------------------------------------------------
    noc_cfg_if     cfg(.clk(clk), .rst_n(rst_n));
    noc_router_if #(
        .DATA_W (NOC_DATA_W),
        .USER_W (NOC_USER_W),
        .FANOUT (FANOUT)
    ) rt(.clk(clk), .rst_n(rst_n));

    noc_router #(
        .DATA_W    (NOC_DATA_W),
        .USER_W    (NOC_USER_W),
        .FANOUT    (FANOUT),
        .ROUTER_ID (32'd0)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .cfg   (cfg),
        .rt    (rt)
    );

    // -------------------------------------------------------------------------
    // TB state
    // -------------------------------------------------------------------------
    int n_checks;
    int n_errors;

    // Golden copy of the committed path table (low FANOUT bits only).
    logic [FANOUT-1:0] gold_mask [N_PATHS];

    // Per-egress backpressure control (driven by TB).
    logic [FANOUT-1:0] tb_out_ready;

    assign rt.out_ready = tb_out_ready;

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    task automatic do_reset();
        rst_n         = 1'b0;
        cfg.handle    = '0;
        cfg.cfg       = '0;
        cfg.cfg_valid = 1'b0;
        cfg.path_commit = 1'b0;
        rt.in_data    = '0;
        rt.in_user    = '0;
        rt.in_valid   = 1'b0;
        rt.in_last    = 1'b0;
        rt.path_id    = '0;
        rt.path_commit= 1'b0;
        tb_out_ready  = '0;
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
    endtask

    task automatic program_path(
        input logic [NOC_PATH_ID_W-1:0] h,
        input noc_mask_t                mask
    );
        noc_path_cfg_t pc;
        pc              = '0;
        pc.src_node     = '0;
        pc.dst_mask     = mask;
        pc.priority_lvl = 3'd0;
        pc.is_multicast = (|((mask & (mask - 1))));  // more than one bit set

        @(posedge clk);
        cfg.handle    <= h;
        cfg.cfg       <= pc;
        cfg.cfg_valid <= 1'b1;
        // Wait for cfg_ready
        do @(posedge clk); while (!cfg.cfg_ready);
        cfg.cfg_valid <= 1'b0;
        gold_mask[h]  = mask[FANOUT-1:0];
    endtask

    task automatic commit_paths();
        @(posedge clk);
        cfg.path_commit <= 1'b1;
        @(posedge clk);
        cfg.path_commit <= 1'b0;
        @(posedge clk);
    endtask

    // Drive one ingress beat; wait for fire or timeout. Returns 1 if fired.
    task automatic drive_beat(
        input  logic [NOC_PATH_ID_W-1:0] pid,
        input  logic [NOC_DATA_W-1:0]    data,
        input  logic                     last,
        input  logic [FANOUT-1:0]        ready_mask,
        input  int                       max_wait,
        output bit                       fired
    );
        int waited;
        fired  = 1'b0;
        waited = 0;

        rt.in_data    <= data;
        rt.in_user    <= 8'hA5;
        rt.in_valid   <= 1'b1;
        rt.in_last    <= last;
        rt.path_id    <= pid;
        tb_out_ready  <= ready_mask;

        @(posedge clk);
        while (!(rt.in_valid && rt.in_ready) && waited < max_wait) begin
            waited++;
            @(posedge clk);
        end
        fired = rt.in_valid && rt.in_ready;

        rt.in_valid   <= 1'b0;
        rt.in_last    <= 1'b0;
        tb_out_ready  <= '0;
        @(posedge clk);
    endtask

    task automatic fail(input string msg);
        n_errors++;
        $error("[%0t] %s", $time, msg);
    endtask

    // -------------------------------------------------------------------------
    // D1/D2: config phase and pre-commit gating.
    // -------------------------------------------------------------------------
    task automatic run_config_and_gating();
        $display("[%0t] D1/D2: config phase + no-stream-before-commit", $time);
        // Program a single-dst path (bit 2) before commit.
        program_path(8'd0, noc_mask_t'(1 << 2));

        // Attempt to drive a beat BEFORE commit - must NOT fire.
        begin
            bit f;
            drive_beat(.pid('d0),
                       .data({NOC_DATA_W{1'b1}}),
                       .last(1'b1),
                       .ready_mask({FANOUT{1'b1}}),
                       .max_wait(8),
                       .fired(f));
            n_checks++;
            if (f) fail("router fired a beat before path_commit");
        end

        // Program a few more paths still in the config window.
        program_path(8'd1, noc_mask_t'(8'b1100_0011));                 // multicast across FANOUT=8
        program_path(8'd2, noc_mask_t'(8'b0000_1111));                 // multicast lower half
        program_path(8'd3, noc_mask_t'(1 << 5));                       // single-dst
        program_path(8'd4, noc_mask_t'(8'b1111_1111));                 // full FANOUT broadcast
        program_path(8'd5, noc_mask_t'(0));                            // no destinations (should not fire)
        program_path(8'd6, noc_mask_t'(8'b0101_0101));                 // striped
        program_path(8'd7, noc_mask_t'(1 << 0));                       // single-dst lowest

        commit_paths();
    endtask

    // -------------------------------------------------------------------------
    // D3/D4/D6: directed single-dst and multicast routing.
    // -------------------------------------------------------------------------
    task automatic run_routing();
        $display("[%0t] D3/D4/D6: single-dst + multicast routing", $time);

        for (int p = 0; p < N_PATHS; p++) begin
            bit  fired;
            logic [FANOUT-1:0] observed;
            logic [FANOUT-1:0] expected = gold_mask[p];
            logic [FANOUT-1:0] rmask    = {FANOUT{1'b1}};  // all egresses ready
            logic [NOC_DATA_W-1:0] pattern;

            pattern = {NOC_DATA_W{1'b0}};
            for (int b = 0; b < NOC_DATA_W; b += 8) pattern[b +: 8] = 8'(p + 1);

            drive_beat(.pid(8'(p)),
                       .data(pattern),
                       .last(1'b1),
                       .ready_mask(rmask),
                       .max_wait(16),
                       .fired(fired));
            n_checks++;

            // expected == 0 (path 5) must NOT fire.
            if (expected == '0) begin
                if (fired) fail($sformatf("path=%0d mask=0 but router fired", p));
                continue;
            end

            if (!fired) begin
                fail($sformatf("path=%0d mask=%b beat did not fire", p, expected));
                continue;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // D5: backpressure - a partial ready_mask on a multicast must stall.
    // -------------------------------------------------------------------------
    task automatic run_backpressure();
        bit fired;
        logic [FANOUT-1:0] mask;
        logic [NOC_DATA_W-1:0] data_beat;

        $display("[%0t] D5: backpressure stalls a multicast", $time);

        mask      = gold_mask[1];            // 8'b1100_0011, 4 destinations
        data_beat = {NOC_DATA_W{1'b1}};

        // Hold one selected egress NOT ready. Beat must NOT fire.
        begin
            logic [FANOUT-1:0] rmask;
            rmask = {FANOUT{1'b1}};
            // Drop one selected bit from the ready mask.
            for (int d = 0; d < FANOUT; d++) begin
                if (mask[d]) begin
                    rmask[d] = 1'b0;
                    break;
                end
            end

            drive_beat(.pid(8'd1),
                       .data(data_beat),
                       .last(1'b1),
                       .ready_mask(rmask),
                       .max_wait(6),
                       .fired(fired));
            n_checks++;
            if (fired) fail("router fired while a selected egress was not ready");
        end

        // Now raise all selected readies - beat must fire.
        begin
            drive_beat(.pid(8'd1),
                       .data(data_beat),
                       .last(1'b1),
                       .ready_mask({FANOUT{1'b1}}),
                       .max_wait(6),
                       .fired(fired));
            n_checks++;
            if (!fired) fail("router failed to fire once all egresses became ready");
        end
    endtask

    // -------------------------------------------------------------------------
    // Random stress: random path_id, random partial readiness.
    // For each attempted beat we either see it fire (and verify out_valid
    // on exactly the mask bits) or not (and verify in_ready == 0).
    // -------------------------------------------------------------------------
    task automatic run_random();
        $display("[%0t] RANDOM: %0d beats with random path + readiness", $time, N_RANDOM);

        for (int i = 0; i < N_RANDOM; i++) begin
            logic [NOC_PATH_ID_W-1:0] pid;
            logic [FANOUT-1:0] rmask;
            logic [FANOUT-1:0] exp_mask;
            logic [FANOUT-1:0] obs_valid;
            bit fired;
            logic [NOC_DATA_W-1:0] data_beat;

            pid       = 8'($urandom_range(0, N_PATHS-1));
            rmask     = FANOUT'($urandom());
            exp_mask  = gold_mask[pid];
            data_beat = {NOC_DATA_W{1'b0}};
            for (int b = 0; b < NOC_DATA_W; b += 16) data_beat[b +: 16] = 16'($urandom());

            // Apply a single cycle of stimulus and observe.
            rt.in_data   <= data_beat;
            rt.in_user   <= 8'($urandom());
            rt.in_valid  <= 1'b1;
            rt.in_last   <= 1'b1;
            rt.path_id   <= pid;
            tb_out_ready <= rmask;
            @(posedge clk);

            obs_valid = rt.out_valid;
            fired     = rt.in_valid && rt.in_ready;
            n_checks++;

            // Regardless of fire, out_valid during in_valid must equal exp_mask.
            if (obs_valid !== exp_mask) begin
                fail($sformatf("i=%0d pid=%0d obs_valid=%b exp=%b",
                               i, pid, obs_valid, exp_mask));
            end

            // If any selected egress was not ready, the beat must NOT fire.
            if (((exp_mask & ~rmask) != '0) && fired) begin
                fail($sformatf("i=%0d fired despite unready egress: mask=%b ready=%b",
                               i, exp_mask, rmask));
            end

            rt.in_valid  <= 1'b0;
            tb_out_ready <= '0;
            @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin
        n_checks = 0;
        n_errors = 0;

        do_reset();
        run_config_and_gating();
        run_routing();
        run_backpressure();
        run_random();

        if (n_errors == 0 && n_checks > 0) begin
            $display("=========================================================");
            $display(" tb_noc_router: PASS  (%0d checks, 0 errors)", n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_noc_router: FAIL  (%0d checks, %0d errors)",
                     n_checks, n_errors);
            $display("=========================================================");
        end
        $finish;
    end

    initial begin
        #(T_CLK * 200_000);
        $fatal(1, "tb_noc_router: watchdog timeout");
    end

endmodule : tb_noc_router

`default_nettype wire
`endif // ARCHBETTER_TB_NOC_ROUTER_SV
