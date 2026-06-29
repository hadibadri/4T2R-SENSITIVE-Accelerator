// -----------------------------------------------------------------------------
// tb_dispatcher_batch_cont.sv  (R6.4)
//
// Control-plane unit testbench for the dispatcher's CONTINUOUS (v2) OP_GEMM_BATCH
// path (opt-in via FLG_GEMM_CONTINUOUS). Like tb_dispatcher_layer, this checks the
// SEQUENCE the walker emits, not datapath values (the continuous datapath is
// proven bit-exact at the array level by tb_dense_array T5). The TB proxies the
// weight streamer (load_done LOAD_LAT after load_req) and the activation streamer,
// and scoreboards the continuous contract:
//
//   * the walker visits every tile of the row_cnt x col_cnt grid once, raster
//     order (gc fastest), one load_req per tile;
//   * each resident tile streams exactly T token-beats at II=1;
//   * acc_clr fires on EVERY beat (per-beat K=1 LOAD), so n_acc_clr = T * N_TILES;
//   * acc_snap NEVER fires (continuous snaps inside the array on the cell valid);
//   * tile_first pulses once, on tile (0,0)'s first beat (bank clear);
//   * tile_last pulses once, on the LAST tile's LAST beat (drain trigger);
//   * stream_mode is CONTINUOUS throughout the op.
//
// Activation proxy: in continuous the dispatcher holds gemm.busy high for the
// whole T-beat run of a tile and drops it (S_GEMM_CFLUSH) after the T-th beat, so
// the proxy simply streams a beat every cycle busy is high — the dispatcher meters
// the count to exactly T per tile.
//
// Single clock, sync active-low reset.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_TB_DISPATCHER_BATCH_CONT_SV
`define ARCHBETTER_TB_DISPATCHER_BATCH_CONT_SV
`default_nettype none
`timescale 1ns/1ps

module tb_dispatcher_batch_cont
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
    localparam int  T_TOK    = 4;                             // tokens per tile (T)
    localparam int  K_TILE   = 1;                             // k_cnt (K=1 per token)
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

    assign cfg_bus[0].cfg_ready = 1'b1;
    assign tlmm_bus.done        = 1'b0;
    assign mem_if.done          = 1'b0;
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
    // Activation-streamer proxy (continuous): stream one beat every cycle busy is
    // high. The dispatcher meters the count to exactly T per tile (it drops busy
    // into S_GEMM_CFLUSH after the T-th beat).
    // -------------------------------------------------------------------------
    assign gemm_bus.beat_fire = gemm_bus.busy;

    // -------------------------------------------------------------------------
    // Weight-streamer proxy: on load_req, pulse load_done LOAD_LAT cycles later.
    // -------------------------------------------------------------------------
    logic load_done_r;
    logic loading;
    int   load_timer;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            loading     <= 1'b0;
            load_done_r <= 1'b0;
            load_timer  <= 0;
        end else begin
            load_done_r <= 1'b0;
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
    // Scoreboard
    // -------------------------------------------------------------------------
    int n_load, n_beats, n_acc_clr, n_acc_snap, n_tfirst, n_tlast;
    int seen_gr [$];
    int seen_gc [$];
    int tile_beats [$];     // beats observed per tile (one entry per retired tile)
    int cur_tile_beats;
    int tfirst_gr, tfirst_gc, tlast_gr, tlast_gc;
    logic mode_ok;          // 0 if stream_mode ever != CONTINUOUS while busy

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            n_load <= 0; n_beats <= 0; n_acc_clr <= 0; n_acc_snap <= 0;
            n_tfirst <= 0; n_tlast <= 0; cur_tile_beats <= 0; mode_ok <= 1'b1;
        end else begin
            if (sched_bus.load_req) begin
                // A new tile's load starts: retire the previous tile's beat count.
                if (n_load > 0) tile_beats.push_back(cur_tile_beats);
                cur_tile_beats <= 0;
                n_load <= n_load + 1;
                seen_gr.push_back(int'(sched_bus.tile_gr));
                seen_gc.push_back(int'(sched_bus.tile_gc));
            end
            if (gemm_bus.beat_fire) begin
                n_beats        <= n_beats + 1;
                cur_tile_beats <= (sched_bus.load_req) ? 1 : cur_tile_beats + 1;
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
            // While busy (streaming a tile), the mode must be CONTINUOUS.
            if (gemm_bus.busy && (sched_bus.stream_mode != GEMM_SNAP_CONTINUOUS))
                mode_ok <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Checks
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
    function automatic logic [MACRO_WORD_W-1:0] mk_gemm_batch_cont(
        input logic [7:0] path_id_field,
        input int         row_cnt,
        input int         col_cnt,
        input int         k_cnt,
        input int         t_tok
    );
        logic [MACRO_WORD_W-1:0] w;
        w        = '0;
        w[63:58] = OP_GEMM_BATCH;
        w[57:50] = t_tok[7:0];              // tile_id field carries T
        w[49:42] = path_id_field;
        w[41:32] = row_cnt[9:0];
        w[31:22] = col_cnt[9:0];
        w[21:12] = k_cnt[9:0];
        w[FLG_GEMM_CONTINUOUS] = 1'b1;      // opt-in continuous (v2)
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

        // Program: one continuous full-grid OP_GEMM_BATCH (T tokens), then EOP.
        imem_write(IMEM_ADDR_W'(0),
                   mk_gemm_batch_cont(8'h00, ROW_CNT, COL_CNT, K_TILE, T_TOK));
        imem_write(IMEM_ADDR_W'(1), mk_eop());

        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        waited = 0;
        while (!program_done) begin
            @(posedge clk);
            waited++;
            if (waited > 100_000)
                $fatal(1, "tb_dispatcher_batch_cont: program_done never asserted");
        end
        repeat (4) @(posedge clk);

        // Retire the final tile's beat count (no load_req follows it).
        tile_beats.push_back(cur_tile_beats);

        // ---- Counts ----
        check_eq(n_load,     N_TILES,           "load_req count");
        check_eq(n_beats,    T_TOK * N_TILES,   "total beat count");
        check_eq(n_acc_clr,  T_TOK * N_TILES,   "acc_clr count (every beat)");
        check_eq(n_acc_snap, 0,                 "acc_snap count (none in continuous)");
        check_eq(n_tfirst,   1,                 "tile_first count");
        check_eq(n_tlast,    1,                 "tile_last count");
        check_eq(mode_ok ? 1 : 0, 1,            "stream_mode CONTINUOUS while busy");

        // ---- tile_first / tile_last coordinates ----
        check_eq(tfirst_gr, 0,           "tile_first gr");
        check_eq(tfirst_gc, 0,           "tile_first gc");
        check_eq(tlast_gr,  ROW_CNT - 1, "tile_last gr");
        check_eq(tlast_gc,  COL_CNT - 1, "tile_last gc");

        // ---- Per-tile beat count == T ----
        check_eq(tile_beats.size(), N_TILES, "per-tile beat samples");
        for (int i = 0; i < tile_beats.size(); i++)
            check_eq(tile_beats[i], T_TOK, $sformatf("tile[%0d] beats", i));

        // ---- Raster order of visited tiles ----
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
            $display(" tb_dispatcher_batch_cont: PASS  (%0d checks, 0 errors)", n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_dispatcher_batch_cont: FAIL  (%0d checks, %0d errors)",
                     n_checks, n_errors);
            $display("=========================================================");
        end
        $finish;
    end

    initial begin : watchdog
        #(T_CLK * 400_000);
        $fatal(1, "tb_dispatcher_batch_cont: watchdog timeout");
    end

endmodule : tb_dispatcher_batch_cont

`default_nettype wire
`endif // ARCHBETTER_TB_DISPATCHER_BATCH_CONT_SV
