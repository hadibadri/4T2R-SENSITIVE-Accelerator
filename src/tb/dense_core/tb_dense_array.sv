// -----------------------------------------------------------------------------
// tb_dense_array.sv  (Phase-7d refactor: time-multiplexed contract)
//
// Validates the refactored dense_array (16x32 physical kernel,
// time-multiplexed 32x to logical 128x128). Walks the 32-tile schedule
// explicitly, scanning weights per tile, and compares the drained y_out
// against a pure-SV golden reference y[c] = sum_r W[r,c] * a[r].
//
// Tests
//   T1  K=1, identity weights (W[i,j] = (i==j))                -> y[c] = a[c]
//   T2  K=1, zero weights                                       -> y = 0
//   T3  K=4, ramp activations + constant weights
//   T4  K=8, max-magnitude headroom (ARRAY_ACC_W check)
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_TB_DENSE_ARRAY_SV
`define ARCHBETTER_TB_DENSE_ARRAY_SV
`default_nettype none
`timescale 1ns/1ps

module tb_dense_array
    import types_pkg::*;
();
    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------
    localparam time T_CLK     = 10ns;
    localparam int  ROWS      = DENSE_ARRAY_ROWS;            // 128
    localparam int  COLS      = DENSE_ARRAY_COLS;            // 128
    localparam int  PHYS_COLS = DENSE_PHYS_COLS;             //  32
    localparam int  GRS       = DENSE_GROUP_ROWS;            //  16
    localparam int  GCS       = DENSE_GROUP_COLS;            //  16
    localparam int  T_ROWS    = DENSE_LOGICAL_TILE_ROWS;     //   8
    localparam int  T_COLS    = DENSE_LOGICAL_TILE_COLS;     //   4
    localparam int  PE_ADDR_W = $clog2(DENSE_PE_PER_GROUP);

    // -------------------------------------------------------------------------
    // DUT nets
    // -------------------------------------------------------------------------
    logic clk, rst_n;

    strm_if #(.DATA_W(NOC_DATA_W), .USER_W(NOC_USER_W))
        a_strm (.clk(clk), .rst_n(rst_n));

    localparam int  BT = 4;   // TB batch depth (weight-resident batched test);
                              // 4 tokens stream contiguously in v2 so the tok_out
                              // alignment is exercised across several rows.

    logic [$clog2(T_ROWS)-1:0] tile_gr;
    logic [$clog2(T_COLS)-1:0] tile_gc;
    logic [BATCH_TOK_W-1:0]    tile_tok;
    logic [BATCH_TOK_W-1:0]    batch_n;
    logic                      tile_first, tile_last;
    logic                      acc_clr, acc_snap;
    gemm_stream_mode_e         stream_mode;

    logic                      w_we;
    logic                      w_phys_gc;
    logic [PE_ADDR_W-1:0]      w_pe_addr;
    bfp12_mant_t [(BFP12_BLK/2)-1:0] w_in;   // 8 mantissas/beat (C1.5)

    array_acc_t [COLS-1:0]     y_out;
    logic                      y_valid;

    dense_array #(
        .ENABLE_NOISE_HOOKS (1'b0),
        .ARRAY_ID           (32'd0),
        .BATCH_T            (BT)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .a_strm     (a_strm),
        .tile_gr    (tile_gr),
        .tile_gc    (tile_gc),
        .tile_tok   (tile_tok),
        .batch_n    (batch_n),
        .drain_busy (1'b0),
        .tile_first (tile_first),
        .tile_last  (tile_last),
        .acc_clr    (acc_clr),
        .acc_snap   (acc_snap),
        .stream_mode (stream_mode),
        .w_we       (w_we),
        .w_phys_gc  (w_phys_gc),
        .w_pe_addr  (w_pe_addr),
        .w_in       (w_in),
        .y_out      (y_out),
        .y_valid    (y_valid)
    );

    initial clk = 1'b0;
    always  #(T_CLK/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // TB-side stream drivers
    // -------------------------------------------------------------------------
    logic [NOC_DATA_W-1:0] tb_data;
    logic                  tb_valid, tb_last;

    assign a_strm.data  = tb_data;
    assign a_strm.user  = '0;
    assign a_strm.valid = tb_valid;
    assign a_strm.last  = tb_last;

    // -------------------------------------------------------------------------
    // Capture
    // -------------------------------------------------------------------------
    array_acc_t [COLS-1:0] y_snapped;
    logic                  snap_seen;
    logic                  snap_clear;   // task-driven 1-cycle re-arm pulse
    int                    n_errors;

    // snap_seen is driven by exactly this always_ff (set on y_valid, cleared by
    // the task's snap_clear pulse) — no second procedural driver, so it elabs
    // clean.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            snap_seen <= 1'b0;
        end else if (snap_clear) begin
            snap_seen <= 1'b0;
        end else if (y_valid) begin
            y_snapped <= y_out;
            snap_seen <= 1'b1;
        end
    end

    // Batched-mode capture: the drain streams bank[0..batch_n-1] as successive
    // y_valid pulses; record each token's 128-wide output in arrival order.
    array_acc_t [COLS-1:0] y_batch [BT];
    int                    batch_cap_idx;
    logic                  batch_cap_arm;   // 1-cycle index reset at batch start

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            batch_cap_idx <= 0;
        end else if (batch_cap_arm) begin
            batch_cap_idx <= 0;
        end else if (y_valid && (batch_cap_idx < BT)) begin
            y_batch[batch_cap_idx] <= y_out;
            batch_cap_idx          <= batch_cap_idx + 1;
        end
    end

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    task automatic strm_set(input logic v, input logic l, input bfp12_mant_t row_band[GRS]);
        logic [NOC_DATA_W-1:0] d;
        d = '0;
        for (int r = 0; r < GRS; r++)
            d[r*BFP12_MANT_W +: BFP12_MANT_W] = row_band[r];
        tb_data  <= d;
        tb_valid <= v;
        tb_last  <= l;
    endtask

    task automatic strm_idle();
        tb_data  <= '0;
        tb_valid <= 1'b0;
        tb_last  <= 1'b0;
    endtask

    // Scan weights for one tile (tile_gr_v, tile_gc_v) into both phys groups.
    // Tile covers rows [tile_gr_v*16 +: 16] x cols [tile_gc_v*32 +: 32].
    // Phys group 0 holds cols [tile_gc_v*32 .. tile_gc_v*32+15].
    // Phys group 1 holds cols [tile_gc_v*32+16 .. tile_gc_v*32+31].
    // pe_addr within group = local_r * GCS + local_c.
    task automatic load_tile_weights(
        input int                    tile_gr_v,
        input int                    tile_gc_v,
        input bfp12_mant_t           wm[ROWS][COLS]
    );
        localparam int WSCAN = BFP12_BLK / 2;   // 8 PEs/beat
        for (int local_r = 0; local_r < GRS; local_r++) begin
            for (int half = 0; half < GCS / WSCAN; half++) begin
                automatic int gr_base = tile_gr_v * GRS;
                automatic int gc_base = tile_gc_v * PHYS_COLS;
                automatic int c_base  = half * WSCAN;
                automatic int pe_a    = local_r * GCS + c_base;
                // phys group 0
                @(posedge clk);
                for (int s = 0; s < WSCAN; s++)
                    w_in[s] <= wm[gr_base + local_r][gc_base + c_base + s];
                w_we      <= 1'b1;
                w_phys_gc <= 1'b0;
                w_pe_addr <= pe_a[PE_ADDR_W-1:0];
                // phys group 1
                @(posedge clk);
                for (int s = 0; s < WSCAN; s++)
                    w_in[s] <= wm[gr_base + local_r][gc_base + GCS + c_base + s];
                w_we      <= 1'b1;
                w_phys_gc <= 1'b1;
                w_pe_addr <= pe_a[PE_ADDR_W-1:0];
            end
        end
        @(posedge clk);
        w_we <= 1'b0;
    endtask

    // Drive K activation beats for the current tile_gr (16-wide row band).
    // acc_clr fires concurrent with the first beat; acc_snap one cycle after
    // the last. tile_last_v controls whether the snap also drains the bank.
    task automatic drive_tile_compute(
        input int          K,
        input bfp12_mant_t a_full[ROWS],
        input int          tile_gr_v,
        input logic        tile_last_v
    );
        bfp12_mant_t row_band [GRS];
        for (int r = 0; r < GRS; r++)
            row_band[r] = a_full[tile_gr_v * GRS + r];

        for (int k = 0; k < K; k++) begin
            @(posedge clk);
            strm_set(1'b1, (k == K-1), row_band);
            acc_clr   <= (k == 0);
            acc_snap  <= 1'b0;
            tile_last <= 1'b0;
        end
        // Drop valid, then drain the fused MACC (AREG+MREG+PREG) before snap.
        // The DSP P register holds the completed sum once valid drops, so a
        // generous drain is always safe (dense_group contract).
        @(posedge clk);
        strm_idle();
        acc_clr   <= 1'b0;
        repeat (4) @(posedge clk);
        acc_snap  <= 1'b1;
        tile_last <= tile_last_v;
        @(posedge clk);
        acc_snap  <= 1'b0;
        tile_last <= 1'b0;
    endtask

    // Run a full 128x128 GEMV: walk 32 tiles in raster order (tile_gc outer,
    // tile_gr inner), with tile_first on the very first acc_clr and tile_last
    // on the very last acc_snap.
    task automatic run_layer(
        input int          K,
        input bfp12_mant_t wm   [ROWS][COLS],
        input bfp12_mant_t a_full[ROWS]
    );
        // Re-arm the snap detector.
        snap_clear <= 1'b1;
        @(posedge clk);
        snap_clear <= 1'b0;

        // Pulse tile_first one cycle before the first acc_clr (clears the bank).
        @(posedge clk);
        tile_first <= 1'b1;
        @(posedge clk);
        tile_first <= 1'b0;

        // Time-multiplex: the physical 16x32 kernel holds ONE logical tile's
        // weights at a time (512 PEs, one w_reg each). Each tile must therefore
        // scan in its OWN weights immediately before its compute pass. The
        // previous "load all 32 up front" only worked when every tile shared
        // identical weights (zero / constant), and silently produced the last
        // tile's weights for tile-varying matrices such as identity.
        for (int tgc = 0; tgc < T_COLS; tgc++) begin
            for (int tgr = 0; tgr < T_ROWS; tgr++) begin
                automatic logic last_tile = (tgc == T_COLS-1) && (tgr == T_ROWS-1);
                load_tile_weights(tgr, tgc, wm);
                tile_gr <= tgr[$clog2(T_ROWS)-1:0];
                tile_gc <= tgc[$clog2(T_COLS)-1:0];
                drive_tile_compute(K, a_full, tgr, last_tile);
            end
        end

        // Wait for y_valid drain pulse (worst case ~4 cycles after final snap).
        for (int w = 0; w < 16; w++) begin
            @(posedge clk);
            if (snap_seen) break;
        end
        if (!snap_seen) begin
            $error("tb_dense_array: y_valid never pulsed after final tile_last");
            n_errors++;
        end
    endtask

    // -------------------------------------------------------------------------
    // Golden model
    // -------------------------------------------------------------------------
    function automatic array_acc_t golden_y(
        input int          c,
        input int          K,
        input bfp12_mant_t wm    [ROWS][COLS],
        input bfp12_mant_t a_full[ROWS]
    );
        array_acc_t s;
        s = '0;
        for (int k_iter = 0; k_iter < K; k_iter++) begin
            for (int r = 0; r < ROWS; r++) begin
                s += array_acc_t'(wm[r][c]) * array_acc_t'(a_full[r]);
            end
        end
        return s;
    endfunction

    task automatic check_against_golden(
        input string       label,
        input int          K,
        input bfp12_mant_t wm    [ROWS][COLS],
        input bfp12_mant_t a_full[ROWS]
    );
        int local_err;
        local_err = 0;
        for (int c = 0; c < COLS; c++) begin
            automatic array_acc_t exp = golden_y(c, K, wm, a_full);
            if (y_snapped[c] !== exp) begin
                if (local_err < 4)
                    $error("tb_dense_array %s: y[%0d]=%0d exp=%0d", label, c, $signed(y_snapped[c]), $signed(exp));
                local_err++;
            end
        end
        if (local_err == 0) $display("tb_dense_array %s: PASS", label);
        else                $display("tb_dense_array %s: FAIL (%0d cols mismatched)", label, local_err);
        n_errors += local_err;
    endtask

    // -------------------------------------------------------------------------
    // Weight-resident batched GEMM (C1.5): walk the 32-tile grid, loading each
    // tile's weights ONCE, then stream BT tokens through the resident weights.
    // tile_tok selects the bank row per token; tile_last fires only on the very
    // last (tile,token) snap; the array drains BT outputs.
    // -------------------------------------------------------------------------
    task automatic run_batch(
        input int          K,
        input bfp12_mant_t wm   [ROWS][COLS],
        input bfp12_mant_t a_tok[BT][ROWS]
    );
        batch_cap_arm <= 1'b1;
        batch_n       <= BATCH_TOK_W'(BT);
        @(posedge clk);
        batch_cap_arm <= 1'b0;

        // tile_first clears ALL bank rows at batch start.
        @(posedge clk);
        tile_first <= 1'b1;
        @(posedge clk);
        tile_first <= 1'b0;

        for (int tgc = 0; tgc < T_COLS; tgc++) begin
            for (int tgr = 0; tgr < T_ROWS; tgr++) begin
                load_tile_weights(tgr, tgc, wm);   // load ONCE; reused across BT tokens
                tile_gr <= tgr[$clog2(T_ROWS)-1:0];
                tile_gc <= tgc[$clog2(T_COLS)-1:0];
                for (int t = 0; t < BT; t++) begin
                    automatic logic last_snap =
                        (tgc == T_COLS-1) && (tgr == T_ROWS-1) && (t == BT-1);
                    tile_tok <= BATCH_TOK_W'(t);
                    drive_tile_compute(K, a_tok[t], tgr, last_snap);
                end
            end
        end

        // Wait for BT drain pulses.
        for (int w = 0; w < 64; w++) begin
            @(posedge clk);
            if (batch_cap_idx >= BT) break;
        end
        if (batch_cap_idx < BT) begin
            $error("tb_dense_array: batched drain produced %0d/%0d outputs",
                   batch_cap_idx, BT);
            n_errors++;
        end
    endtask

    // -------------------------------------------------------------------------
    // v2 continuous batched GEMM (R6.3): weights loaded ONCE per tile, then the
    // BT tokens stream through at II=1 with acc_clr=1 on every beat and NO
    // acc_snap. The array's tok_out shift register must route each beat's partial
    // to the correct bank row (bank[t]) DENSE_CONT_RESULT_LAT cycles later. K is
    // forced to 1 (the matrix-vector regime the continuous path is built for).
    // This is the alignment gate: a wrong tok_out depth swaps/collides tokens.
    // -------------------------------------------------------------------------
    task automatic run_batch_continuous(
        input bfp12_mant_t wm   [ROWS][COLS],
        input bfp12_mant_t a_tok[BT][ROWS]
    );
        bfp12_mant_t row_band [GRS];

        stream_mode   = GEMM_SNAP_CONTINUOUS;
        batch_cap_arm <= 1'b1;
        batch_n       <= BATCH_TOK_W'(BT);
        @(posedge clk);
        batch_cap_arm <= 1'b0;

        // tile_first clears ALL bank rows at batch start.
        @(posedge clk);
        tile_first <= 1'b1;
        @(posedge clk);
        tile_first <= 1'b0;

        for (int tgc = 0; tgc < T_COLS; tgc++) begin
            for (int tgr = 0; tgr < T_ROWS; tgr++) begin
                automatic logic last_tile = (tgc == T_COLS-1) && (tgr == T_ROWS-1);
                load_tile_weights(tgr, tgc, wm);   // load ONCE; reused across BT
                tile_gr <= tgr[$clog2(T_ROWS)-1:0];
                tile_gc <= tgc[$clog2(T_COLS)-1:0];
                @(posedge clk);                    // let tile_gr/gc settle

                // Stream BT token-beats back to back, K=1 each (acc_clr every beat).
                for (int t = 0; t < BT; t++) begin
                    automatic logic last_beat = last_tile && (t == BT-1);
                    for (int r = 0; r < GRS; r++)
                        row_band[r] = a_tok[t][tgr * GRS + r];
                    strm_set(1'b1, last_beat, row_band);
                    acc_clr   <= 1'b1;
                    acc_snap  <= 1'b0;
                    tile_tok  <= BATCH_TOK_W'(t);
                    tile_last <= last_beat;        // pulse with the final beat
                    @(posedge clk);
                end
                strm_idle();
                acc_clr   <= 1'b0;
                tile_last <= 1'b0;
                @(posedge clk);                    // hold tile_gc stable post-stream
            end
        end

        // Wait for BT drain pulses (tok_out tail + per-token drain).
        for (int w = 0; w < 128; w++) begin
            @(posedge clk);
            if (batch_cap_idx >= BT) break;
        end
        if (batch_cap_idx < BT) begin
            $error("tb_dense_array: continuous drain produced %0d/%0d outputs",
                   batch_cap_idx, BT);
            n_errors++;
        end
        stream_mode = GEMM_SNAP_PER_TOKEN;
    endtask

    task automatic check_batch(
        input string       label,
        input int          K,
        input bfp12_mant_t wm   [ROWS][COLS],
        input bfp12_mant_t a_tok[BT][ROWS]
    );
        int local_err;
        local_err = 0;
        for (int t = 0; t < BT; t++) begin
            for (int c = 0; c < COLS; c++) begin
                automatic array_acc_t exp = golden_y(c, K, wm, a_tok[t]);
                if (y_batch[t][c] !== exp) begin
                    if (local_err < 4)
                        $error("tb_dense_array %s tok%0d: y[%0d]=%0d exp=%0d",
                               label, t, c, $signed(y_batch[t][c]), $signed(exp));
                    local_err++;
                end
            end
        end
        if (local_err == 0) $display("tb_dense_array %s: PASS (%0d tokens, resident weights)", label, BT);
        else                $display("tb_dense_array %s: FAIL (%0d mismatched)", label, local_err);
        n_errors += local_err;
    endtask

    // -------------------------------------------------------------------------
    // Stim
    // -------------------------------------------------------------------------
    bfp12_mant_t W      [ROWS][COLS];
    bfp12_mant_t A      [ROWS];
    bfp12_mant_t Abatch [BT][ROWS];

    initial begin
        clk        = 1'b0;
        rst_n      = 1'b0;
        tile_gr    = '0;
        tile_gc    = '0;
        tile_tok   = '0;
        batch_n    = BATCH_TOK_W'(1);
        tile_first = 1'b0;
        tile_last  = 1'b0;
        acc_clr    = 1'b0;
        acc_snap   = 1'b0;
        stream_mode = GEMM_SNAP_PER_TOKEN;
        w_we       = 1'b0;
        w_phys_gc  = 1'b0;
        w_pe_addr  = '0;
        w_in       = '0;
        strm_idle();
        snap_clear    = 1'b0;
        batch_cap_arm = 1'b0;
        n_errors      = 0;
        repeat (4) @(posedge clk);
        rst_n      = 1'b1;
        repeat (2) @(posedge clk);

        // T1: identity W, K=1
        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                W[r][c] = (r == c) ? 12'sd1 : 12'sd0;
        for (int r = 0; r < ROWS; r++) A[r] = 12'sd5;
        run_layer(1, W, A);
        check_against_golden("T1_identity", 1, W, A);

        // T2: zero W, K=1
        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                W[r][c] = '0;
        run_layer(1, W, A);
        check_against_golden("T2_zero_w", 1, W, A);

        // T3: constant W=2, ramp A, K=4
        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                W[r][c] = 12'sd2;
        for (int r = 0; r < ROWS; r++) A[r] = bfp12_mant_t'(r % 16);
        run_layer(4, W, A);
        check_against_golden("T3_const_w_ramp_a", 4, W, A);

        // T4: weight-resident batched GEMM. Two tokens with DISTINCT activations
        // stream through one weight-load per tile; the array must produce two
        // independent correct outputs (proves residency + per-token bank).
        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                W[r][c] = bfp12_mant_t'(signed'(((r + c) % 5) - 2));
        for (int r = 0; r < ROWS; r++) begin
            Abatch[0][r] = bfp12_mant_t'(signed'((r % 7) - 3));
            Abatch[1][r] = bfp12_mant_t'(signed'((r % 4) - 1));
            Abatch[2][r] = bfp12_mant_t'(signed'((r % 9) - 4));
            Abatch[3][r] = bfp12_mant_t'(signed'(((2*r + 1) % 6) - 3));
        end
        run_batch(1, W, Abatch);
        check_batch("T4_batch4_v1", 1, W, Abatch);

        // T5: v2 CONTINUOUS batched GEMM — same weights/tokens as T4 but streamed
        // at II=1 with no acc_snap, routed by the tok_out pipeline. Must match the
        // identical golden, proving the continuous bank RMW + tok_out alignment.
        run_batch_continuous(W, Abatch);
        check_batch("T5_batch4_continuous", 1, W, Abatch);

        if (n_errors == 0) $display("tb_dense_array: ALL TESTS PASSED");
        else               $display("tb_dense_array: FAILED with %0d errors", n_errors);
        $finish;
    end

endmodule : tb_dense_array

`default_nettype wire
`endif // ARCHBETTER_TB_DENSE_ARRAY_SV
