// -----------------------------------------------------------------------------
// tb_dispatcher_layer.sv  (Phase-8, Stage 8c)
//
// Control-plane unit testbench for the dispatcher's OP_GEMM_LAYER tile-walker.
//
// Scope: this verifies the SEQUENCING the walker emits, not datapath values
// (those are covered by tb_dense_weight_streamer, the dense-core units, and the
// future tb_archbetter_core). The TB plays the two counterparts the walker
// drives — the dense weight streamer (dense_sched_if) and the activation
// streamer (gemm_issue_if) — as lightweight proxies, and scoreboards:
//
//   * the walker visits every tile of the row_cnt x col_cnt grid exactly once,
//     in raster order (gc fastest), driving one load_req per tile;
//   * acc_clr fires once per tile, acc_snap fires once per tile;
//   * tile_first pulses exactly once, on the FIRST tile (0,0), co-incident with
//     an acc_clr (the array bank-clear contract);
//   * tile_last pulses exactly once, on the LAST tile (row-1,col-1),
//     co-incident with an acc_snap (the array drain contract);
//   * weights load BEFORE each tile's GEMM (load_done gates busy), which holds
//     implicitly when the full sequence completes.
//
// Proxies:
//   * weight streamer: on load_req, asserts load_done LOAD_LAT cycles later.
//   * activation streamer: while gemm.busy, drives beat_fire for k_cnt beats.
//
// Single clock, sync active-low reset.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_TB_DISPATCHER_LAYER_SV
`define ARCHBETTER_TB_DISPATCHER_LAYER_SV
`default_nettype none
`timescale 1ns/1ps

module tb_dispatcher_layer
    import types_pkg::*;
();

    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------
    localparam time T_CLK       = 10ns;
    localparam int  N_SOURCES   = 1;
    localparam int  IMEM_DEPTH  = 64;
    localparam int  IMEM_ADDR_W = $clog2(IMEM_DEPTH);

    localparam int  ROW_CNT  = int'(DENSE_LOGICAL_TILE_ROWS); // 8
    localparam int  COL_CNT  = int'(DENSE_LOGICAL_TILE_COLS); // 4
    localparam int  N_TILES  = ROW_CNT * COL_CNT;             // 32
    localparam int  K_TILE   = 2;                             // beats per tile
    localparam int  LOAD_LAT = 4;                             // weight-load latency

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    logic clk, rst_n;
    initial clk = 1'b0;
    always  #(T_CLK/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Interfaces
    // -------------------------------------------------------------------------
    noc_cfg_if    cfg_bus [N_SOURCES] (.clk(clk), .rst_n(rst_n));
    gemm_issue_if gemm_bus (.clk(clk), .rst_n(rst_n));
    tlmm_issue_if tlmm_bus (.clk(clk), .rst_n(rst_n));
    mem_issue_if  mem_if   (.clk(clk), .rst_n(rst_n));
    kv_access_if  kv_if    (.clk(clk), .rst_n(rst_n));
    dense_sched_if sched_bus (.clk(clk), .rst_n(rst_n));

    // Tie-offs for the channels this program never exercises.
    assign cfg_bus[0].cfg_ready = 1'b1;   // no OP_CFG_NOC
    assign tlmm_bus.done        = 1'b0;   // no OP_FFN_TLMM
    assign mem_if.done          = 1'b0;   // no memory ops
    assign kv_if.rd_data        = '0;
    assign kv_if.rd_valid       = 1'b0;

    // -------------------------------------------------------------------------
    // Dispatcher sidebands
    // -------------------------------------------------------------------------
    logic                     start;
    logic                     program_done;
    logic                     imem_we;
    logic [IMEM_ADDR_W-1:0]   imem_wr_addr;
    logic [MACRO_WORD_W-1:0]  imem_wr_data;
    logic [NOC_PATH_ID_W-1:0] path_id [N_SOURCES];

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    dispatcher #(
        .IMEM_DEPTH    (IMEM_DEPTH),
        .N_NOC_SOURCES (N_SOURCES)
    ) u_disp (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .program_done (program_done),
        .imem_we      (imem_we),
        .imem_wr_addr (imem_wr_addr),
        .imem_wr_data (imem_wr_data),
        .path_id_o    (path_id),
        .noc_cfg      (cfg_bus[0]),
        .gemm         (gemm_bus.disp),
        .tlmm         (tlmm_bus.disp),
        .sched        (sched_bus.walker),
        .mem_issue    (mem_if.disp),
        .kv           (kv_if.master),
        .kv_wr_data_i ('0),
        .dense_drain_busy (1'b0)
    );

    // -------------------------------------------------------------------------
    // Activation-streamer proxy: while gemm.busy, drive beat_fire for k_cnt
    // beats (one per cycle, no backpressure). Resets each tile when busy drops.
    // -------------------------------------------------------------------------
    int tile_beats_fired;
    always_ff @(posedge clk) begin
        if (!rst_n || !gemm_bus.busy) tile_beats_fired <= 0;
        else if (gemm_bus.beat_fire)  tile_beats_fired <= tile_beats_fired + 1;
    end
    assign gemm_bus.beat_fire = gemm_bus.busy
                              && (tile_beats_fired < int'(gemm_bus.k_cnt));

    // -------------------------------------------------------------------------
    // Weight-streamer proxy: on load_req, pulse load_done LOAD_LAT cycles later.
    // Also drives the (unused-here) scan bus to defined zeros.
    // -------------------------------------------------------------------------
    logic       load_done_r;
    logic       loading;
    int         load_timer;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            loading     <= 1'b0;
            load_done_r <= 1'b0;
            load_timer  <= 0;
        end else begin
            load_done_r <= 1'b0;  // default: 1-cycle pulse
            if (!loading && sched_bus.load_req) begin
                loading    <= 1'b1;
                load_timer <= LOAD_LAT;
            end else if (loading) begin
                if (load_timer == 0) begin
                    load_done_r <= 1'b1;
                    loading     <= 1'b0;
                end else begin
                    load_timer <= load_timer - 1;
                end
            end
        end
    end

    assign sched_bus.load_done = load_done_r;
    assign sched_bus.w_we      = 1'b0;
    assign sched_bus.w_phys_gc = '0;
    assign sched_bus.w_pe_addr = '0;
    assign sched_bus.w_in      = '0;

    // -------------------------------------------------------------------------
    // Scoreboard: capture the walker's emitted schedule.
    // -------------------------------------------------------------------------
    int n_load, n_acc_clr, n_acc_snap, n_tfirst, n_tlast;
    int seen_gr [$];
    int seen_gc [$];
    int tfirst_gr, tfirst_gc, tlast_gr, tlast_gc;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            n_load <= 0; n_acc_clr <= 0; n_acc_snap <= 0; n_tfirst <= 0; n_tlast <= 0;
        end else begin
            if (sched_bus.load_req) begin
                n_load <= n_load + 1;
                seen_gr.push_back(int'(sched_bus.tile_gr));
                seen_gc.push_back(int'(sched_bus.tile_gc));
            end
            if (gemm_bus.acc_clr)  n_acc_clr  <= n_acc_clr  + 1;
            if (gemm_bus.acc_snap) n_acc_snap <= n_acc_snap + 1;
            if (sched_bus.tile_first) begin
                n_tfirst  <= n_tfirst + 1;
                tfirst_gr <= int'(sched_bus.tile_gr);
                tfirst_gc <= int'(sched_bus.tile_gc);
            end
            if (sched_bus.tile_last) begin
                n_tlast  <= n_tlast + 1;
                tlast_gr <= int'(sched_bus.tile_gr);
                tlast_gc <= int'(sched_bus.tile_gc);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Scoreboard checks
    // -------------------------------------------------------------------------
    int n_checks = 0;
    int n_errors = 0;

    function automatic void check_eq(input int got, exp, input string label);
        n_checks++;
        if (got !== exp) begin
            n_errors++;
            $error("[%0t] %s: got=%0d exp=%0d", $time, label, got, exp);
        end
    endfunction

    // -------------------------------------------------------------------------
    // Instruction builders
    // -------------------------------------------------------------------------
    function automatic logic [MACRO_WORD_W-1:0] mk_gemm_layer(
        input logic [7:0] path_id_field,
        input int         row_cnt,
        input int         col_cnt,
        input int         k_cnt
    );
        logic [MACRO_WORD_W-1:0] w;
        w        = '0;
        w[63:58] = OP_GEMM_LAYER;
        w[49:42] = path_id_field;
        w[41:32] = row_cnt[9:0];
        w[31:22] = col_cnt[9:0];
        w[21:12] = k_cnt[9:0];
        return w;
    endfunction

    function automatic logic [MACRO_WORD_W-1:0] mk_eop();
        logic [MACRO_WORD_W-1:0] w;
        w        = '0;
        w[63:58] = OP_EOP;
        return w;
    endfunction

    task automatic imem_write(
        input logic [IMEM_ADDR_W-1:0]  addr,
        input logic [MACRO_WORD_W-1:0] word
    );
        @(posedge clk);
        imem_we      <= 1'b1;
        imem_wr_addr <= addr;
        imem_wr_data <= word;
        @(posedge clk);
        imem_we      <= 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin : main
        int waited;

        rst_n        = 1'b0;
        start        = 1'b0;
        imem_we      = 1'b0;
        imem_wr_addr = '0;
        imem_wr_data = '0;

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // Program: one full-grid OP_GEMM_LAYER, then EOP.
        imem_write(IMEM_ADDR_W'(0), mk_gemm_layer(8'h00, ROW_CNT, COL_CNT, K_TILE));
        imem_write(IMEM_ADDR_W'(1), mk_eop());

        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        waited = 0;
        while (!program_done) begin
            @(posedge clk);
            waited++;
            if (waited > 50_000)
                $fatal(1, "tb_dispatcher_layer: program_done never asserted");
        end
        repeat (4) @(posedge clk);

        // ---- Counts ----
        check_eq(n_load,     N_TILES, "load_req count");
        check_eq(n_acc_clr,  N_TILES, "acc_clr count");
        check_eq(n_acc_snap, N_TILES, "acc_snap count");
        check_eq(n_tfirst,   1,       "tile_first count");
        check_eq(n_tlast,    1,       "tile_last count");

        // ---- tile_first / tile_last coordinates ----
        check_eq(tfirst_gr, 0, "tile_first gr");
        check_eq(tfirst_gc, 0, "tile_first gc");
        check_eq(tlast_gr,  ROW_CNT - 1, "tile_last gr");
        check_eq(tlast_gc,  COL_CNT - 1, "tile_last gc");

        // ---- Raster order of the visited tiles ----
        check_eq(seen_gr.size(), N_TILES, "seen tiles size (gr)");
        check_eq(seen_gc.size(), N_TILES, "seen tiles size (gc)");
        if (seen_gr.size() == N_TILES) begin
            for (int i = 0; i < N_TILES; i++) begin
                check_eq(seen_gr[i], i / COL_CNT, $sformatf("tile[%0d].gr", i));
                check_eq(seen_gc[i], i % COL_CNT, $sformatf("tile[%0d].gc", i));
            end
        end

        if (n_errors == 0 && n_checks > 0) begin
            $display("=========================================================");
            $display(" tb_dispatcher_layer: PASS  (%0d checks, 0 errors)", n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_dispatcher_layer: FAIL  (%0d checks, %0d errors)",
                     n_checks, n_errors);
            $display("=========================================================");
        end
        $finish;
    end

    initial begin : watchdog
        #(T_CLK * 200_000);
        $fatal(1, "tb_dispatcher_layer: watchdog timeout");
    end

endmodule : tb_dispatcher_layer

`default_nettype wire
`endif // ARCHBETTER_TB_DISPATCHER_LAYER_SV
