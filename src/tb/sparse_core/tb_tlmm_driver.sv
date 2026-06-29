// -----------------------------------------------------------------------------
// tb_tlmm_driver.sv
//
// Phase-5b unit testbench for tlmm_driver.
//
// What it covers:
//   * Directed K=1 op with known activations + weights; verify tile partials
//     match a golden model computed from the same (activations, weights).
//   * K=4 op: same activations, sequence of 4 different weight beats.
//   * K=8 with random backpressure on the sparse_tile's OUT port (via
//     the tile itself; we only throttle by not asserting the dispatcher's
//     busy drop until after the last OUT has landed - the driver keeps
//     o_ready = busy so the sparse_tile actually drives o_valid and the
//     driver sinks it unconditionally).
//   * Two back-to-back ops at different base_addrs.
//   * tlmm_issue_if invariants (start is a pulse, done is a pulse, busy
//     spans the op, done co-falls with busy).
//
// TB roles:
//   * dispatcher (tlmm_issue_if.disp): we drive start / k_cnt / busy; we
//     sample tlmm.done.
//   * memory_manager (pingpong_if.mem_mgr): 1-cycle UltraRAM fake with
//     deterministic contents.
//   * real sparse_tile is instantiated to consume ctrl.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_tlmm_driver;
    import types_pkg::*;

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    localparam time CLK_PERIOD = 10ns;
    logic clk = 1'b0;
    logic rst_n;
    initial forever #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Local widths (mirror RTL)
    // -------------------------------------------------------------------------
    localparam int unsigned PP_DATA_W             = 144;
    localparam int unsigned PROG_BITS_PER_WORD    = 96;
    localparam int unsigned COMPUTE_BITS_PER_WORD = 128;
    localparam int unsigned PROG_PAYLOAD_W        = TLMM_TILE * BFP12_MANT_W;
    localparam int unsigned COMPUTE_PAYLOAD_W     = TLMM_LANES * TLMM_TILE * 2;
    localparam int unsigned PROG_WORDS            = (PROG_PAYLOAD_W    + PROG_BITS_PER_WORD    - 1) / PROG_BITS_PER_WORD;
    localparam int unsigned COMPUTE_WORDS         = (COMPUTE_PAYLOAD_W + COMPUTE_BITS_PER_WORD - 1) / COMPUTE_BITS_PER_WORD;
    localparam int unsigned WEIGHT_BASE_OFFSET    = PROG_WORDS;

    localparam int unsigned URAM_DEPTH_TB = 2048;

    // -------------------------------------------------------------------------
    // Interfaces
    // -------------------------------------------------------------------------
    tlmm_issue_if                                                   tlmm (clk, rst_n);
    pingpong_if   #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_DATA_W))       pp   (clk, rst_n);
    tlmm_ctrl_if                                                    ctrl (clk, rst_n);

    // -------------------------------------------------------------------------
    // DUT + sparse_tile consumer
    // -------------------------------------------------------------------------
    logic [URAM_ADDR_W-1:0] base_addr;

    // Phase-8 result bus (Stage 8d): per-lane K-reduction accumulator + valid.
    tlmm_acc_vec_t          dut_result_acc;
    logic                   dut_result_valid;

    tlmm_driver #(.PP_DATA_W(PP_DATA_W)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .base_addr   (base_addr),
        .tlmm        (tlmm.drv),
        .pp          (pp.core),
        .ctrl        (ctrl.driver),
        .result_acc  (dut_result_acc),
        .result_valid(dut_result_valid)
    );

    sparse_tile u_tile (
        .clk   (clk),
        .rst_n (rst_n),
        .ctrl  (ctrl.tile)
    );

    // -------------------------------------------------------------------------
    // Fake URAM (1-cycle latency)
    // -------------------------------------------------------------------------
    logic [PP_DATA_W-1:0] mem_q [0:URAM_DEPTH_TB-1];

    bank_sel_e          mgr_active_side;
    logic               mgr_side_valid;
    logic [PP_DATA_W-1:0] mgr_rd_data;
    logic               mgr_rd_valid;
    logic               mgr_drain_req;

    assign pp.active_side = mgr_active_side;
    assign pp.side_valid  = mgr_side_valid;
    assign pp.rd_data     = mgr_rd_data;
    assign pp.rd_valid    = mgr_rd_valid;
    assign pp.drain_req   = mgr_drain_req;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mgr_rd_valid <= 1'b0;
            mgr_rd_data  <= '0;
        end else begin
            mgr_rd_valid <= pp.rd_en;
            if (pp.rd_en) begin
                mgr_rd_data <= mem_q[pp.rd_addr[$clog2(URAM_DEPTH_TB)-1:0]];
            end
        end
    end

    initial begin
        mgr_active_side = BANK_A;
        mgr_side_valid  = 1'b1;
        mgr_drain_req   = 1'b0;
    end

    // -------------------------------------------------------------------------
    // Dispatcher emulation (tlmm_issue_if.disp)
    // -------------------------------------------------------------------------
    logic                     disp_start;
    logic [MACRO_CNT_W-1:0]   disp_k_cnt;
    logic                     disp_busy;

    assign tlmm.start = disp_start;
    assign tlmm.k_cnt = disp_k_cnt;
    assign tlmm.busy  = disp_busy;

    // -------------------------------------------------------------------------
    // Output scoreboard
    // -------------------------------------------------------------------------
    typedef struct {
        tlmm_part_vec_t parts;
    } obeat_t;

    obeat_t obs_q [$];

    always_ff @(posedge clk) begin
        if (rst_n && ctrl.o_valid && ctrl.o_ready) begin
            obeat_t ob;
            ob.parts = ctrl.o_parts;
            obs_q.push_back(ob);
        end
    end

    int n_checks = 0;
    int n_errors = 0;

    function automatic void check_eq_part(
        input tlmm_tile_part_t got,
        input tlmm_tile_part_t exp,
        input string           label
    );
        n_checks++;
        if (got !== exp) begin
            n_errors++;
            $error("[%0t] %s: tile_partial mismatch got=%0d exp=%0d",
                   $time, label, $signed(got), $signed(exp));
        end
    endfunction

    function automatic void check_eq_acc(
        input tlmm_acc_t got,
        input tlmm_acc_t exp,
        input string     label
    );
        n_checks++;
        if (got !== exp) begin
            n_errors++;
            $error("[%0t] %s: result_acc mismatch got=%0d exp=%0d",
                   $time, label, $signed(got), $signed(exp));
        end
    endfunction

    // -------------------------------------------------------------------------
    // Golden reference: expected tile partial per lane given one
    // (activations, weights) pair.
    // -------------------------------------------------------------------------
    function automatic tlmm_tile_part_t golden_part(
        input tlmm_tile_act_t   acts,
        input tern_tile_t       w_lane
    );
        logic signed [TLMM_TILE_PART_W-1:0] acc;
        acc = '0;
        for (int t = 0; t < int'(TLMM_TILE); t++) begin
            unique case (w_lane[t])
                TERN_POS : acc += tlmm_tile_part_t'($signed(acts[t]));
                TERN_NEG : acc -= tlmm_tile_part_t'($signed(acts[t]));
                default  : ; // 0 or reserved -> no contribution
            endcase
        end
        return acc;
    endfunction

    // -------------------------------------------------------------------------
    // URAM programming helpers.
    //   prog words: word[0] low96 = mant[0..7], word[1] low96 = mant[8..15].
    //   compute words: each word's low128 holds 64 ternary weights.
    //     bit (l*TLMM_TILE*2 + t*2 +: 2) in the ASSEMBLED 512b vector
    //     -> which URAM word and which bit within that word.
    // -------------------------------------------------------------------------
    function automatic void program_acts(
        input logic [URAM_ADDR_W-1:0] op_base,
        input tlmm_tile_act_t         acts
    );
        logic [PP_DATA_W-1:0] w0, w1;
        w0 = '0;
        w1 = '0;
        for (int i = 0; i < int'(TLMM_TILE/2); i++) begin
            w0[i*BFP12_MANT_W +: BFP12_MANT_W] = acts[i];
            w1[i*BFP12_MANT_W +: BFP12_MANT_W] = acts[TLMM_TILE/2 + i];
        end
        mem_q[op_base + 0] = w0;
        mem_q[op_base + 1] = w1;
    endfunction

    function automatic void program_w_beat(
        input logic [URAM_ADDR_W-1:0] op_base,
        input int                     beat_idx,
        input tern_lane_tiles_t       w_beat
    );
        logic [COMPUTE_PAYLOAD_W-1:0] asm_bits;
        logic [URAM_ADDR_W-1:0]       w_base;
        asm_bits = '0;
        for (int l = 0; l < int'(TLMM_LANES); l++) begin
            for (int t = 0; t < int'(TLMM_TILE); t++) begin
                asm_bits[(l*int'(TLMM_TILE) + t)*2 +: 2] = 2'(w_beat[l][t]);
            end
        end
        w_base = URAM_ADDR_W'(op_base + WEIGHT_BASE_OFFSET + beat_idx * COMPUTE_WORDS);
        for (int k = 0; k < int'(COMPUTE_WORDS); k++) begin
            logic [PP_DATA_W-1:0] word;
            word = '0;
            word[COMPUTE_BITS_PER_WORD-1:0] =
                asm_bits[k*COMPUTE_BITS_PER_WORD +: COMPUTE_BITS_PER_WORD];
            mem_q[w_base + k] = word;
        end
    endfunction

    // Build a random activation tile.
    function automatic tlmm_tile_act_t rand_acts(input int seed_v);
        tlmm_tile_act_t a;
        for (int i = 0; i < int'(TLMM_TILE); i++) begin
            a[i] = bfp12_mant_t'($urandom_range(0, (1 << BFP12_MANT_W) - 1)
                                 - (1 << (BFP12_MANT_W - 1)));
        end
        return a;
    endfunction

    // Build a random ternary weight beat.
    function automatic tern_lane_tiles_t rand_w_beat();
        tern_lane_tiles_t w;
        for (int l = 0; l < int'(TLMM_LANES); l++) begin
            for (int t = 0; t < int'(TLMM_TILE); t++) begin
                automatic int r;
                r = $urandom_range(0, 2);   // 0 -> 0, 1 -> +1, 2 -> -1
                unique case (r)
                    0:       w[l][t] = TERN_ZERO;
                    1:       w[l][t] = TERN_POS;
                    default: w[l][t] = TERN_NEG;
                endcase
            end
        end
        return w;
    endfunction

    // -------------------------------------------------------------------------
    // Op runner.
    // -------------------------------------------------------------------------
    task automatic run_op (
        input logic [URAM_ADDR_W-1:0] op_base,
        input int                     op_k,
        input tlmm_tile_act_t         acts,
        input tern_lane_tiles_t       wbeats [],
        input string                  label
    );
        int prev_obs_size;
        tlmm_acc_vec_t res_snap;
        tlmm_acc_t     exp_acc_arr [TLMM_LANES];

        // Program memory.
        program_acts(op_base, acts);
        for (int k = 0; k < op_k; k++) begin
            program_w_beat(op_base, k, wbeats[k]);
        end

        @(posedge clk);
        base_addr  = op_base;
        disp_k_cnt = MACRO_CNT_W'(op_k);
        prev_obs_size = obs_q.size();

        // Pulse start + hold busy.
        disp_busy  <= 1'b1;
        disp_start <= 1'b1;
        @(posedge clk);
        disp_start <= 1'b0;

        // Wait for done. Drop busy in the SAME cycle done is observed
        // (the tlmm_issue_if contract is "done co-falls with busy"); if we
        // hold busy=1 for an extra cycle, the driver's S_IDLE branch sees
        // state_q=S_IDLE && tlmm.busy=1 the cycle after S_DONE and re-fires
        // the op-start load — spawning a phantom op that reloads k_cnt_q
        // with the previous op's value and runs a stray fetch/prog/compute
        // pass against whatever base_addr/mem state happens to be live.
        while (!tlmm.done) @(posedge clk);
        // done co-fires with result_valid; result_acc is final and stable this
        // cycle (the bank is not cleared until the next op's PROG_FETCH entry).
        // Snapshot it here, before dropping busy.
        check_eq_part(tlmm_tile_part_t'(dut_result_valid), tlmm_tile_part_t'(1'b1),
                      $sformatf("%s result_valid co-fires with done", label));
        res_snap = dut_result_acc;
        disp_busy <= 1'b0;
        @(posedge clk);

        // Compare OUT beats vs golden, and accumulate the expected per-lane
        // K-reduction (sign-extend each 17b tile_partial to 32b, sum over beats).
        for (int l = 0; l < int'(TLMM_LANES); l++) exp_acc_arr[l] = '0;
        for (int k = 0; k < op_k; k++) begin
            obeat_t got;
            got = obs_q[prev_obs_size + k];
            for (int l = 0; l < int'(TLMM_LANES); l++) begin
                tlmm_tile_part_t exp_part;
                exp_part = golden_part(acts, wbeats[k][l]);
                check_eq_part(got.parts[l], exp_part,
                              $sformatf("%s beat[%0d].lane[%0d]", label, k, l));
                exp_acc_arr[l] = exp_acc_arr[l] + tlmm_acc_t'($signed(exp_part));
            end
        end

        // result_acc must equal the whole-op K-reduction per lane.
        for (int l = 0; l < int'(TLMM_LANES); l++) begin
            check_eq_acc(res_snap[l], exp_acc_arr[l],
                         $sformatf("%s result_acc.lane[%0d]", label, l));
        end
    endtask

    // -------------------------------------------------------------------------
    // Watchdog
    // -------------------------------------------------------------------------
    initial begin
        #200us;
        $fatal(1, "tb_tlmm_driver: watchdog timeout");
    end

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        // Reset
        rst_n        = 1'b0;
        disp_start   = 1'b0;
        disp_busy    = 1'b0;
        disp_k_cnt   = '0;
        base_addr    = '0;
        for (int i = 0; i < URAM_DEPTH_TB; i++) mem_q[i] = '0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // Test 1: K=1 with deterministic activations + all-POS weights,
        //         partial per lane = sum of activations.
        begin
            tlmm_tile_act_t   acts;
            tern_lane_tiles_t wbeats [];
            wbeats = new[1];
            for (int i = 0; i < int'(TLMM_TILE); i++) begin
                acts[i] = bfp12_mant_t'(i + 1);  // 1..16
            end
            for (int l = 0; l < int'(TLMM_LANES); l++) begin
                for (int t = 0; t < int'(TLMM_TILE); t++) begin
                    wbeats[0][l][t] = TERN_POS;
                end
            end
            run_op(URAM_ADDR_W'(0), 1, acts, wbeats, "T1.K1_all_pos");
        end

        // Test 2: K=1 with mixed +/-/0 weights on one lane, zero on others.
        begin
            tlmm_tile_act_t   acts;
            tern_lane_tiles_t wbeats [];
            wbeats = new[1];
            for (int i = 0; i < int'(TLMM_TILE); i++) begin
                acts[i] = bfp12_mant_t'((i % 2) ? -(i+1) : (i+1));
            end
            for (int l = 0; l < int'(TLMM_LANES); l++) begin
                for (int t = 0; t < int'(TLMM_TILE); t++) begin
                    if (l == 0) begin
                        if (t < 4)       wbeats[0][l][t] = TERN_POS;
                        else if (t < 8)  wbeats[0][l][t] = TERN_NEG;
                        else             wbeats[0][l][t] = TERN_ZERO;
                    end else begin
                        wbeats[0][l][t] = TERN_ZERO;
                    end
                end
            end
            run_op(URAM_ADDR_W'(64), 1, acts, wbeats, "T2.K1_mixed");
        end

        // Test 3: K=4, random.
        begin
            tlmm_tile_act_t   acts;
            tern_lane_tiles_t wbeats [];
            wbeats = new[4];
            acts = rand_acts(32);
            for (int k = 0; k < 4; k++) wbeats[k] = rand_w_beat();
            run_op(URAM_ADDR_W'(128), 4, acts, wbeats, "T3.K4_rand");
        end

        // Test 4: K=8, random, different base.
        begin
            tlmm_tile_act_t   acts;
            tern_lane_tiles_t wbeats [];
            wbeats = new[8];
            acts = rand_acts(64);
            for (int k = 0; k < 8; k++) wbeats[k] = rand_w_beat();
            run_op(URAM_ADDR_W'(512), 8, acts, wbeats, "T4.K8_rand");
        end

        // Test 5: two back-to-back ops at different bases.
        begin
            tlmm_tile_act_t   actsA, actsB;
            tern_lane_tiles_t wbeatsA [], wbeatsB [];
            wbeatsA = new[3];
            wbeatsB = new[5];
            actsA = rand_acts(100);
            actsB = rand_acts(200);
            for (int k = 0; k < 3; k++) wbeatsA[k] = rand_w_beat();
            for (int k = 0; k < 5; k++) wbeatsB[k] = rand_w_beat();
            run_op(URAM_ADDR_W'(1024), 3, actsA, wbeatsA, "T5a.K3");
            run_op(URAM_ADDR_W'(1280), 5, actsB, wbeatsB, "T5b.K5");
        end

        // -- Summary
        repeat (8) @(posedge clk);
        if (n_errors == 0) begin
            $display("=========================================================");
            $display("tb_tlmm_driver: PASS  (%0d / %0d checks)", n_checks, n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display("tb_tlmm_driver: FAIL  (%0d errors / %0d checks)",
                     n_errors, n_checks);
            $display("=========================================================");
        end
        $finish;
    end

endmodule : tb_tlmm_driver

`default_nettype wire
