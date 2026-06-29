
`timescale 1ns/1ps
`default_nettype none

module tb_csd_engine;
    import types_pkg::*;
    localparam int unsigned URAM_DATA_W = URAM_WIDTH_BITS;
    localparam int unsigned MAX_BEATS   = 64;
    localparam int unsigned N_DESC      = 16;
    localparam logic [39:0] DRAM_PATTERN_HI = 40'hCA_FEBA_BECA;
    logic clk;
    logic rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;
    csd_descriptor_t       desc_i;
    logic                  desc_valid_i;
    logic                  desc_ready_o;
    logic                  done_o;

    csd_dram_if dram (.clk(clk), .rst_n(rst_n));

    logic                       fill_wr_en_o;
    logic [URAM_ADDR_W-1:0]     fill_wr_addr_o;
    logic [URAM_DATA_W-1:0]     fill_wr_data_o;
    logic                       fill_is_sparse_o;

    csd_engine #(
        .URAM_DATA_W(URAM_DATA_W)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .desc_i          (desc_i),
        .desc_valid_i    (desc_valid_i),
        .desc_ready_o    (desc_ready_o),
        .done_o          (done_o),
        .dram            (dram.mgr),
        .fill_wr_en_o    (fill_wr_en_o),
        .fill_wr_addr_o  (fill_wr_addr_o),
        .fill_wr_data_o  (fill_wr_data_o),
        .fill_is_sparse_o(fill_is_sparse_o)
    );
    int unsigned req_ready_stall_cycles;
    int unsigned rsp_throttle_period;

    typedef enum logic [1:0] {
        D_IDLE = 2'b00,
        D_REQ  = 2'b01,
        D_RESP = 2'b10
    } dram_state_e;

    dram_state_e            dram_state_q;
    logic [DRAM_ADDR_W-1:0] dram_addr_q;
    logic [DRAM_LEN_W-1:0]  dram_len_q;
    logic [DRAM_LEN_W-1:0]  dram_idx_q;
    int unsigned            req_stall_cnt;
    int unsigned            rsp_period_cnt;
    logic                   stub_req_ready;
    logic                   stub_rsp_valid;
    logic                   stub_rsp_last;
    logic [DRAM_BEAT_W-1:0] stub_rsp_data;

    always_comb begin
        stub_req_ready = 1'b0;
        stub_rsp_valid = 1'b0;
        stub_rsp_last  = 1'b0;
        stub_rsp_data  = '0;
        unique case (dram_state_q)
            D_IDLE: begin
                stub_req_ready = 1'b0;
            end
            D_REQ: begin
                stub_req_ready = (req_stall_cnt == 0);
            end
            D_RESP: begin
                stub_rsp_valid = (rsp_throttle_period == 0) || (rsp_period_cnt == 0);
                stub_rsp_last  = (dram_idx_q == DRAM_LEN_W'(dram_len_q - 1'b1));
                stub_rsp_data  = {DRAM_PATTERN_HI,
                                   DRAM_ADDR_W'(dram_addr_q + DRAM_ADDR_W'(dram_idx_q << 3))};
            end
            default: ;
        endcase
    end

    assign dram.req_ready = stub_req_ready;
    assign dram.rsp_valid = stub_rsp_valid;
    assign dram.rsp_last  = stub_rsp_last;
    assign dram.rsp_data  = stub_rsp_data;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dram_state_q   <= D_IDLE;
            dram_addr_q    <= '0;
            dram_len_q     <= '0;
            dram_idx_q     <= '0;
            req_stall_cnt  <= 0;
            rsp_period_cnt <= 0;
        end else begin
            unique case (dram_state_q)
                D_IDLE: begin
                    if (dram.req_valid) begin
                        dram_state_q  <= D_REQ;
                        req_stall_cnt <= req_ready_stall_cycles;
                    end
                end
                D_REQ: begin
                    if (req_stall_cnt != 0) begin
                        req_stall_cnt <= req_stall_cnt - 1;
                    end else if (dram.req_valid) begin
                        dram_addr_q    <= dram.req_addr;
                        dram_len_q     <= dram.req_len;
                        dram_idx_q     <= '0;
                        rsp_period_cnt <= rsp_throttle_period;
                        dram_state_q   <= D_RESP;
                    end
                end
                D_RESP: begin
                    if (rsp_throttle_period != 0) begin
                        if (rsp_period_cnt != 0) begin
                            rsp_period_cnt <= rsp_period_cnt - 1;
                        end else begin
                            if (dram.rsp_ready) begin
                                if (stub_rsp_last) begin
                                    dram_state_q <= D_IDLE;
                                end else begin
                                    dram_idx_q <= DRAM_LEN_W'(dram_idx_q + 1'b1);
                                end
                                rsp_period_cnt <= rsp_throttle_period;
                            end
                        end
                    end else begin
                        if (dram.rsp_ready && stub_rsp_valid) begin
                            if (stub_rsp_last) begin
                                dram_state_q <= D_IDLE;
                            end else begin
                                dram_idx_q <= DRAM_LEN_W'(dram_idx_q + 1'b1);
                            end
                        end
                    end
                end
                default: dram_state_q <= D_IDLE;
            endcase
        end
    end
    csd_descriptor_t expect_q;
    logic            expect_active;
    int unsigned     expect_idx;

    int unsigned checks    = 0;
    int unsigned errors    = 0;
    int unsigned tb_errors = 0;
    int unsigned descriptors_done = 0;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            expect_q         <= '0;
            expect_active    <= 1'b0;
            expect_idx       <= 0;
            descriptors_done <= 0;
        end else begin
            if (desc_valid_i && desc_ready_o) begin
                expect_q      <= desc_i;
                expect_active <= 1'b1;
                expect_idx    <= 0;
            end
            if (fill_wr_en_o) begin
                if (!expect_active) begin
                    tb_errors <= tb_errors + 1;
                    $display("[%0t] OBS: fill_wr_en with no active descriptor", $time);
                end else begin
                    automatic logic [URAM_ADDR_W-1:0] exp_addr;
                    automatic logic [URAM_DATA_W-1:0] exp_data;
                    exp_addr = URAM_ADDR_W'(expect_q.uram_base + URAM_ADDR_W'(expect_idx));
                    exp_data = {DRAM_PATTERN_HI,
                                DRAM_ADDR_W'(expect_q.dram_base + DRAM_ADDR_W'(expect_idx << 3))};
                    checks <= checks + 1;
                    if (fill_wr_addr_o !== exp_addr) begin
                        errors <= errors + 1;
                        $display("[%0t] FILL ADDR MISMATCH idx=%0d exp=0x%0h got=0x%0h",
                                 $time, expect_idx, exp_addr, fill_wr_addr_o);
                    end
                    if (fill_wr_data_o !== exp_data) begin
                        errors <= errors + 1;
                        $display("[%0t] FILL DATA MISMATCH idx=%0d exp=0x%0h got=0x%0h",
                                 $time, expect_idx, exp_data, fill_wr_data_o);
                    end
                    if (fill_is_sparse_o !== expect_q.is_sparse) begin
                        errors <= errors + 1;
                        $display("[%0t] FILL is_sparse MISMATCH exp=%0b got=%0b",
                                 $time, expect_q.is_sparse, fill_is_sparse_o);
                    end
                    expect_idx <= expect_idx + 1;
                end
            end
            if (done_o) begin
                if (!expect_active) begin
                    tb_errors <= tb_errors + 1;
                    $display("[%0t] OBS: done_o with no active descriptor", $time);
                end else if (expect_idx !== expect_q.n_beats) begin
                    tb_errors <= tb_errors + 1;
                    $display("[%0t] OBS: done_o with idx=%0d, expected %0d",
                             $time, expect_idx, expect_q.n_beats);
                end
                expect_active    <= 1'b0;
                descriptors_done <= descriptors_done + 1;
            end
        end
    end
    task automatic drive_idle();
        desc_i       <= '0;
        desc_valid_i <= 1'b0;
    endtask
    task automatic issue_desc(input csd_descriptor_t d);
        @(negedge clk);
        desc_i       = d;
        desc_valid_i = 1'b1;
        do begin
            @(posedge clk);
        end while (desc_ready_o !== 1'b1);
        @(negedge clk);
        desc_valid_i = 1'b0;
        desc_i       = '0;
        while (done_o !== 1'b1) @(posedge clk);
        @(posedge clk);
    endtask

    function automatic csd_descriptor_t mk_desc(
        input logic                    compressed,
        input logic                    is_sparse,
        input logic [URAM_ADDR_W-1:0]  uram_base,
        input logic [DRAM_ADDR_W-1:0]  dram_base,
        input logic [DRAM_LEN_W-1:0]   n_beats);
        csd_descriptor_t d;
        d.compressed = compressed;
        d.is_sparse  = is_sparse;
        d.uram_base  = uram_base;
        d.dram_base  = dram_base;
        d.n_beats    = n_beats;
        return d;
    endfunction
    always_ff @(posedge clk) begin
        if (rst_n && done_o && $past(done_o, 1)) begin
            tb_errors <= tb_errors + 1;
            $display("[%0t] done_o held high for >1 cycle", $time);
        end
    end
    initial begin : main
        req_ready_stall_cycles = 0;
        rsp_throttle_period    = 0;

        rst_n = 1'b0;
        drive_idle();
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        $display("[%0t] STAGE 0: reset quiescent", $time);
        if (desc_ready_o !== 1'b1) begin
            tb_errors++;
            $display("[%0t] STAGE 0 FAIL: desc_ready_o=%0b after reset (expected 1)",
                     $time, desc_ready_o);
        end
        if (done_o !== 1'b0 || fill_wr_en_o !== 1'b0
            || dram.req_valid !== 1'b0 || dram.rsp_ready !== 1'b0) begin
            tb_errors++;
            $display("[%0t] STAGE 0 FAIL: outputs not quiescent", $time);
        end
        $display("[%0t] STAGE 1: small dense descriptor (4 beats, no stalls)", $time);
        issue_desc(mk_desc(.compressed(1'b0), .is_sparse(1'b0),
                            .uram_base(12'h010), .dram_base(32'h0000_1000),
                            .n_beats(16'd4)));
        $display("[%0t] STAGE 2: small sparse descriptor (8 beats)", $time);
        issue_desc(mk_desc(.compressed(1'b0), .is_sparse(1'b1),
                            .uram_base(12'h040), .dram_base(32'h0000_2000),
                            .n_beats(16'd8)));
        $display("[%0t] STAGE 3: large descriptor (256 beats)", $time);
        issue_desc(mk_desc(.compressed(1'b0), .is_sparse(1'b0),
                            .uram_base(12'h100), .dram_base(32'h0001_0000),
                            .n_beats(16'd256)));
        $display("[%0t] STAGE 4: stub stalls req_ready for 5 cycles", $time);
        req_ready_stall_cycles = 5;
        rsp_throttle_period    = 0;
        issue_desc(mk_desc(.compressed(1'b0), .is_sparse(1'b0),
                            .uram_base(12'h200), .dram_base(32'h0002_0000),
                            .n_beats(16'd16)));
        req_ready_stall_cycles = 0;
        $display("[%0t] STAGE 5: stub throttles rsp_valid (period=3)", $time);
        rsp_throttle_period = 3;
        issue_desc(mk_desc(.compressed(1'b0), .is_sparse(1'b1),
                            .uram_base(12'h300), .dram_base(32'h0003_0000),
                            .n_beats(16'd16)));
        rsp_throttle_period = 0;
        $display("[%0t] STAGE 6: random %0d descriptors", $time, N_DESC);
        for (int i = 0; i < N_DESC; i++) begin
            csd_descriptor_t d;
            d = mk_desc(.compressed(1'b0),
                        .is_sparse($urandom_range(0, 1)),
                        .uram_base(URAM_ADDR_W'($urandom_range(0, URAM_DEPTH-1))),
                        .dram_base($urandom()),
                        .n_beats(DRAM_LEN_W'($urandom_range(1, MAX_BEATS))));
            if ((i % 4) == 0) req_ready_stall_cycles = $urandom_range(0, 4);
            else              req_ready_stall_cycles = 0;
            if ((i % 3) == 0) rsp_throttle_period    = $urandom_range(0, 3);
            else              rsp_throttle_period    = 0;
            issue_desc(d);
        end
        req_ready_stall_cycles = 0;
        rsp_throttle_period    = 0;
        $display("=========================================================");
        if (errors == 0 && tb_errors == 0) begin
            $display(" tb_csd_engine: PASS  (%0d descriptors, %0d beat checks, 0 errors)",
                     descriptors_done, checks);
        end else begin
            $display(" tb_csd_engine: FAIL  (%0d descriptors, %0d checks, %0d compare, %0d tb errors)",
                     descriptors_done, checks, errors, tb_errors);
        end
        $display("=========================================================");
        $finish;
    end
    initial begin : watchdog
        #(2_000_000);
        $fatal(1, "tb_csd_engine: watchdog expired");
    end

endmodule : tb_csd_engine

`default_nettype wire
