
`timescale 1ns/1ps
`default_nettype none

module tb_axi4_dram_adapter;
    import types_pkg::*;

    localparam time         T_CLK      = 10ns;
    localparam int unsigned AXI_DATA_W = 128;
    localparam int unsigned AXI_ID_W   = 4;
    localparam int unsigned RD_LATENCY = 8;
    localparam int unsigned WR_LATENCY = 4;
    logic clk, rst_n;
    initial clk = 1'b0;
    always #(T_CLK/2) clk = ~clk;
    csd_dram_if    rd_if (.clk(clk), .rst_n(rst_n));
    csd_dram_wr_if wr_if (.clk(clk), .rst_n(rst_n));
    axi4_if #(.ADDR_W(DRAM_ADDR_W), .DATA_W(AXI_DATA_W), .ID_W(AXI_ID_W))
        axi (.clk(clk), .rst_n(rst_n));

    axi4_read_adapter #(.AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W))
        u_rd (.clk(clk), .rst_n(rst_n), .rd(rd_if.dram), .axi(axi.master_rd));

    axi4_write_adapter #(.AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W))
        u_wr (.clk(clk), .rst_n(rst_n), .wr(wr_if.dram), .axi(axi.master_wr));

    axi4_dram_model #(
        .AXI_DATA_W(AXI_DATA_W), .AXI_ADDR_W(DRAM_ADDR_W), .AXI_ID_W(AXI_ID_W),
        .RD_LATENCY(RD_LATENCY), .WR_LATENCY(WR_LATENCY)
    ) u_model (.clk(clk), .rst_n(rst_n), .axi(axi.slave));
    int unsigned n_checks, n_errors;
    function automatic void chk(input bit cond, input string msg);
        n_checks++;
        if (!cond) begin
            n_errors++;
            $error("tb_axi4_dram_adapter: CHECK FAILED — %s", msg);
        end
    endfunction
    function automatic logic [DRAM_BEAT_W-1:0] patt(
        input logic [DRAM_ADDR_W-1:0] base, input int unsigned idx
    );
        return { base, 8'hA5, 32'(idx) };
    endfunction
    int unsigned cyc;
    always_ff @(posedge clk) begin
        if (!rst_n) cyc <= 0; else cyc <= cyc + 1;
    end
    initial begin
        rd_if.req_addr  = '0; rd_if.req_len = '0; rd_if.req_valid = 1'b0;
        rd_if.rsp_ready = 1'b0;
        wr_if.req_addr  = '0; wr_if.req_len = '0; wr_if.req_valid = 1'b0;
        wr_if.wd_data   = '0; wr_if.wd_valid = 1'b0; wr_if.wd_last = 1'b0;
    end
    task automatic do_write(
        input logic [DRAM_ADDR_W-1:0] base, input int unsigned n, input bit slow
    );
        @(negedge clk);
        wr_if.req_addr  = base;
        wr_if.req_len   = DRAM_LEN_W'(n);
        wr_if.req_valid = 1'b1;
        forever begin @(posedge clk); if (wr_if.req_ready) break; end
        @(negedge clk); wr_if.req_valid = 1'b0;
        for (int unsigned i = 0; i < n; i++) begin
            if (slow && ($urandom_range(0, 1) == 0)) begin
                @(negedge clk); wr_if.wd_valid = 1'b0;
                repeat ($urandom_range(1, 3)) @(posedge clk);
            end
            @(negedge clk);
            wr_if.wd_data  = patt(base, i);
            wr_if.wd_last  = (i == n - 1);
            wr_if.wd_valid = 1'b1;
            forever begin @(posedge clk); if (wr_if.wd_ready) break; end
            @(negedge clk); wr_if.wd_valid = 1'b0; wr_if.wd_last = 1'b0;
        end
        forever begin @(posedge clk); if (wr_if.req_ready) break; end
    endtask
    task automatic do_read_check(
        input logic [DRAM_ADDR_W-1:0] base, input int unsigned n, input bit slow,
        output int unsigned first_lat
    );
        int unsigned t_accept, t_first;
        bit got_first;
        got_first = 1'b0;
        first_lat = 0;

        @(negedge clk);
        rd_if.req_addr  = base;
        rd_if.req_len   = DRAM_LEN_W'(n);
        rd_if.req_valid = 1'b1;
        rd_if.rsp_ready = 1'b1;
        forever begin @(posedge clk); if (rd_if.req_ready) break; end
        t_accept = cyc;
        @(negedge clk); rd_if.req_valid = 1'b0;

        for (int unsigned i = 0; i < n; i++) begin
            if (slow && ($urandom_range(0, 1) == 0)) begin
                @(negedge clk); rd_if.rsp_ready = 1'b0;
                repeat ($urandom_range(1, 3)) @(posedge clk);
                @(negedge clk); rd_if.rsp_ready = 1'b1;
            end
            forever begin @(posedge clk); if (rd_if.rsp_valid && rd_if.rsp_ready) break; end
            if (!got_first) begin t_first = cyc; first_lat = t_first - t_accept; got_first = 1'b1; end
            chk(rd_if.rsp_data === patt(base, i),
                $sformatf("read base=%h beat %0d: got %h exp %h",
                          base, i, rd_if.rsp_data, patt(base, i)));
            chk(rd_if.rsp_last === ((i == n - 1) ? 1'b1 : 1'b0),
                $sformatf("read base=%h beat %0d: rsp_last=%b exp %b",
                          base, i, rd_if.rsp_last, (i == n - 1)));
        end
        @(negedge clk); rd_if.rsp_ready = 1'b0;
    endtask
    task automatic round_trip(
        input string name, input logic [DRAM_ADDR_W-1:0] base,
        input int unsigned n, input bit slow
    );
        int unsigned lat;
        $display("[%0t] CASE %s: base=%h N=%0d slow=%0d", $time, name, base, n, slow);
        do_write(base, n, slow);
        do_read_check(base, n, slow, lat);
        $display("[%0t]   %s: %0d beats verified, first-beat latency = %0d cyc",
                 $time, name, n, lat);
        chk(lat >= RD_LATENCY,
            $sformatf("%s: first-beat latency %0d < modeled RD_LATENCY %0d",
                      name, lat, RD_LATENCY));
    endtask
    initial begin : main
        n_checks = 0; n_errors = 0;
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        round_trip("single",      32'h1000_0000, 1,   1'b0);
        round_trip("one_maxburst",32'h1000_1000, 256, 1'b0);
        round_trip("two_bursts",  32'h1000_2000, 257, 1'b0);
        round_trip("midpage",     32'h1000_3010, 200, 1'b0);
        round_trip("crosses_2pg", 32'h1000_3F00, 300, 1'b0);
        round_trip("throttled",   32'h2000_0000, 130, 1'b1);

        repeat (8) @(posedge clk);
        if (n_errors == 0)
            $display("tb_axi4_dram_adapter: PASS  (%0d checks, 0 errors)", n_checks);
        else
            $display("tb_axi4_dram_adapter: FAIL  (%0d errors / %0d checks)", n_errors, n_checks);
        $finish;
    end
    initial begin : watchdog
        #(T_CLK * 200_000);
        $fatal(1, "tb_axi4_dram_adapter: watchdog timeout");
    end

endmodule : tb_axi4_dram_adapter

`default_nettype wire
