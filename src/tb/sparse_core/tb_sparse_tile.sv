
`ifndef ARCHBETTER_TB_SPARSE_TILE_SV
`define ARCHBETTER_TB_SPARSE_TILE_SV
`default_nettype none
`timescale 1ns/1ps

module tb_sparse_tile
    import types_pkg::*;
();
    localparam time T_CLK                   = 10ns;
    localparam int  N_RAND_EPOCHS           = 3;
    localparam int  N_RAND_BEATS_PER_EPOCH  = 50;
    localparam int  PIPE_LATENCY_MAX        = 8;
    localparam int  WATCHDOG_CLKS           = 500_000;
    logic clk, rst_n;

    tlmm_ctrl_if ctrl (.clk(clk), .rst_n(rst_n));

    sparse_tile dut (
        .clk   (clk),
        .rst_n (rst_n),
        .ctrl  (ctrl.tile)
    );
    initial clk = 1'b0;
    always  #(T_CLK/2) clk = ~clk;
    bfp12_mant_t acts_ref [TLMM_TILE];
    tlmm_part_vec_t expected_q [$];

    int n_beats;
    int n_errors;
    function automatic tlmm_tile_part_t golden_lane_partial(input tern_tile_t w);
        automatic int acc;
        acc = 0;
        for (int i = 0; i < int'(TLMM_TILE); i++) begin
            case (w[i])
                TERN_POS : acc += $signed(acts_ref[i]);
                TERN_NEG : acc -= $signed(acts_ref[i]);
                TERN_ZERO: ;
                default  : ;
            endcase
        end
        return tlmm_tile_part_t'(acc);
    endfunction

    function automatic tlmm_part_vec_t golden_beat(input tern_lane_tiles_t wb);
        tlmm_part_vec_t v;
        for (int l = 0; l < int'(TLMM_LANES); l++) v[l] = golden_lane_partial(wb[l]);
        return v;
    endfunction
    always_ff @(posedge clk) begin
        if (rst_n && ctrl.o_valid && ctrl.o_ready) begin
            if (expected_q.size() == 0) begin
                n_errors++;
                $error("[%0t] scoreboard underflow: o_valid with no expected", $time);
            end else begin
                automatic tlmm_part_vec_t exp_vec = expected_q.pop_front();
                for (int l = 0; l < int'(TLMM_LANES); l++) begin
                    if (ctrl.o_parts[l] !== exp_vec[l]) begin
                        n_errors++;
                        $error("[%0t] lane %0d mismatch: dut=%0d ref=%0d",
                               $time, l, $signed(ctrl.o_parts[l]),
                               $signed(exp_vec[l]));
                    end
                end
            end
        end
    end
    task automatic program_activations(input bfp12_mant_t a[TLMM_TILE]);
        tlmm_tile_act_t packed_acts;
        for (int i = 0; i < int'(TLMM_TILE); i++) packed_acts[i] = a[i];
        @(posedge clk);
        ctrl.prog_acts  <= packed_acts;
        ctrl.prog_valid <= 1'b1;
        do @(posedge clk); while (!ctrl.prog_ready);
        ctrl.prog_valid <= 1'b0;
        for (int i = 0; i < int'(TLMM_TILE); i++) acts_ref[i] = a[i];
        while (!ctrl.w_ready) @(posedge clk);
    endtask
    task automatic drive_weight_beat(input tern_lane_tiles_t wb);
        tlmm_part_vec_t exp_vec;
        exp_vec = golden_beat(wb);
        expected_q.push_back(exp_vec);
        n_beats++;

        @(posedge clk);
        ctrl.w_tiles <= wb;
        ctrl.w_valid <= 1'b1;
        do @(posedge clk); while (!ctrl.w_ready);
        ctrl.w_valid <= 1'b0;
    endtask
    function automatic void acts_zero(output bfp12_mant_t a[TLMM_TILE]);
        for (int i = 0; i < int'(TLMM_TILE); i++) a[i] = '0;
    endfunction

    function automatic void acts_ramp(output bfp12_mant_t a[TLMM_TILE]);
        for (int i = 0; i < int'(TLMM_TILE); i++) a[i] = bfp12_mant_t'(i + 1);
    endfunction

    function automatic void acts_max(output bfp12_mant_t a[TLMM_TILE]);
        for (int i = 0; i < int'(TLMM_TILE); i++) a[i] = 12'sh7FF;
    endfunction

    function automatic void acts_random(output bfp12_mant_t a[TLMM_TILE]);
        for (int i = 0; i < int'(TLMM_TILE); i++)
            a[i] = bfp12_mant_t'($urandom());
    endfunction
    function automatic tern_weight_e rand_tern();
        automatic int r = $urandom_range(0, 2);
        case (r)
            0: return TERN_ZERO;
            1: return TERN_POS;
            2: return TERN_NEG;
            default: return TERN_ZERO;
        endcase
    endfunction

    function automatic tern_lane_tiles_t wb_const(input tern_weight_e v);
        tern_lane_tiles_t wb;
        for (int l = 0; l < int'(TLMM_LANES); l++)
            for (int i = 0; i < int'(TLMM_TILE); i++)
                wb[l][i] = v;
        return wb;
    endfunction

    function automatic tern_lane_tiles_t wb_random();
        tern_lane_tiles_t wb;
        for (int l = 0; l < int'(TLMM_LANES); l++)
            for (int i = 0; i < int'(TLMM_TILE); i++)
                wb[l][i] = rand_tern();
        return wb;
    endfunction
    function automatic tern_lane_tiles_t wb_one_hot();
        tern_lane_tiles_t wb;
        for (int l = 0; l < int'(TLMM_LANES); l++) begin
            for (int i = 0; i < int'(TLMM_TILE); i++) wb[l][i] = TERN_ZERO;
            wb[l][l % TLMM_TILE] = TERN_POS;
        end
        return wb;
    endfunction
    task automatic run_directed();
        bfp12_mant_t a[TLMM_TILE];

        $display("[%0t] DIRECTED: zero activations + random weights", $time);
        acts_zero(a);
        program_activations(a);
        for (int b = 0; b < 8; b++) drive_weight_beat(wb_random());

        $display("[%0t] DIRECTED: ramp activations + all-+1 weights", $time);
        acts_ramp(a);
        program_activations(a);
        drive_weight_beat(wb_const(TERN_POS));

        $display("[%0t] DIRECTED: ramp activations + all-(-1) weights", $time);
        acts_ramp(a);
        program_activations(a);
        drive_weight_beat(wb_const(TERN_NEG));

        $display("[%0t] DIRECTED: random activations + all-zero weights", $time);
        acts_random(a);
        program_activations(a);
        drive_weight_beat(wb_const(TERN_ZERO));

        $display("[%0t] DIRECTED: random activations + one-hot lane weights", $time);
        acts_random(a);
        program_activations(a);
        drive_weight_beat(wb_one_hot());

        $display("[%0t] DIRECTED: max-magnitude activations + random weights (headroom)", $time);
        acts_max(a);
        program_activations(a);
        for (int b = 0; b < 8; b++) drive_weight_beat(wb_random());
    endtask
    task automatic run_random_epoch(input int epoch_id);
        bfp12_mant_t a[TLMM_TILE];
        acts_random(a);
        program_activations(a);
        $display("[%0t] RANDOM epoch %0d: %0d weight beats",
                 $time, epoch_id, N_RAND_BEATS_PER_EPOCH);
        for (int b = 0; b < N_RAND_BEATS_PER_EPOCH; b++)
            drive_weight_beat(wb_random());
    endtask
    task automatic drain_scoreboard();
        int guard = 0;
        while (expected_q.size() > 0) begin
            @(posedge clk);
            guard++;
            if (guard > (PIPE_LATENCY_MAX + 64)) begin
                n_errors++;
                $error("[%0t] drain timeout with %0d expected remaining",
                       $time, expected_q.size());
                return;
            end
        end
    endtask
    initial begin
        rst_n           = 1'b0;
        ctrl.prog_acts  = '0;
        ctrl.prog_valid = 1'b0;
        ctrl.w_tiles    = '0;
        ctrl.w_valid    = 1'b0;
        ctrl.o_ready    = 1'b1;
        n_beats         = 0;
        n_errors        = 0;

        for (int i = 0; i < int'(TLMM_TILE); i++) acts_ref[i] = '0;

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        run_directed();
        drain_scoreboard();

        for (int e = 0; e < N_RAND_EPOCHS; e++) begin
            run_random_epoch(e);
            drain_scoreboard();
        end

        if (n_errors == 0 && n_beats > 0) begin
            $display("=========================================================");
            $display(" tb_sparse_tile: PASS  (%0d beats, 0 errors)", n_beats);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_sparse_tile: FAIL  (%0d beats, %0d errors)",
                     n_beats, n_errors);
            $display("=========================================================");
        end

        $finish;
    end
    initial begin
        #(T_CLK * WATCHDOG_CLKS);
        $fatal(1, "tb_sparse_tile: watchdog timeout");
    end

endmodule : tb_sparse_tile

`default_nettype wire
`endif
