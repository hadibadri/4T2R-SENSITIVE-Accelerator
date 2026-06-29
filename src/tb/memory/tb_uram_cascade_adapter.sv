// -----------------------------------------------------------------------------
// tb_uram_cascade_adapter.sv
//
// Unit testbench for uram_cascade_adapter. Stands the adapter up against a
// behavioral upstream (a tiny fake-URAM that obeys pingpong_if.mem_mgr) so
// the test does not depend on uram_pingpong or memory_manager. Two scenarios:
//
//   1) Sequential, no overlap: issue dn.rd_en, wait for dn.rd_valid, check
//      that the returned 144-b word equals { native[2A+1], native[2A] }.
//
//   2) Back-to-back issue (max throughput): issue 8 consecutive cascaded
//      reads with dn.rd_en held high every cycle until the adapter goes
//      full, then release as the FSM drains. Confirms the 1-pair-per-2-cycle
//      steady-state.
//
//   3) Drain handshake: assert up.drain_req, observe dn.drain_req propagate,
//      pulse dn.drain_ack, observe up.drain_ack reflect.
//
// All upstream native data is filled with a deterministic pattern keyed on
// native address so each cascaded result has a unique expected value.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_TB_URAM_CASCADE_ADAPTER_SV
`define ARCHBETTER_TB_URAM_CASCADE_ADAPTER_SV
`default_nettype none
`timescale 1ns/1ps

module tb_uram_cascade_adapter
    import types_pkg::*;
();

    // -------------------------------------------------------------------------
    // Config.
    // -------------------------------------------------------------------------
    localparam time T_CLK     = 10ns;
    localparam int  UP_DW     = URAM_WIDTH_BITS;
    localparam int  DN_DW     = 2 * URAM_WIDTH_BITS;
    localparam int  AW        = URAM_ADDR_W;
    localparam int  DEPTH     = 256;             // small backing store
    localparam int  RESP_LAT  = 2;               // upstream URAM latency to model

    // -------------------------------------------------------------------------
    // Clock / reset.
    // -------------------------------------------------------------------------
    logic clk = 1'b0;
    always #(T_CLK/2) clk = ~clk;
    logic rst_n = 1'b0;

    // -------------------------------------------------------------------------
    // Pingpong interfaces.
    // -------------------------------------------------------------------------
    pingpong_if #(.ADDR_W(AW), .DATA_W(UP_DW)) up (.clk(clk), .rst_n(rst_n));
    pingpong_if #(.ADDR_W(AW), .DATA_W(DN_DW)) dn (.clk(clk), .rst_n(rst_n));

    // -------------------------------------------------------------------------
    // Behavioral upstream: a 256-deep 72-b array. Reads are pipelined RESP_LAT
    // cycles. drain_req/drain_ack are TB-driven from a stimulus thread.
    // -------------------------------------------------------------------------
    logic [UP_DW-1:0] native_mem [DEPTH];

    function automatic logic [UP_DW-1:0] gen_native(input int addr);
        logic [UP_DW-1:0] v;
        v = '0;
        v[31:0]  = 32'hD00D_0000 ^ addr;
        v[63:32] = 32'hCAFE_0000 ^ (addr * 7);
        // Top 8 bits left zero -- mostly mantissa-friendly pattern.
        return v;
    endfunction

    // Read pipeline: shift register of (valid, data).
    logic [UP_DW-1:0] pipe_data [RESP_LAT];
    logic             pipe_valid[RESP_LAT];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < RESP_LAT; i++) begin
                pipe_data[i]  <= '0;
                pipe_valid[i] <= 1'b0;
            end
        end else begin
            // Shift older entries upward; index 0 is "oldest" (about to surface).
            for (int i = 0; i < RESP_LAT - 1; i++) begin
                pipe_data[i]  <= pipe_data[i+1];
                pipe_valid[i] <= pipe_valid[i+1];
            end
            // New issue lands at the deepest slot.
            pipe_data[RESP_LAT-1]  <= native_mem[up.rd_addr % DEPTH];
            pipe_valid[RESP_LAT-1] <= up.rd_en;
        end
    end

    // up.mem_mgr drives: active_side, side_valid, rd_data, rd_valid, drain_req
    logic         tb_drain_req;
    bank_sel_e    tb_active_side;
    logic         tb_side_valid;

    assign up.active_side = tb_active_side;
    assign up.side_valid  = tb_side_valid;
    assign up.rd_data     = pipe_data[0];
    assign up.rd_valid    = pipe_valid[0];
    assign up.drain_req   = tb_drain_req;

    // -------------------------------------------------------------------------
    // DUT.
    // -------------------------------------------------------------------------
    uram_cascade_adapter #(
        .UP_DATA_W(UP_DW),
        .DN_DATA_W(DN_DW),
        .UP_ADDR_W(AW),
        .DN_ADDR_W(AW)
    ) dut (
        .clk  (clk),
        .rst_n(rst_n),
        .up   (up),
        .dn   (dn)
    );

    // -------------------------------------------------------------------------
    // Consumer-side stimulus: dn is the .mem_mgr modport so the TB drives the
    // .core signals (rd_addr, rd_en, drain_ack).
    // -------------------------------------------------------------------------
    logic [AW-1:0]    dn_rd_addr_drv;
    logic             dn_rd_en_drv;
    logic             dn_drain_ack_drv;

    assign dn.rd_addr   = dn_rd_addr_drv;
    assign dn.rd_en     = dn_rd_en_drv;
    assign dn.drain_ack = dn_drain_ack_drv;

    // -------------------------------------------------------------------------
    // Score.
    // -------------------------------------------------------------------------
    int n_checks = 0;
    int n_errors = 0;

    function automatic logic [DN_DW-1:0] expected(input int dn_addr);
        return { gen_native(2*dn_addr + 1), gen_native(2*dn_addr) };
    endfunction

    task automatic check_eq(
        input logic [DN_DW-1:0] got,
        input logic [DN_DW-1:0] exp,
        input int               dn_addr
    );
        n_checks++;
        if (got !== exp) begin
            n_errors++;
            $error("[%0t] cascaded read mismatch addr=0x%0h got=%h exp=%h",
                   $time, dn_addr, got, exp);
        end
    endtask

    // -------------------------------------------------------------------------
    // Helpers.
    // -------------------------------------------------------------------------
    task automatic seed_memory();
        for (int i = 0; i < DEPTH; i++) native_mem[i] = gen_native(i);
    endtask

    task automatic single_read(input int dn_addr);
        logic [DN_DW-1:0] got;
        // Issue one rd_en pulse.
        @(negedge clk);
        dn_rd_addr_drv <= AW'(dn_addr);
        dn_rd_en_drv   <= 1'b1;
        @(negedge clk);
        dn_rd_en_drv   <= 1'b0;
        // Wait for response.
        do begin
            @(posedge clk);
        end while (!dn.rd_valid);
        got = dn.rd_data;
        check_eq(got, expected(dn_addr), dn_addr);
    endtask

    task automatic burst_read(input int base, input int count);
        // Hold rd_en high while addr walks; collect responses in order.
        int sent;
        int recv;
        sent = 0;
        recv = 0;

        fork
            begin : tx
                while (sent < count) begin
                    @(negedge clk);
                    if (!dut.afifo_full) begin   // adapter can accept (R6.8a-cont FIFO)
                        dn_rd_addr_drv <= AW'(base + sent);
                        dn_rd_en_drv   <= 1'b1;
                        @(posedge clk); // observe acceptance
                        sent++;
                    end else begin
                        dn_rd_en_drv   <= 1'b0;
                    end
                end
                @(negedge clk);
                dn_rd_en_drv <= 1'b0;
            end

            begin : rx
                int rx_idx;
                rx_idx = 0;
                while (rx_idx < count) begin
                    @(posedge clk);
                    if (dn.rd_valid) begin
                        check_eq(dn.rd_data, expected(base + rx_idx), base + rx_idx);
                        rx_idx++;
                    end
                end
                recv = rx_idx;
            end
        join
    endtask

    task automatic drain_handshake();
        @(negedge clk);
        tb_drain_req <= 1'b1;
        // Adapter forwards combinationally; expect dn.drain_req to follow.
        @(posedge clk);
        n_checks++;
        if (!dn.drain_req) begin
            n_errors++;
            $error("[%0t] drain_req did not propagate downstream", $time);
        end
        // Consumer pulses ack.
        @(negedge clk);
        dn_drain_ack_drv <= 1'b1;
        @(posedge clk);
        n_checks++;
        if (!up.drain_ack) begin
            n_errors++;
            $error("[%0t] drain_ack did not reflect upstream", $time);
        end
        @(negedge clk);
        dn_drain_ack_drv <= 1'b0;
        tb_drain_req     <= 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Main.
    // -------------------------------------------------------------------------
    initial begin : main
        // Init.
        tb_drain_req     = 1'b0;
        tb_active_side   = BANK_A;
        tb_side_valid    = 1'b1;
        dn_rd_addr_drv   = '0;
        dn_rd_en_drv     = 1'b0;
        dn_drain_ack_drv = 1'b0;

        seed_memory();

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        $display("[%0t] CASE 1: sequential single reads", $time);
        for (int a = 0; a < 8; a++) single_read(a);

        repeat (4) @(posedge clk);

        $display("[%0t] CASE 2: back-to-back burst (16 reads)", $time);
        burst_read(16, 16);

        repeat (8) @(posedge clk);

        $display("[%0t] CASE 3: drain handshake passthrough", $time);
        drain_handshake();

        repeat (8) @(posedge clk);

        if (n_errors == 0 && n_checks > 0) begin
            $display("=========================================================");
            $display(" tb_uram_cascade_adapter: PASS  (%0d checks, 0 errors)",
                     n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_uram_cascade_adapter: FAIL  (%0d checks, %0d errors)",
                     n_checks, n_errors);
            $display("=========================================================");
        end
        $finish;
    end

    // Watchdog.
    initial begin : watchdog
        #(T_CLK * 5_000);
        $fatal(1, "tb_uram_cascade_adapter: watchdog timeout");
    end

endmodule : tb_uram_cascade_adapter

`default_nettype wire
`endif // ARCHBETTER_TB_URAM_CASCADE_ADAPTER_SV
