
`timescale 1ns/1ps
`default_nettype none

module tb_dense_weight_streamer;
    import types_pkg::*;
    localparam time CLK_PERIOD = 10ns;
    logic clk = 1'b0;
    logic rst_n;
    initial forever #(CLK_PERIOD/2) clk = ~clk;
    localparam int unsigned PP_DATA_W        = DENSE_PP_URAM_W;
    localparam int unsigned CASC_HALF_W      = PP_DATA_W / 2;
    localparam int unsigned MANT_HALF_W      = BFP12_BLK * BFP12_MANT_W / 2;
    localparam int unsigned WEIGHTS_PER_WORD = MANT_HALF_W / BFP12_MANT_W;
    localparam int unsigned TILE_PE_TOTAL    = DENSE_PHYS_GROUPS_COL * DENSE_PE_PER_GROUP;
    localparam int unsigned WORDS_PER_TILE   = TILE_PE_TOTAL / WEIGHTS_PER_WORD;
    localparam int unsigned PE_ADDR_W        = $clog2(DENSE_PE_PER_GROUP);
    localparam int unsigned PHYS_GC_W        = $clog2(DENSE_PHYS_GROUPS_COL);
    localparam int unsigned GLOBAL_W         = $clog2(TILE_PE_TOTAL);
    localparam int unsigned URAM_DEPTH_TB    = 4096;

    localparam int unsigned TGR_W = $clog2(DENSE_LOGICAL_TILE_ROWS);
    localparam int unsigned TGC_W = $clog2(DENSE_LOGICAL_TILE_COLS);
    dense_sched_if sched (clk, rst_n);
    pingpong_if #(.ADDR_W(URAM_ADDR_W), .DATA_W(PP_DATA_W)) pp (clk, rst_n);
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
    logic [TGR_W-1:0] wlk_tile_gr;
    logic [TGC_W-1:0] wlk_tile_gc;
    logic             wlk_load_req;
    logic             wlk_load_busy;

    assign sched.tile_gr    = wlk_tile_gr;
    assign sched.tile_gc    = wlk_tile_gc;
    assign sched.tile_first = 1'b0;
    assign sched.tile_last  = 1'b0;
    assign sched.load_req   = wlk_load_req;
    assign sched.load_busy  = wlk_load_busy;
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
    logic [BFP12_MANT_W-1:0] ref_w   [TILE_PE_TOTAL];
    logic [BFP12_MANT_W-1:0] got_w   [TILE_PE_TOTAL];
    logic                    got_seen[TILE_PE_TOTAL];
    int unsigned             scan_count;

    logic clr_capture;
    logic [GLOBAL_W-1:0] cap_idx;
    assign cap_idx = {sched.w_phys_gc, sched.w_pe_addr};
    always_ff @(posedge clk) begin
        if (!rst_n || clr_capture) begin
            for (int g = 0; g < int'(TILE_PE_TOTAL); g++) got_seen[g] <= 1'b0;
            scan_count <= 0;
        end else if (sched.w_we) begin
            for (int s = 0; s < int'(BFP12_BLK/2); s++) begin
                got_w[cap_idx + GLOBAL_W'(s)]    <= sched.w_in[s];
                got_seen[cap_idx + GLOBAL_W'(s)] <= 1'b1;
            end
            scan_count <= scan_count + (BFP12_BLK/2);
        end
    end
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
                2:       wv = g[0] ? 12'sh7FF : 12'sh800;
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
            mem_q[(tile_base + URAM_ADDR_W'(w)) >> 1][(w[0] ? CASC_HALF_W : 0) +: CASC_HALF_W] = wd;
        end
    endfunction
    task automatic run_tile(
        input logic [URAM_ADDR_W-1:0] base,
        input int                     gr,
        input int                     gc,
        input string                  label
    );
        @(posedge clk);
        base_addr   <= base;
        wlk_tile_gr <= TGR_W'(gr);
        wlk_tile_gc <= TGC_W'(gc);
        clr_capture <= 1'b1;
        @(posedge clk);
        clr_capture <= 1'b0;
        wlk_load_busy <= 1'b1;
        wlk_load_req  <= 1'b1;
        @(posedge clk);
        wlk_load_req  <= 1'b0;
        while (!sched.load_done) @(posedge clk);
        @(posedge clk);
        wlk_load_busy <= 1'b0;
        @(posedge clk);
        check_true(scan_count == TILE_PE_TOTAL,
                   $sformatf("%s scan_count==512 (got %0d)", label, scan_count));
        for (int g = 0; g < int'(TILE_PE_TOTAL); g++) begin
            check_true(got_seen[g], $sformatf("%s pe[%0d] seen", label, g));
            check_eq(got_w[g], ref_w[g], $sformatf("%s pe[%0d]", label, g));
        end
    endtask
    initial begin
        #500us;
        $fatal(1, "tb_dense_weight_streamer: watchdog timeout");
    end
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
        program_tile(URAM_ADDR_W'(0), 0, 0, 0, 12'h000);
        run_tile(URAM_ADDR_W'(0), 0, 0, "T1.ramp(0,0)");
        program_tile(URAM_ADDR_W'(0), 3, 2, 1, 12'h5A5);
        run_tile(URAM_ADDR_W'(0), 3, 2, "T2.const(3,2)");
        program_tile(URAM_ADDR_W'(0), 7, 3, 2, 12'h000);
        run_tile(URAM_ADDR_W'(0), 7, 3, "T3.sign(7,3)");
        program_tile(URAM_ADDR_W'(2048), 0, 0, 3, 12'h000);
        run_tile(URAM_ADDR_W'(2048), 0, 0, "T4.rand@2048(0,0)");
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
