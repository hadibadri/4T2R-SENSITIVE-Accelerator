// -----------------------------------------------------------------------------
// tb_csd_drain_engine.sv
//
// Phase-5e unit testbench for csd_drain_engine.
//
// Roles in the verification stack:
//   * memory_manager (descriptor master): we present desc + desc_valid and
//     watch desc_ready and done.
//   * URAM (output region): we provide a behavioural 2-cycle-latency read
//     port indexed by rd_addr_o; data is a deterministic function of address
//     so the comparator can predict the streamed beats.
//   * DRAM (write slave): we accept req_valid (with optional stalls) and
//     consume wd_valid (with optional backpressure). Captured beats land in
//     a queue that is checked against the URAM data predictor.
//
// What it covers:
//   T1  short descriptor (n_beats=4), no stalls.
//   T2  longer descriptor (n_beats=37), no stalls.
//   T3  full speed with random req_ready stalls.
//   T4  full speed with random wd_ready backpressure.
//   T5  random both sides, n_beats=128.
//   T6  back-to-back descriptors (sequential, no overlap).
//
// Assertions guarded by the engine itself fire on contract violations; this
// TB only checks data correctness and basic completion.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_csd_drain_engine;
    import types_pkg::*;

    // -------------------------------------------------------------------------
    // Clock / reset.
    // -------------------------------------------------------------------------
    localparam time CLK_PERIOD = 10ns;
    logic clk = 1'b0;
    logic rst_n;
    initial forever #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Geometry.
    // -------------------------------------------------------------------------
    localparam int unsigned URAM_DATA_W   = URAM_WIDTH_BITS;  // 72
    localparam int unsigned URAM_DEPTH_TB = 1024;             // shallow TB-only

    // Pattern function: data at URAM word `a` is { tag, addr<<3 } so the
    // received DRAM beat carries an address-derived signature.
    localparam logic [31:0] URAM_TAG = 32'hCAFE_BABE;

    // -------------------------------------------------------------------------
    // Interface.
    // -------------------------------------------------------------------------
    csd_dram_wr_if dram_wr (clk, rst_n);

    // Descriptor master.
    csd_descriptor_t desc_i;
    logic            desc_valid_i;
    logic            desc_ready_o;
    logic            done_o;

    // URAM read port (DUT outputs, TB inputs, with 2-cycle latency).
    logic                    rd_en_o;
    logic [URAM_ADDR_W-1:0]  rd_addr_o;
    logic                    rd_valid_i;
    logic [URAM_DATA_W-1:0]  rd_data_i;

    // -------------------------------------------------------------------------
    // DUT.
    // -------------------------------------------------------------------------
    csd_drain_engine #(.URAM_DATA_W(URAM_DATA_W)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .desc_i      (desc_i),
        .desc_valid_i(desc_valid_i),
        .desc_ready_o(desc_ready_o),
        .done_o      (done_o),
        .rd_en_o     (rd_en_o),
        .rd_addr_o   (rd_addr_o),
        .rd_valid_i  (rd_valid_i),
        .rd_data_i   (rd_data_i),
        .dram_wr     (dram_wr.mgr)
    );

    // -------------------------------------------------------------------------
    // Behavioural URAM. 2-cycle latency on rd_en. The TB pre-fills the
    // mem on init using the URAM_TAG pattern.
    // -------------------------------------------------------------------------
    function automatic logic [URAM_DATA_W-1:0] mk_word(input logic [URAM_ADDR_W-1:0] a);
        logic [URAM_DATA_W-1:0] w;
        w = '0;
        w[URAM_DATA_W-1 -: 32] = URAM_TAG;
        w[31:0]                = {{(32-URAM_ADDR_W){1'b0}}, a} ^ 32'hA5A5_5A5A;
        return w;
    endfunction

    logic [URAM_DATA_W-1:0] uram_mem [0:URAM_DEPTH_TB-1];

    // 2-cycle pipeline.
    logic [URAM_DATA_W-1:0] rd_data_s1, rd_data_s2;
    logic                   rd_valid_s1, rd_valid_s2;
    logic [URAM_ADDR_W-1:0] rd_addr_s1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_valid_s1 <= 1'b0;
            rd_valid_s2 <= 1'b0;
            rd_data_s1  <= '0;
            rd_data_s2  <= '0;
            rd_addr_s1  <= '0;
        end else begin
            // stage 1
            rd_valid_s1 <= rd_en_o;
            rd_addr_s1  <= rd_addr_o;
            if (rd_en_o) begin
                rd_data_s1 <= uram_mem[rd_addr_o[$clog2(URAM_DEPTH_TB)-1:0]];
            end
            // stage 2
            rd_valid_s2 <= rd_valid_s1;
            rd_data_s2  <= rd_data_s1;
        end
    end

    assign rd_valid_i = rd_valid_s2;
    assign rd_data_i  = rd_data_s2;

    // -------------------------------------------------------------------------
    // DRAM-write stub: random req_ready stall, random wd_ready backpressure.
    // -------------------------------------------------------------------------
    int unsigned req_ready_pct;
    int unsigned wd_ready_pct;

    logic stub_req_ready;
    logic stub_wd_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            stub_req_ready <= 1'b1;
            stub_wd_ready  <= 1'b1;
        end else begin
            stub_req_ready <= ($urandom_range(1, 100) <= req_ready_pct);
            stub_wd_ready  <= ($urandom_range(1, 100) <= wd_ready_pct);
        end
    end

    assign dram_wr.req_ready = stub_req_ready;
    assign dram_wr.wd_ready  = stub_wd_ready;

    // -------------------------------------------------------------------------
    // Beat capture queue.
    // -------------------------------------------------------------------------
    typedef struct {
        logic [URAM_DATA_W-1:0] data;
        logic                   last;
    } beat_t;
    beat_t beats [$];

    always_ff @(posedge clk) begin
        if (rst_n && dram_wr.wd_valid && dram_wr.wd_ready) begin
            beat_t b;
            b.data = dram_wr.wd_data;
            b.last = dram_wr.wd_last;
            beats.push_back(b);
        end
    end

    // -------------------------------------------------------------------------
    // Stats.
    // -------------------------------------------------------------------------
    int n_checks = 0;
    int n_errors = 0;

    function automatic csd_descriptor_t mk_desc(
        input logic [URAM_ADDR_W-1:0] uram_base,
        input logic [DRAM_ADDR_W-1:0] dram_base,
        input logic [DRAM_LEN_W-1:0]  n_beats);
        csd_descriptor_t d;
        d.compressed = 1'b0;
        d.is_sparse  = 1'b0;
        d.uram_base  = uram_base;
        d.dram_base  = dram_base;
        d.n_beats    = n_beats;
        return d;
    endfunction

    // -------------------------------------------------------------------------
    // Drive a single descriptor end-to-end; verify the captured beats match
    // mk_word(uram_base + i) for i in [0..n_beats-1] in order, with last on
    // the final beat.
    // -------------------------------------------------------------------------
    task automatic run_desc(input csd_descriptor_t d,
                             input string label);
        int unsigned saw_done_at;
        int unsigned wait_iters;

        beats.delete();

        @(negedge clk);
        desc_i       = d;
        desc_valid_i = 1'b1;
        // Wait for the engine to accept.
        wait (desc_ready_o === 1'b1);
        @(posedge clk);
        @(negedge clk);
        desc_valid_i = 1'b0;

        // Wait for done. 32 * n_beats clock cycles is a generous bound even
        // with both stub channels at 25%.
        saw_done_at = 0;
        wait_iters  = 0;
        while (saw_done_at == 0) begin
            @(posedge clk);
            if (done_o) saw_done_at = $time;
            wait_iters++;
            if (wait_iters > int'(d.n_beats) * 64 + 256) begin
                $error("%s: timeout waiting for done after %0d cycles",
                       label, wait_iters);
                n_errors++;
                return;
            end
        end

        // Validate beat count + content.
        n_checks++;
        if (beats.size() !== int'(d.n_beats)) begin
            n_errors++;
            $error("%s: expected %0d beats, got %0d",
                   label, d.n_beats, beats.size());
        end else begin
            for (int i = 0; i < int'(d.n_beats); i++) begin
                logic [URAM_DATA_W-1:0] exp_w;
                logic                   exp_last;
                exp_w    = mk_word(URAM_ADDR_W'(d.uram_base + URAM_ADDR_W'(i)));
                exp_last = (i == int'(d.n_beats) - 1);
                n_checks++;
                if (beats[i].data !== exp_w) begin
                    n_errors++;
                    $error("%s.beat[%0d] data: exp=0x%0h got=0x%0h",
                           label, i, exp_w, beats[i].data);
                end
                n_checks++;
                if (beats[i].last !== exp_last) begin
                    n_errors++;
                    $error("%s.beat[%0d] last: exp=%0b got=%0b",
                           label, i, exp_last, beats[i].last);
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Watchdog.
    // -------------------------------------------------------------------------
    initial begin
        #2ms;
        $fatal(1, "tb_csd_drain_engine: watchdog timeout");
    end

    // -------------------------------------------------------------------------
    // Main.
    // -------------------------------------------------------------------------
    initial begin
        rst_n         = 1'b0;
        desc_i        = '0;
        desc_valid_i  = 1'b0;
        req_ready_pct = 100;
        wd_ready_pct  = 100;

        // Pre-fill URAM mirror.
        for (int a = 0; a < URAM_DEPTH_TB; a++) begin
            uram_mem[a] = mk_word(URAM_ADDR_W'(a));
        end

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // T1 short descriptor, no stalls.
        req_ready_pct = 100; wd_ready_pct = 100;
        run_desc(mk_desc(URAM_ADDR_W'(12'h010),
                         32'h0000_8000,
                         16'd4),
                 "T1.short");

        // T2 longer descriptor.
        run_desc(mk_desc(URAM_ADDR_W'(12'h040),
                         32'h0001_0000,
                         16'd37),
                 "T2.long");

        // T3 random req_ready (drain harder to start).
        req_ready_pct = 30; wd_ready_pct = 100;
        run_desc(mk_desc(URAM_ADDR_W'(12'h080),
                         32'h0002_0000,
                         16'd64),
                 "T3.req_stalls");

        // T4 random wd_ready (saturates the skid).
        req_ready_pct = 100; wd_ready_pct = 30;
        run_desc(mk_desc(URAM_ADDR_W'(12'h100),
                         32'h0003_0000,
                         16'd64),
                 "T4.wd_backpressure");

        // T5 random both, deeper.
        req_ready_pct = 60; wd_ready_pct = 50;
        run_desc(mk_desc(URAM_ADDR_W'(12'h180),
                         32'h0004_0000,
                         16'd128),
                 "T5.rand_both");

        // T6 back-to-back. Engine must reset its counters cleanly.
        req_ready_pct = 100; wd_ready_pct = 100;
        run_desc(mk_desc(URAM_ADDR_W'(12'h200),
                         32'h0005_0000,
                         16'd16),
                 "T6a");
        run_desc(mk_desc(URAM_ADDR_W'(12'h220),
                         32'h0005_1000,
                         16'd24),
                 "T6b");

        repeat (8) @(posedge clk);
        $display("=========================================================");
        if (n_errors == 0) begin
            $display(" tb_csd_drain_engine: PASS  (%0d checks, 0 errors)", n_checks);
        end else begin
            $display(" tb_csd_drain_engine: FAIL  (%0d errors / %0d checks)",
                     n_errors, n_checks);
        end
        $display("=========================================================");
        $finish;
    end

endmodule : tb_csd_drain_engine

`default_nettype wire
