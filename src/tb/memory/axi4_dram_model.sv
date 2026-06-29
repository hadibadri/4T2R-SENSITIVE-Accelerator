// -----------------------------------------------------------------------------
// axi4_dram_model.sv  (C2 — behavioral DDR4 AXI4 slave, SIMULATION ONLY)
//
// A self-contained AXI4 slave that models off-chip DDR4 for the memory seam.
// It is the sim stand-in for the DDR4 MIG that archbetter_soc_top will drop in
// at C3 — so it is deliberately NOT synthesizable (associative-array backing
// store) and lives under src/tb/. It is never added to the synth fileset.
//
// Models:
//   * INCR read/write bursts (the only kind the adapters issue).
//   * A fixed access latency: RD_LATENCY cycles from AR-accept to the first R
//     beat; WR_LATENCY cycles from WLAST to B. This is what gives the full layer
//     "modeled DRAM latency" end to end (the C2 goal). Constant latency is the
//     honest floor; a row-hit/row-miss model can replace it later without
//     touching the adapters or the accelerator.
//   * Single outstanding read and single outstanding write (independent),
//     matching the adapters' one-burst-at-a-time issue.
//
// Backing store: byte-addressed, one AXI_DATA_W word per BEAT_BYTES of address.
// Unwritten addresses read as 0 (not X) so testbench compares are clean.
//
// wstrb: honored byte-wise (the adapters drive all-ones, but byte-enable is
// modeled correctly so a future narrow/ECC write still behaves).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_AXI4_DRAM_MODEL_SV
`define ARCHBETTER_AXI4_DRAM_MODEL_SV
`default_nettype none

module axi4_dram_model #(
    parameter int unsigned AXI_DATA_W  = 128,
    parameter int unsigned AXI_ADDR_W  = 32,
    parameter int unsigned AXI_ID_W    = 4,
    parameter int unsigned RD_LATENCY  = 8,   // AR-accept -> first R beat
    parameter int unsigned WR_LATENCY  = 4    // WLAST -> B
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

    // -------------------------------------------------------------------------
    // Backing store (sim-only associative array), byte-addressed.
    // -------------------------------------------------------------------------
    logic [AXI_DATA_W-1:0] mem [logic [AXI_ADDR_W-1:0]];

    function automatic logic [AXI_DATA_W-1:0] mem_rd(input logic [AXI_ADDR_W-1:0] a);
        return mem.exists(a) ? mem[a] : '0;
    endfunction

    // Sim backdoor: a testbench preloads the DRAM image and reads results back
    // without going through the AXI channels (call hierarchically, e.g.
    // u_model.backdoor_write(addr, data)). Blocking, as required for assoc arrays.
    task automatic backdoor_write(input logic [AXI_ADDR_W-1:0] a,
                                  input logic [AXI_DATA_W-1:0] d);
        mem[a] = d;
    endtask
    function automatic logic [AXI_DATA_W-1:0] backdoor_read(input logic [AXI_ADDR_W-1:0] a);
        return mem.exists(a) ? mem[a] : '0;
    endfunction

    // =========================================================================
    // READ engine (AR -> R).
    // =========================================================================
    typedef enum logic [1:0] { RD_IDLE, RD_WAIT, RD_BEAT } rstate_e;
    rstate_e               rstate_q;
    logic [AXI_ADDR_W-1:0] raddr_q;
    logic [7:0]            rcnt_q;     // beats remaining - 1
    logic [AXI_ID_W-1:0]   rid_q;
    logic [LAT_W-1:0]      rlat_q;

    assign axi.arready = (rstate_q == RD_IDLE);
    assign axi.rvalid  = (rstate_q == RD_BEAT);
    assign axi.rdata   = (rstate_q == RD_BEAT) ? mem_rd(raddr_q) : '0;
    assign axi.rlast   = (rstate_q == RD_BEAT) && (rcnt_q == 8'd0);
    assign axi.rid     = rid_q;
    assign axi.rresp   = 2'b00; // OKAY

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

    // =========================================================================
    // WRITE engine (AW -> W -> B).
    // =========================================================================
    typedef enum logic [1:0] { WR_IDLE, WR_COLLECT, WR_WAIT, WR_B } wstate_e;
    wstate_e               wstate_q;
    logic [AXI_ADDR_W-1:0] waddr_q;
    logic [AXI_ID_W-1:0]   bid_q;
    logic [LAT_W-1:0]      wlat_q;

    assign axi.awready = (wstate_q == WR_IDLE);
    assign axi.wready  = (wstate_q == WR_COLLECT);
    assign axi.bvalid  = (wstate_q == WR_B);
    assign axi.bid     = bid_q;
    assign axi.bresp   = 2'b00; // OKAY

    // Byte-wise write with strobe.
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
                        // Blocking write: XSim does not support non-blocking
                        // assignment to an associative array (XSIM 43-3980). The
                        // RHS reads the OLD mem via apply_strb before the store,
                        // which is the intended read-modify-write semantics.
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
    // The adapters issue INCR only and never exceed 256-beat bursts.
    a_arlen_ok: assert property (@(posedge clk) disable iff (!rst_n)
        (axi.arvalid && axi.arready) |-> (axi.arburst == 2'b01))
        else $error("axi4_dram_model: non-INCR read burst");
    a_awlen_ok: assert property (@(posedge clk) disable iff (!rst_n)
        (axi.awvalid && axi.awready) |-> (axi.awburst == 2'b01))
        else $error("axi4_dram_model: non-INCR write burst");
`endif

endmodule : axi4_dram_model

`default_nettype wire
`endif // ARCHBETTER_AXI4_DRAM_MODEL_SV
