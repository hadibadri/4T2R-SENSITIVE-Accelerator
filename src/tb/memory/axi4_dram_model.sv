
`timescale 1ns/1ps
`ifndef ARCHBETTER_AXI4_DRAM_MODEL_SV
`define ARCHBETTER_AXI4_DRAM_MODEL_SV
`default_nettype none

module axi4_dram_model #(
    parameter int unsigned AXI_DATA_W  = 128,
    parameter int unsigned AXI_ADDR_W  = 32,
    parameter int unsigned AXI_ID_W    = 4,
    parameter int unsigned RD_LATENCY  = 8,
    parameter int unsigned WR_LATENCY  = 4
) (
    input  wire logic clk,
    input  wire logic rst_n,
    axi4_if.slave     axi
);

    localparam int unsigned BEAT_BYTES = AXI_DATA_W / 8;
    localparam int unsigned AXSIZE     = $clog2(BEAT_BYTES);
    localparam int unsigned LAT_W      = (RD_LATENCY > WR_LATENCY)
                                       ? ($clog2(RD_LATENCY + 1) + 1)
                                       : ($clog2(WR_LATENCY + 1) + 1);
    logic [AXI_DATA_W-1:0] mem [logic [AXI_ADDR_W-1:0]];

    function automatic logic [AXI_DATA_W-1:0] mem_rd(input logic [AXI_ADDR_W-1:0] a);
        return mem.exists(a) ? mem[a] : '0;
    endfunction
    task automatic backdoor_write(input logic [AXI_ADDR_W-1:0] a,
                                  input logic [AXI_DATA_W-1:0] d);
        mem[a] = d;
    endtask
    function automatic logic [AXI_DATA_W-1:0] backdoor_read(input logic [AXI_ADDR_W-1:0] a);
        return mem.exists(a) ? mem[a] : '0;
    endfunction
    typedef enum logic [1:0] { RD_IDLE, RD_WAIT, RD_BEAT } rstate_e;
    rstate_e               rstate_q;
    logic [AXI_ADDR_W-1:0] raddr_q;
    logic [7:0]            rcnt_q;
    logic [AXI_ID_W-1:0]   rid_q;
    logic [LAT_W-1:0]      rlat_q;

    assign axi.arready = (rstate_q == RD_IDLE);
    assign axi.rvalid  = (rstate_q == RD_BEAT);
    assign axi.rdata   = (rstate_q == RD_BEAT) ? mem_rd(raddr_q) : '0;
    assign axi.rlast   = (rstate_q == RD_BEAT) && (rcnt_q == 8'd0);
    assign axi.rid     = rid_q;
    assign axi.rresp   = 2'b00;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rstate_q <= RD_IDLE;
            raddr_q  <= '0;
            rcnt_q   <= '0;
            rid_q    <= '0;
            rlat_q   <= '0;
        end else begin
            unique case (rstate_q)
                RD_IDLE: begin
                    if (axi.arvalid && axi.arready) begin
                        raddr_q  <= axi.araddr;
                        rcnt_q   <= axi.arlen;
                        rid_q    <= axi.arid;
                        rlat_q   <= LAT_W'(RD_LATENCY);
                        rstate_q <= (RD_LATENCY == 0) ? RD_BEAT : RD_WAIT;
                    end
                end
                RD_WAIT: begin
                    if (rlat_q <= LAT_W'(1)) rstate_q <= RD_BEAT;
                    else                     rlat_q   <= LAT_W'(rlat_q - 1'b1);
                end
                RD_BEAT: begin
                    if (axi.rvalid && axi.rready) begin
                        raddr_q <= AXI_ADDR_W'(raddr_q + AXI_ADDR_W'(BEAT_BYTES));
                        if (rcnt_q == 8'd0) rstate_q <= RD_IDLE;
                        else                rcnt_q   <= rcnt_q - 8'd1;
                    end
                end
                default: rstate_q <= RD_IDLE;
            endcase
        end
    end
    typedef enum logic [1:0] { WR_IDLE, WR_COLLECT, WR_WAIT, WR_B } wstate_e;
    wstate_e               wstate_q;
    logic [AXI_ADDR_W-1:0] waddr_q;
    logic [AXI_ID_W-1:0]   bid_q;
    logic [LAT_W-1:0]      wlat_q;

    assign axi.awready = (wstate_q == WR_IDLE);
    assign axi.wready  = (wstate_q == WR_COLLECT);
    assign axi.bvalid  = (wstate_q == WR_B);
    assign axi.bid     = bid_q;
    assign axi.bresp   = 2'b00;
    function automatic logic [AXI_DATA_W-1:0] apply_strb(
        input logic [AXI_ADDR_W-1:0]  a,
        input logic [AXI_DATA_W-1:0]  d,
        input logic [AXI_DATA_W/8-1:0] strb
    );
        logic [AXI_DATA_W-1:0] cur;
        cur = mem_rd(a);
        for (int b = 0; b < int'(AXI_DATA_W/8); b++)
            if (strb[b]) cur[b*8 +: 8] = d[b*8 +: 8];
        return cur;
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wstate_q <= WR_IDLE;
            waddr_q  <= '0;
            bid_q    <= '0;
            wlat_q   <= '0;
        end else begin
            unique case (wstate_q)
                WR_IDLE: begin
                    if (axi.awvalid && axi.awready) begin
                        waddr_q  <= axi.awaddr;
                        bid_q    <= axi.awid;
                        wstate_q <= WR_COLLECT;
                    end
                end
                WR_COLLECT: begin
                    if (axi.wvalid && axi.wready) begin
                        mem[waddr_q] = apply_strb(waddr_q, axi.wdata, axi.wstrb);
                        waddr_q      <= AXI_ADDR_W'(waddr_q + AXI_ADDR_W'(BEAT_BYTES));
                        if (axi.wlast) begin
                            wlat_q   <= LAT_W'(WR_LATENCY);
                            wstate_q <= (WR_LATENCY == 0) ? WR_B : WR_WAIT;
                        end
                    end
                end
                WR_WAIT: begin
                    if (wlat_q <= LAT_W'(1)) wstate_q <= WR_B;
                    else                     wlat_q   <= LAT_W'(wlat_q - 1'b1);
                end
                WR_B: begin
                    if (axi.bvalid && axi.bready) wstate_q <= WR_IDLE;
                end
                default: wstate_q <= WR_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    a_arlen_ok: assert property (@(posedge clk) disable iff (!rst_n)
        (axi.arvalid && axi.arready) |-> (axi.arburst == 2'b01))
        else $error("axi4_dram_model: non-INCR read burst");
    a_awlen_ok: assert property (@(posedge clk) disable iff (!rst_n)
        (axi.awvalid && axi.awready) |-> (axi.awburst == 2'b01))
        else $error("axi4_dram_model: non-INCR write burst");
`endif

endmodule : axi4_dram_model

`default_nettype wire
`endif
