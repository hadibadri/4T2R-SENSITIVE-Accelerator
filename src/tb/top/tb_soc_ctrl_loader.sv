// -----------------------------------------------------------------------------
// tb_soc_ctrl_loader.sv  (C3 — narrow control/loader unit test)
//
// Drives the narrow 32-bit cfg port and checks the wide fan-out to the core:
//   * an imem program streams correctly ({HI,LO} packing + auto-increment addr),
//   * a CSD descriptor table streams correctly (62-bit pack + auto-increment),
//   * all five URAM base-address registers latch,
//   * CTRL bit0 produces exactly one `start` pulse,
//   * STATUS reads back program_done.
// imem_we / desc_we commit pulses are captured by monitors into logs and then
// bit-compared against the expected sequence (robust to commit timing).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_soc_ctrl_loader;
    import types_pkg::*;

    localparam time         T_CLK       = 10ns;
    localparam int unsigned IMEM_DEPTH  = 64;
    localparam int unsigned IMEM_ADDR_W = $clog2(IMEM_DEPTH);
    localparam int unsigned DESC_W      = $bits(csd_descriptor_t);  // 62

    logic clk, rst_n;
    initial clk = 1'b0;
    always #(T_CLK/2) clk = ~clk;

    // -- cfg port + DUT outputs ----------------------------------------------
    logic                    cfg_we;
    logic [7:0]              cfg_addr;
    logic [31:0]             cfg_wdata;
    logic [31:0]             cfg_rdata;

    logic                    start;
    logic                    imem_we;
    logic [IMEM_ADDR_W-1:0]  imem_wr_addr;
    logic [MACRO_WORD_W-1:0] imem_wr_data;
    logic                    desc_we;
    logic [7:0]              desc_wr_addr;
    csd_descriptor_t         desc_wr_data;
    logic [URAM_ADDR_W-1:0]  base_dw, base_da, base_tl, base_oc, base_so;
    logic                    program_done;

    soc_ctrl_loader #(.IMEM_DEPTH(IMEM_DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .cfg_rdata(cfg_rdata),
        .start(start),
        .imem_we(imem_we), .imem_wr_addr(imem_wr_addr), .imem_wr_data(imem_wr_data),
        .desc_we(desc_we), .desc_wr_addr(desc_wr_addr), .desc_wr_data(desc_wr_data),
        .dense_weight_base_addr(base_dw), .dense_act_base_addr(base_da),
        .tlmm_base_addr(base_tl), .out_collector_base_addr(base_oc),
        .sparse_out_base_addr(base_so),
        .program_done(program_done)
    );

    // Register-map addresses (mirror the DUT).
    localparam logic [7:0] A_CTRL=8'h00, A_STATUS=8'h04, A_IMEM_ADDR=8'h10,
        A_IMEM_LO=8'h14, A_IMEM_HI=8'h18, A_DESC_ADDR=8'h20, A_DESC_LO=8'h24,
        A_DESC_HI=8'h28, A_BASE_DW=8'h30, A_BASE_DA=8'h34, A_BASE_TL=8'h38,
        A_BASE_OC=8'h3C, A_BASE_SO=8'h40;

    // -- Scoreboard ----------------------------------------------------------
    int unsigned n_checks, n_errors;
    function automatic void chk(input bit cond, input string msg);
        n_checks++;
        if (!cond) begin n_errors++; $error("tb_soc_ctrl_loader: FAIL — %s", msg); end
    endfunction

    // -- Monitors: log every commit pulse ------------------------------------
    localparam int unsigned LOGN = 64;
    logic [MACRO_WORD_W-1:0] imem_log_d [LOGN];
    logic [IMEM_ADDR_W-1:0]  imem_log_a [LOGN];
    int unsigned             imem_n;
    csd_descriptor_t         desc_log_d [LOGN];
    logic [7:0]              desc_log_a [LOGN];
    int unsigned             desc_n;
    int unsigned             start_pulses;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            imem_n <= 0; desc_n <= 0; start_pulses <= 0;
        end else begin
            if (imem_we) begin imem_log_d[imem_n] <= imem_wr_data;
                               imem_log_a[imem_n] <= imem_wr_addr; imem_n <= imem_n + 1; end
            if (desc_we) begin desc_log_d[desc_n] <= desc_wr_data;
                               desc_log_a[desc_n] <= desc_wr_addr; desc_n <= desc_n + 1; end
            if (start)   start_pulses <= start_pulses + 1;
        end
    end

    // -- cfg write helper ----------------------------------------------------
    task automatic cfg_w(input logic [7:0] a, input logic [31:0] d);
        @(negedge clk); cfg_we = 1'b1; cfg_addr = a; cfg_wdata = d;
        @(negedge clk); cfg_we = 1'b0;
    endtask

    // -- Expected reference data ---------------------------------------------
    localparam int unsigned N_IMEM = 6;
    localparam int unsigned N_DESC = 3;
    logic [MACRO_WORD_W-1:0] exp_imem [N_IMEM];
    csd_descriptor_t         exp_desc [N_DESC];

    initial begin : main
        n_checks = 0; n_errors = 0;
        cfg_we = 1'b0; cfg_addr = '0; cfg_wdata = '0; program_done = 1'b0;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---- Build reference vectors --------------------------------------
        for (int i = 0; i < int'(N_IMEM); i++)
            exp_imem[i] = { 32'(32'hDEAD_0000 + i), 32'(32'hBEEF_1000 + i) };
        for (int i = 0; i < int'(N_DESC); i++) begin
            exp_desc[i].compressed = 1'b0;
            exp_desc[i].is_sparse  = (i[0]);
            exp_desc[i].uram_base  = URAM_ADDR_W'(16 * i);
            exp_desc[i].dram_base  = DRAM_ADDR_W'(32'h1000_0000 + 32'h1000 * i);
            exp_desc[i].n_beats    = DRAM_LEN_W'(64 + i);
        end

        // ---- Stream the imem program (set ADDR=0, then {LO,HI} per word) ---
        cfg_w(A_IMEM_ADDR, 32'd0);
        for (int i = 0; i < int'(N_IMEM); i++) begin
            cfg_w(A_IMEM_LO, exp_imem[i][31:0]);
            cfg_w(A_IMEM_HI, exp_imem[i][63:32]);
        end

        // ---- Stream the descriptor table ----------------------------------
        cfg_w(A_DESC_ADDR, 32'd0);
        for (int i = 0; i < int'(N_DESC); i++) begin
            automatic logic [DESC_W-1:0] dv = exp_desc[i];
            cfg_w(A_DESC_LO, dv[31:0]);
            cfg_w(A_DESC_HI, 32'(dv[DESC_W-1:32]));
        end

        // ---- Base addresses -----------------------------------------------
        cfg_w(A_BASE_DW, 32'd11);
        cfg_w(A_BASE_DA, 32'd22);
        cfg_w(A_BASE_TL, 32'd33);
        cfg_w(A_BASE_OC, 32'd44);
        cfg_w(A_BASE_SO, 32'd55);

        // ---- start pulse ---------------------------------------------------
        cfg_w(A_CTRL, 32'h1);

        repeat (4) @(posedge clk);

        // ---- Checks --------------------------------------------------------
        chk(imem_n == N_IMEM, $sformatf("imem commits: got %0d exp %0d", imem_n, N_IMEM));
        for (int i = 0; i < int'(N_IMEM); i++) begin
            chk(imem_log_d[i] === exp_imem[i],
                $sformatf("imem[%0d] data: got %h exp %h", i, imem_log_d[i], exp_imem[i]));
            chk(imem_log_a[i] === IMEM_ADDR_W'(i),
                $sformatf("imem[%0d] addr: got %0d exp %0d", i, imem_log_a[i], i));
        end

        chk(desc_n == N_DESC, $sformatf("desc commits: got %0d exp %0d", desc_n, N_DESC));
        for (int i = 0; i < int'(N_DESC); i++) begin
            chk(desc_log_d[i] === exp_desc[i],
                $sformatf("desc[%0d]: got %h exp %h", i, desc_log_d[i], exp_desc[i]));
            chk(desc_log_a[i] === 8'(i),
                $sformatf("desc[%0d] addr: got %0d exp %0d", i, desc_log_a[i], i));
        end

        chk(base_dw === URAM_ADDR_W'(11), "base_dw");
        chk(base_da === URAM_ADDR_W'(22), "base_da");
        chk(base_tl === URAM_ADDR_W'(33), "base_tl");
        chk(base_oc === URAM_ADDR_W'(44), "base_oc");
        chk(base_so === URAM_ADDR_W'(55), "base_so");

        chk(start_pulses == 1, $sformatf("start pulses: got %0d exp 1", start_pulses));

        // ---- STATUS readback ----------------------------------------------
        program_done = 1'b1;
        @(negedge clk); cfg_addr = A_STATUS;
        #1; chk(cfg_rdata[0] === 1'b1, "STATUS.program_done should read 1");
        @(negedge clk); cfg_addr = A_CTRL;
        #1; chk(cfg_rdata === 32'b0, "non-STATUS read should be 0");

        repeat (2) @(posedge clk);
        if (n_errors == 0) $display("tb_soc_ctrl_loader: PASS  (%0d checks, 0 errors)", n_checks);
        else               $display("tb_soc_ctrl_loader: FAIL  (%0d errors / %0d checks)", n_errors, n_checks);
        $finish;
    end

    initial begin : watchdog
        #(T_CLK * 50_000);
        $fatal(1, "tb_soc_ctrl_loader: watchdog timeout");
    end

endmodule : tb_soc_ctrl_loader

`default_nettype wire
