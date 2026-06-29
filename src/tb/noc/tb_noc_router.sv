
`ifndef ARCHBETTER_TB_NOC_ROUTER_SV
`define ARCHBETTER_TB_NOC_ROUTER_SV
`default_nettype none
`timescale 1ns/1ps

module tb_noc_router
    import types_pkg::*;
();
    localparam time T_CLK    = 10ns;
    localparam int  FANOUT   = 8;
    localparam int  N_PATHS  = 8;
    localparam int  N_RANDOM = 256;
    logic clk, rst_n;
    initial clk = 1'b0;
    always  #(T_CLK/2) clk = ~clk;
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
    int n_checks;
    int n_errors;
    logic [FANOUT-1:0] gold_mask [N_PATHS];
    logic [FANOUT-1:0] tb_out_ready;

    assign rt.out_ready = tb_out_ready;
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
        pc.is_multicast = (|((mask & (mask - 1))));

        @(posedge clk);
        cfg.handle    <= h;
        cfg.cfg       <= pc;
        cfg.cfg_valid <= 1'b1;
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
    task automatic run_config_and_gating();
        $display("[%0t] D1/D2: config phase + no-stream-before-commit", $time);
        program_path(8'd0, noc_mask_t'(1 << 2));
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
        program_path(8'd1, noc_mask_t'(8'b1100_0011));
        program_path(8'd2, noc_mask_t'(8'b0000_1111));
        program_path(8'd3, noc_mask_t'(1 << 5));
        program_path(8'd4, noc_mask_t'(8'b1111_1111));
        program_path(8'd5, noc_mask_t'(0));
        program_path(8'd6, noc_mask_t'(8'b0101_0101));
        program_path(8'd7, noc_mask_t'(1 << 0));

        commit_paths();
    endtask
    task automatic run_routing();
        $display("[%0t] D3/D4/D6: single-dst + multicast routing", $time);

        for (int p = 0; p < N_PATHS; p++) begin
            bit  fired;
            logic [FANOUT-1:0] observed;
            logic [FANOUT-1:0] expected = gold_mask[p];
            logic [FANOUT-1:0] rmask    = {FANOUT{1'b1}};
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
    task automatic run_backpressure();
        bit fired;
        logic [FANOUT-1:0] mask;
        logic [NOC_DATA_W-1:0] data_beat;

        $display("[%0t] D5: backpressure stalls a multicast", $time);

        mask      = gold_mask[1];
        data_beat = {NOC_DATA_W{1'b1}};
        begin
            logic [FANOUT-1:0] rmask;
            rmask = {FANOUT{1'b1}};
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
            if (obs_valid !== exp_mask) begin
                fail($sformatf("i=%0d pid=%0d obs_valid=%b exp=%b",
                               i, pid, obs_valid, exp_mask));
            end
            if (((exp_mask & ~rmask) != '0) && fired) begin
                fail($sformatf("i=%0d fired despite unready egress: mask=%b ready=%b",
                               i, exp_mask, rmask));
            end

            rt.in_valid  <= 1'b0;
            tb_out_ready <= '0;
            @(posedge clk);
        end
    endtask
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
`endif
