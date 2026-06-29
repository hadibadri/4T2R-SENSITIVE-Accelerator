// -----------------------------------------------------------------------------
// tb_archbetter_ku5p_top.sv  (C5 — real-MMCM smoke test for the closure top)
//
// A LIGHTWEIGHT smoke test of archbetter_ku5p_top with the REAL MMCME4_ADV
// (SIM_CLOCK_BYPASS=0) — the path the C3 functional TB never exercised (it used
// the clock bypass). It proves, cheaply and before the long non-OOC synth run:
//   * the MMCM locks (locked_o rises),
//   * the xpm reset synchronizers release cleanly,
//   * the narrow cfg loader + dispatcher run on the MMCM-generated compute clock,
//   * a trivial program (NOP; EOP) reaches program_done.
//
// It is NOT a data test — the BRAM backend aliases regions, and full-layer data
// correctness is proven against the behavioral model (tb_archbetter_soc_top).
// This TB issues NO DRAM ops, so the BRAM slave stays idle.
//
// cfg is driven on the MMCM-generated compute clock (compute_clk_o), NOT clk_in:
// the loader samples cfg on the 250 MHz compute clock, so a value held for a
// 100 MHz clk_in period would be sampled multiple times. Wait for lock first,
// then time cfg to compute_clk_o.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_archbetter_ku5p_top;
    import types_pkg::*;

    localparam time T_CLK_IN = 10ns;   // 100 MHz board oscillator

    // cfg register map (mirrors soc_ctrl_loader).
    localparam logic [7:0] A_CTRL=8'h00, A_IMEM_ADDR=8'h10, A_IMEM_LO=8'h14, A_IMEM_HI=8'h18;

    logic clk_in, ext_rst_n;
    initial clk_in = 1'b0;
    always #(T_CLK_IN/2) clk_in = ~clk_in;

    logic        cfg_we;
    logic [7:0]  cfg_addr;
    logic [31:0] cfg_wdata, cfg_rdata;
    logic        program_done, locked_o;

    archbetter_ku5p_top #(
        .IMEM_DEPTH(64), .BATCH_T(8), .AXI_DATA_W(128), .AXI_ID_W(4), .MEM_DEPTH(2048)
    ) dut (
        .clk_in(clk_in), .ext_rst_n(ext_rst_n),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
        .cfg_rdata(cfg_rdata), .program_done(program_done), .locked_o(locked_o)
    );

    int unsigned n_checks, n_errors;
    function automatic void chk(input bit cond, input string msg);
        n_checks++;
        if (!cond) begin n_errors++; $error("tb_archbetter_ku5p_top: FAIL — %s", msg); end
    endfunction

    // Drive cfg on the MMCM-generated compute clock (one compute-clock period).
    task automatic cfg_w(input logic [7:0] a, input logic [31:0] d);
        @(negedge dut.compute_clk_w); cfg_we = 1'b1; cfg_addr = a; cfg_wdata = d;
        @(negedge dut.compute_clk_w); cfg_we = 1'b0;
    endtask

    // Trivial program: imem[0] = OP_NOP, imem[1] = OP_EOP.
    logic [MACRO_WORD_W-1:0] nop_w, eop_w;

    int waited;
    initial begin : main
        n_checks = 0; n_errors = 0;
        cfg_we = 1'b0; cfg_addr = '0; cfg_wdata = '0;
        ext_rst_n = 1'b0;

        nop_w = '0;                                  // OP_NOP = opc 0
        eop_w = '0; eop_w[63:58] = OP_EOP;           // OP_EOP at [63:58]

        repeat (20) @(posedge clk_in);
        ext_rst_n = 1'b1;

        // ---- Wait for the real MMCM to lock --------------------------------
        waited = 0;
        while (!locked_o) begin
            @(posedge clk_in); waited++;
            if (waited > 100_000) $fatal(1, "tb_archbetter_ku5p_top: MMCM never locked");
        end
        $display("[%0t] MMCM locked after %0d clk_in cycles", $time, waited);
        // Let the compute-domain reset sync release.
        repeat (16) @(posedge dut.compute_clk_w);

        // ---- Load the trivial program via cfg ------------------------------
        cfg_w(A_IMEM_ADDR, 32'd0);
        cfg_w(A_IMEM_LO, nop_w[31:0]);  cfg_w(A_IMEM_HI, nop_w[63:32]);   // imem[0]=NOP
        cfg_w(A_IMEM_LO, eop_w[31:0]);  cfg_w(A_IMEM_HI, eop_w[63:32]);   // imem[1]=EOP

        // ---- Start, wait for completion ------------------------------------
        cfg_w(A_CTRL, 32'h1);

        waited = 0;
        while (!program_done) begin
            @(posedge dut.compute_clk_w); waited++;
            if (waited > 50_000) $fatal(1, "tb_archbetter_ku5p_top: program_done never asserted");
        end
        $display("[%0t] program_done after %0d compute cycles", $time, waited);

        chk(locked_o     === 1'b1, "MMCM not locked at end");
        chk(program_done === 1'b1, "program_done not asserted");

        repeat (4) @(posedge dut.compute_clk_w);
        if (n_errors == 0) $display("tb_archbetter_ku5p_top: PASS  (%0d checks, 0 errors)", n_checks);
        else               $display("tb_archbetter_ku5p_top: FAIL  (%0d errors / %0d checks)", n_errors, n_checks);
        $finish;
    end

    initial begin : watchdog
        #(T_CLK_IN * 2_000_000);   // generous: real MMCM lock can take a while in sim
        $fatal(1, "tb_archbetter_ku5p_top: watchdog timeout");
    end

endmodule : tb_archbetter_ku5p_top

`default_nettype wire
