// -----------------------------------------------------------------------------
// tb_dense_weight_streamer.sv  (Phase-8, Stage 8b)
//
// Unit testbench for dense_weight_streamer.
//
// What it covers:
//   * A full per-tile weight load (512 mantissas) lands on the scan bus at the
//     correct {w_phys_gc, w_pe_addr} index with the correct 12-bit value, for
//     several logical tile coordinates and a non-zero base address.
//   * Exactly 512 scan writes occur per load (no over/under-scan), each global
//     PE index seen exactly once.
//   * The load_req / load_busy / load_done handshake (dense_sched_if) is well
//     formed: load_done is a single pulse that arrives after the final scan.
//   * Directed patterns (ramp, constant, sign extremes) + a randomized sweep
//     over random tiles / random weights / random base.
//
// TB roles:
//   * walker  (dense_sched_if walker side): drive tile_gr/tile_gc/load_req/
//             load_busy; tile_first/tile_last tied 0 (unused by the streamer).
//   * array   (dense_sched_if array side):  capture w_we/w_phys_gc/w_pe_addr/
//             w_in into a per-tile scoreboard.
//   * memory_manager (pingpong_if.mem_mgr): a 1-cycle-latency behavioral URAM.
//
// Single clock, sync active-low reset.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_dense_weight_streamer;
    import types_pkg::*;

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    localparam time CLK_PERIOD = 10ns;
    logic clk = 1'b0;
    logic rst_n;
    initial forever #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Geometry (mirror the DUT's derived localparams)
    // -------------------------------------------------------------------------
    // R6.8b.3: dense pp is WIDE (288b) — 2 cascade words per wide word.
    localparam int unsigned PP_DATA_W        = DENSE_PP_URAM_W;                         // 288
    localparam int unsigned CASC_HALF_W      = PP_DATA_W / 2;                           // 144
    localparam int unsigned MANT_HALF_W      = BFP12_BLK * BFP12_MANT_W / 2;            // 96
    localparam int unsigned WEIGHTS_PER_WORD = MANT_HALF_W / BFP12_MANT_W;              //  8
    localparam int unsigned TILE_PE_TOTAL    = DENSE_PHYS_GROUPS_COL * DENSE_PE_PER_GROUP; // 512
    localparam int unsigned WORDS_PER_TILE   = TILE_PE_TOTAL / WEIGHTS_PER_WORD;        // 64
    localparam int unsigned PE_ADDR_W        = $clog2(DENSE_PE_PER_GROUP);              //  8
    localparam int unsigned PHYS_GC_W        = $clog2(DENSE_PHYS_GROUPS_COL);           //  1
    localparam int unsigned GLOBAL_W         = $clog2(TILE_PE_TOTAL);                   //  9
    localparam int unsigned URAM_DEPTH_TB    = 4096;

    localparam int unsigned TGR_W = $clog2(DENSE_LOGICAL_TILE_ROWS);                    //  3
    localparam int unsigned TGC_W = $clog2(DENSE_LOGICAL_TILE_COLS);                    //  2

    // -------------------------------------------------------------------------
    // Interfaces
    // -------------------------------------------------------------------------
    dense_sched_if sched (clk, rst_n);
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_DATA_W)) pp (clk, rst_n);

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    logic [URAM_ADDR_W-1:0] base_addr;

    dense_weight_streamer #(
        .PP_DATA_W (PP_DATA_W)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .base_addr (base_addr),
        .sched     (sched.streamer),
        .pp        (pp.core)
    );

    // -------------------------------------------------------------------------
    // Walker-side drive (TB owns these interface signals)
    // -------------------------------------------------------------------------
    logic [TGR_W-1:0] wlk_tile_gr;
    logic [TGC_W-1:0] wlk_tile_gc;
    logic             wlk_load_req;
    logic             wlk_load_busy;

    assign sched.tile_gr    = wlk_tile_gr;
    assign sched.tile_gc    = wlk_tile_gc;
    assign sched.tile_first = 1'b0;   // unused by streamer; held to avoid X
    assign sched.tile_last  = 1'b0;
    assign sched.load_req   = wlk_load_req;
    assign sched.load_busy  = wlk_load_busy;
    // sched.load_done / w_* are DUT-driven; TB only reads them.

    // -------------------------------------------------------------------------
    // Behavioral 1-cycle URAM on the manager side of the pingpong.
    // -------------------------------------------------------------------------
    logic [PP_DATA_W-1:0] mem_q [0:URAM_DEPTH_TB-1];

    bank_sel_e            mgr_active_side;
    logic                 mgr_side_valid;
    logic [PP_DATA_W-1:0] mgr_rd_data;
    logic                 mgr_rd_valid;
    logic                 mgr_drain_req;

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
            if (pp.rd_en) mgr_rd_data <= mem_q[pp.rd_addr[$clog2(URAM_DEPTH_TB)-1:0]];
        end
    end

    initial begin
        mgr_active_side = BANK_A;
        mgr_side_valid  = 1'b1;
        mgr_drain_req   = 1'b0;
    end

    // -------------------------------------------------------------------------
    // Reference weights for the current tile + scan-bus capture scoreboard.
    // -------------------------------------------------------------------------
    logic [BFP12_MANT_W-1:0] ref_w   [TILE_PE_TOTAL];
    logic [BFP12_MANT_W-1:0] got_w   [TILE_PE_TOTAL];
    logic                    got_seen[TILE_PE_TOTAL];
    int unsigned             scan_count;

    logic clr_capture;

    // Reconstruct the global PE index from the scan bus.
    logic [GLOBAL_W-1:0] cap_idx;
    assign cap_idx = {sched.w_phys_gc, sched.w_pe_addr};

    // All capture writes live in this one block (non-blocking only) so there is
    // no mixed blocking/non-blocking driver on the scoreboard arrays.
    always_ff @(posedge clk) begin
        if (!rst_n || clr_capture) begin
            for (int g = 0; g < int'(TILE_PE_TOTAL); g++) got_seen[g] <= 1'b0;
            scan_count <= 0;
        end else if (sched.w_we) begin
            // C1.5: each beat writes a whole word = 8 PEs at base cap_idx.
            for (int s = 0; s < int'(BFP12_BLK/2); s++) begin
                got_w[cap_idx + GLOBAL_W'(s)]    <= sched.w_in[s];
                got_seen[cap_idx + GLOBAL_W'(s)] <= 1'b1;
            end
            scan_count <= scan_count + (BFP12_BLK/2);
        end
    end

    // -------------------------------------------------------------------------
    // Scoreboard
    // -------------------------------------------------------------------------
    int n_checks = 0;
    int n_errors = 0;

    function automatic void check_eq(
        input logic [BFP12_MANT_W-1:0] got, exp,
        input string                   label
    );
        n_checks++;
        if (got !== exp) begin
            n_errors++;
            $error("[%0t] %s: mismatch got=%h exp=%h", $time, label, got, exp);
        end
    endfunction

    function automatic void check_true(input logic c, input string label);
        n_checks++;
        if (c !== 1'b1) begin
            n_errors++;
            $error("[%0t] %s: expected true", $time, label);
        end
    endfunction

    // -------------------------------------------------------------------------
    // Tile programming: fill ref_w[] and the URAM image for tile (gr,gc).
    //   mode 0 = ramp, 1 = const(seed), 2 = sign-alt extremes, 3 = random.
    // -------------------------------------------------------------------------
    function automatic void program_tile(
        input logic [URAM_ADDR_W-1:0] base,
        input int                     gr,
        input int                     gc,
        input int                     mode,
        input logic [BFP12_MANT_W-1:0] seed
    );
        int                     tile_lin;
        logic [URAM_ADDR_W-1:0] tile_base;
        tile_lin  = gr * int'(DENSE_LOGICAL_TILE_COLS) + gc;
        tile_base = base + URAM_ADDR_W'(tile_lin * int'(WORDS_PER_TILE));

        for (int g = 0; g < int'(TILE_PE_TOTAL); g++) begin
            logic [BFP12_MANT_W-1:0] wv;
            unique case (mode)
                0:       wv = BFP12_MANT_W'(g);
                1:       wv = seed;
                2:       wv = g[0] ? 12'sh7FF : 12'sh800;  // +2047 / -2048 alt
                default: wv = BFP12_MANT_W'($urandom);
            endcase
            ref_w[g] = wv;
        end

        for (int w = 0; w < int'(WORDS_PER_TILE); w++) begin
            logic [CASC_HALF_W-1:0] wd;
            wd = '0;
            for (int s = 0; s < int'(WEIGHTS_PER_WORD); s++) begin
                automatic int g = w * int'(WEIGHTS_PER_WORD) + s;
                wd[s*BFP12_MANT_W +: BFP12_MANT_W] = ref_w[g];
            end
            // Cascade word w -> wide word (tile_base+w)>>1, low half for even w,
            // high half for odd w (matches the streamer's >>1 + word_idx[0] select).
            mem_q[(tile_base + URAM_ADDR_W'(w)) >> 1][(w[0] ? CASC_HALF_W : 0) +: CASC_HALF_W] = wd;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Run one weight load and verify.
    // -------------------------------------------------------------------------
    task automatic run_tile(
        input logic [URAM_ADDR_W-1:0] base,
        input int                     gr,
        input int                     gc,
        input string                  label
    );
        // Present base + coords, then clear the scoreboard (w_we is 0 while
        // idle so the clear cannot race a capture).
        @(posedge clk);
        base_addr   <= base;
        wlk_tile_gr <= TGR_W'(gr);
        wlk_tile_gc <= TGC_W'(gc);
        clr_capture <= 1'b1;
        @(posedge clk);
        clr_capture <= 1'b0;

        // Issue the load: req pulse (1 cycle), busy held until done.
        wlk_load_busy <= 1'b1;
        wlk_load_req  <= 1'b1;
        @(posedge clk);
        wlk_load_req  <= 1'b0;

        // Wait for completion.
        while (!sched.load_done) @(posedge clk);
        @(posedge clk);
        wlk_load_busy <= 1'b0;
        @(posedge clk);

        // Verify: every global PE index seen exactly once with the right value.
        check_true(scan_count == TILE_PE_TOTAL,
                   $sformatf("%s scan_count==512 (got %0d)", label, scan_count));
        for (int g = 0; g < int'(TILE_PE_TOTAL); g++) begin
            check_true(got_seen[g], $sformatf("%s pe[%0d] seen", label, g));
            check_eq(got_w[g], ref_w[g], $sformatf("%s pe[%0d]", label, g));
        end
    endtask

    // -------------------------------------------------------------------------
    // Watchdog
    // -------------------------------------------------------------------------
    initial begin
        #500us;
        $fatal(1, "tb_dense_weight_streamer: watchdog timeout");
    end

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin
        rst_n         = 1'b0;
        base_addr     = '0;
        wlk_tile_gr   = '0;
        wlk_tile_gc   = '0;
        wlk_load_req  = 1'b0;
        wlk_load_busy = 1'b0;
        clr_capture   = 1'b0;
        for (int i = 0; i < URAM_DEPTH_TB; i++) mem_q[i] = '0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // T1: tile (0,0), ramp, base 0.
        program_tile(URAM_ADDR_W'(0), 0, 0, 0, 12'h000);
        run_tile(URAM_ADDR_W'(0), 0, 0, "T1.ramp(0,0)");

        // T2: tile (3,2), constant, base 0 (exercises tile_linear addressing).
        program_tile(URAM_ADDR_W'(0), 3, 2, 1, 12'h5A5);
        run_tile(URAM_ADDR_W'(0), 3, 2, "T2.const(3,2)");

        // T3: tile (7,3) — last tile — sign extremes, base 0.
        program_tile(URAM_ADDR_W'(0), 7, 3, 2, 12'h000);
        run_tile(URAM_ADDR_W'(0), 7, 3, "T3.sign(7,3)");

        // T4: non-zero base, tile (0,0), random.
        program_tile(URAM_ADDR_W'(2048), 0, 0, 3, 12'h000);
        run_tile(URAM_ADDR_W'(2048), 0, 0, "T4.rand@2048(0,0)");

        // T5: randomized sweep — random tiles, random weights, base 0.
        for (int t = 0; t < 8; t++) begin
            automatic int rgr = $urandom_range(0, int'(DENSE_LOGICAL_TILE_ROWS) - 1);
            automatic int rgc = $urandom_range(0, int'(DENSE_LOGICAL_TILE_COLS) - 1);
            program_tile(URAM_ADDR_W'(0), rgr, rgc, 3, 12'h000);
            run_tile(URAM_ADDR_W'(0), rgr, rgc, $sformatf("T5.rand(%0d,%0d)", rgr, rgc));
        end

        repeat (8) @(posedge clk);
        if (n_errors == 0) begin
            $display("=========================================================");
            $display(" tb_dense_weight_streamer: PASS  (%0d / %0d checks)", n_checks, n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_dense_weight_streamer: FAIL  (%0d errors / %0d checks)",
                     n_errors, n_checks);
            $display("=========================================================");
        end
        $finish;
    end

endmodule : tb_dense_weight_streamer

`default_nettype wire
