// -----------------------------------------------------------------------------
// tb_noc_fabric.sv
//
// End-to-end testbench for noc_fabric.
//
// Topology under test:
//   N_SOURCES = 2, NOC_NODES = 64 destination nodes.
//   Source 0 path: broadcasts to destinations {0, 1, 2, 3}.
//   Source 1 path: broadcasts to destinations {16, 17, 18, 19}.
//   Non-overlapping masks -> the circuit-switched single-driver invariant is
//   respected by construction.
//
// Phases:
//   P1. Program each source's path 0 mask.
//   P2. Commit each source independently (two single-cycle pulses).
//   P3. Stream beats on each source with distinguishable payload patterns.
//       After each fire, immediately sample every destination's bus and push
//       to the per-destination act_q.
//   P4. Apply backpressure on one destination (stall source 0) and verify:
//         - that stalled source holds s_ready low across several cycles,
//         - once d_ready is released, the beat fires exactly once.
//   P5. Verify at EOT that for every destination, the captured sequence of
//       beats equals the expected one.
//
// Driver discipline:
//   All TB writes to source-side signals are blocking, so deassert of valid
//   takes effect at the same time step as the fire sample - no double-fire.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_TB_NOC_FABRIC_SV
`define ARCHBETTER_TB_NOC_FABRIC_SV
`default_nettype none
`timescale 1ns/1ps

module tb_noc_fabric
    import types_pkg::*;
();

    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------
    localparam time T_CLK     = 10ns;
    localparam int  N_SOURCES = 2;
    localparam int  N_BEATS   = 8;
    localparam int  DATA_W    = NOC_DATA_W;
    localparam int  USER_W    = NOC_USER_W;

    localparam noc_mask_t MASK_S0 = noc_mask_t'(64'h0000_0000_0000_000F); // {0,1,2,3}
    localparam noc_mask_t MASK_S1 = noc_mask_t'(64'h0000_0000_000F_0000); // {16..19}

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    logic clk, rst_n;
    initial clk = 1'b0;
    always  #(T_CLK/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Interfaces
    // -------------------------------------------------------------------------
    noc_cfg_if cfg [N_SOURCES] (.clk(clk), .rst_n(rst_n));

    strm_if #(.DATA_W(DATA_W), .USER_W(USER_W))
        src [N_SOURCES] (.clk(clk), .rst_n(rst_n));
    strm_if #(.DATA_W(DATA_W), .USER_W(USER_W))
        dst [NOC_NODES]  (.clk(clk), .rst_n(rst_n));

    logic [NOC_PATH_ID_W-1:0] path_id [N_SOURCES];

    noc_fabric #(
        .N_SOURCES (N_SOURCES),
        .DATA_W    (DATA_W),
        .USER_W    (USER_W)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .path_id (path_id),
        .cfg     (cfg),
        .src     (src),
        .dst     (dst)
    );

    // -------------------------------------------------------------------------
    // Packed mirrors (interface arrays can only be indexed by constants in
    // procedural code under XSim).
    // -------------------------------------------------------------------------
    logic [N_SOURCES-1:0][DATA_W-1:0] s_data;
    logic [N_SOURCES-1:0][USER_W-1:0] s_user;
    logic [N_SOURCES-1:0]             s_valid;
    logic [N_SOURCES-1:0]             s_last;
    logic [N_SOURCES-1:0]             s_ready_obs;

    for (genvar S = 0; S < N_SOURCES; S++) begin : gen_src_bind
        assign src[S].data  = s_data [S];
        assign src[S].user  = s_user [S];
        assign src[S].valid = s_valid[S];
        assign src[S].last  = s_last [S];
        assign s_ready_obs[S] = src[S].ready;
    end

    logic [NOC_NODES-1:0][DATA_W-1:0] d_data;
    logic [NOC_NODES-1:0][USER_W-1:0] d_user;
    logic [NOC_NODES-1:0]             d_valid;
    logic [NOC_NODES-1:0]             d_last;
    logic [NOC_NODES-1:0]             d_ready;

    for (genvar D = 0; D < NOC_NODES; D++) begin : gen_dst_bind
        assign d_data [D]  = dst[D].data;
        assign d_user [D]  = dst[D].user;
        assign d_valid[D]  = dst[D].valid;
        assign d_last [D]  = dst[D].last;
        assign dst[D].ready = d_ready[D];
    end

    // -------------------------------------------------------------------------
    // Scoreboard: per-destination expected + actual queues, populated from
    // the TB procedural code (no always_ff to avoid races with the driver).
    // -------------------------------------------------------------------------
    typedef logic [DATA_W-1:0] data_word_t;

    data_word_t exp_q [NOC_NODES][$];
    data_word_t act_q [NOC_NODES][$];

    int n_errors;
    int n_checks;

    // -------------------------------------------------------------------------
    // Config helpers. cfg[] and dst[] indices must be constant, so case-unroll.
    // -------------------------------------------------------------------------
    task automatic cfg_reset();
        cfg[0].handle       = '0;
        cfg[0].cfg          = '0;
        cfg[0].cfg_valid    = 1'b0;
        cfg[0].path_commit  = 1'b0;
        cfg[1].handle       = '0;
        cfg[1].cfg          = '0;
        cfg[1].cfg_valid    = 1'b0;
        cfg[1].path_commit  = 1'b0;
    endtask

    task automatic program_source_path(
        input int unsigned                 s,
        input logic [NOC_PATH_ID_W-1:0]    h,
        input noc_mask_t                   mask
    );
        noc_path_cfg_t pc;
        pc              = '0;
        pc.src_node     = s[NOC_NODE_ID_W-1:0];
        pc.dst_mask     = mask;
        pc.is_multicast = 1'b1;

        @(posedge clk);
        case (s)
            0: begin
                cfg[0].handle    = h;
                cfg[0].cfg       = pc;
                cfg[0].cfg_valid = 1'b1;
                do @(posedge clk); while (!cfg[0].cfg_ready);
                cfg[0].cfg_valid = 1'b0;
            end
            1: begin
                cfg[1].handle    = h;
                cfg[1].cfg       = pc;
                cfg[1].cfg_valid = 1'b1;
                do @(posedge clk); while (!cfg[1].cfg_ready);
                cfg[1].cfg_valid = 1'b0;
            end
            default: $fatal(1, "program_source_path: unsupported source %0d", s);
        endcase
    endtask

    task automatic commit_source(input int unsigned s);
        @(posedge clk);
        case (s)
            0: begin
                cfg[0].path_commit = 1'b1;
                @(posedge clk);
                cfg[0].path_commit = 1'b0;
            end
            1: begin
                cfg[1].path_commit = 1'b1;
                @(posedge clk);
                cfg[1].path_commit = 1'b0;
            end
            default: $fatal(1, "commit_source: unsupported source %0d", s);
        endcase
        @(posedge clk);
    endtask

    // Sample every destination that is valid+ready THIS cycle and push its
    // payload onto act_q. Called by the TB from the same process that fires
    // the beat, so it sees the post-NBA, pre-deassert state.
    task automatic sample_destinations();
        for (int d = 0; d < NOC_NODES; d++) begin
            if (d_valid[d] && d_ready[d]) begin
                act_q[d].push_back(d_data[d]);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Drive one beat on one source, waiting for fire, then immediately sample
    // all destinations and deassert valid via blocking writes (same time step,
    // so no double-fire on the following edge).
    // -------------------------------------------------------------------------
    task automatic stream_one_beat(
        input int unsigned       s,
        input data_word_t        payload,
        input logic              last,
        input noc_mask_t         exp_mask
    );
        int waited;
        waited = 0;

        s_data [s] = payload;
        s_user [s] = 8'hCC;
        s_valid[s] = 1'b1;
        s_last [s] = last;

        do begin
            @(posedge clk);
            waited++;
            if (waited > 64)
                $fatal(1, "stream_one_beat: source %0d stalled > 64 cycles", s);
        end while (!s_ready_obs[s]);

        // Fire occurred at this edge. Sample destinations NOW.
        sample_destinations();

        // Record expectation.
        for (int d = 0; d < NOC_NODES; d++) begin
            if (exp_mask[d]) exp_q[d].push_back(payload);
        end

        // Immediately drop valid so no second beat fires at next edge.
        s_valid[s] = 1'b0;
        s_last [s] = 1'b0;
    endtask

    task automatic check_scoreboard();
        for (int d = 0; d < NOC_NODES; d++) begin
            if (exp_q[d].size() != act_q[d].size()) begin
                n_errors++;
                $error("dst[%0d] count mismatch: exp=%0d act=%0d",
                       d, exp_q[d].size(), act_q[d].size());
            end else begin
                for (int i = 0; i < exp_q[d].size(); i++) begin
                    n_checks++;
                    if (exp_q[d][i] !== act_q[d][i]) begin
                        n_errors++;
                        $error("dst[%0d] beat %0d: exp=%h act=%h",
                               d, i, exp_q[d][i], act_q[d][i]);
                    end
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin
        rst_n      = 1'b0;
        n_errors   = 0;
        n_checks   = 0;
        path_id[0] = '0;
        path_id[1] = '0;
        s_data     = '0;
        s_user     = '0;
        s_valid    = '0;
        s_last     = '0;
        d_ready    = {NOC_NODES{1'b1}};
        cfg_reset();
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // -- P1: program --
        $display("[%0t] P1: program paths", $time);
        program_source_path(0, '0, MASK_S0);
        program_source_path(1, '0, MASK_S1);

        // -- P2: commit --
        $display("[%0t] P2: commit", $time);
        commit_source(0);
        commit_source(1);

        // -- P3: streaming --
        $display("[%0t] P3: stream %0d beats each, no backpressure", $time, N_BEATS);
        for (int b = 0; b < N_BEATS; b++) begin
            data_word_t p0, p1;
            p0 = '0; p1 = '0;
            for (int k = 0; k < DATA_W; k += 16) begin
                p0[k +: 16] = 16'(16'hA000 + b);
                p1[k +: 16] = 16'(16'hB000 + b);
            end
            stream_one_beat(0, p0, (b == N_BEATS-1), MASK_S0);
            stream_one_beat(1, p1, (b == N_BEATS-1), MASK_S1);
        end

        // -- P4: backpressure dst[0] during a source-0 beat --
        $display("[%0t] P4: backpressure dst[0]", $time);
        begin
            data_word_t p;
            int waited;
            p = '0;
            for (int k = 0; k < DATA_W; k += 16) p[k +: 16] = 16'hDEAD;

            d_ready[0] = 1'b0;           // stall dst[0]
            s_data [0] = p;
            s_user [0] = 8'hCC;
            s_valid[0] = 1'b1;
            s_last [0] = 1'b1;

            // Hold for several cycles; s_ready_obs[0] must stay low.
            repeat (4) begin
                @(posedge clk);
                n_checks++;
                if (s_ready_obs[0]) begin
                    n_errors++;
                    $error("source 0 accepted a beat while dst[0] was stalled");
                end
            end

            d_ready[0] = 1'b1;           // release
            waited = 0;
            do begin
                @(posedge clk);
                waited++;
                if (waited > 8)
                    $fatal(1, "P4: source 0 failed to fire after release");
            end while (!s_ready_obs[0]);

            // Fire. Sample.
            sample_destinations();
            for (int d = 0; d < NOC_NODES; d++) begin
                if (MASK_S0[d]) exp_q[d].push_back(p);
            end

            s_valid[0] = 1'b0;
            s_last [0] = 1'b0;
            n_checks++;   // successful stall+release counted
        end

        repeat (8) @(posedge clk);

        // -- P5: scoreboard --
        check_scoreboard();

        if (n_errors == 0 && n_checks > 0) begin
            $display("=========================================================");
            $display(" tb_noc_fabric: PASS  (%0d checks, 0 errors)", n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_noc_fabric: FAIL  (%0d checks, %0d errors)",
                     n_checks, n_errors);
            $display("=========================================================");
        end
        $finish;
    end

    initial begin
        #(T_CLK * 500_000);
        $fatal(1, "tb_noc_fabric: watchdog timeout");
    end

endmodule : tb_noc_fabric

`default_nettype wire
`endif // ARCHBETTER_TB_NOC_FABRIC_SV
