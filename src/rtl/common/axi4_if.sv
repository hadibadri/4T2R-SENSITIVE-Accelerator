
`timescale 1ns/1ps
`ifndef ARCHBETTER_AXI4_IF_SV
`define ARCHBETTER_AXI4_IF_SV
`default_nettype none

interface axi4_if #(
    parameter int unsigned ADDR_W = 32,
    parameter int unsigned DATA_W = 128,
    parameter int unsigned ID_W   = 4
) (
    input  wire logic clk,
    input  wire logic rst_n
);

    localparam int unsigned STRB_W = DATA_W / 8;
    logic [ID_W-1:0]   awid;
    logic [ADDR_W-1:0] awaddr;
    logic [7:0]        awlen;
    logic [2:0]        awsize;
    logic [1:0]        awburst;
    logic              awvalid;
    logic              awready;
    logic [DATA_W-1:0] wdata;
    logic [STRB_W-1:0] wstrb;
    logic              wlast;
    logic              wvalid;
    logic              wready;
    logic [ID_W-1:0]   bid;
    logic [1:0]        bresp;
    logic              bvalid;
    logic              bready;
    logic [ID_W-1:0]   arid;
    logic [ADDR_W-1:0] araddr;
    logic [7:0]        arlen;
    logic [2:0]        arsize;
    logic [1:0]        arburst;
    logic              arvalid;
    logic              arready;
    logic [ID_W-1:0]   rid;
    logic [DATA_W-1:0] rdata;
    logic [1:0]        rresp;
    logic              rlast;
    logic              rvalid;
    logic              rready;
    modport master (
        output awid, awaddr, awlen, awsize, awburst, awvalid, input awready,
        output wdata, wstrb, wlast, wvalid, input wready,
        input  bid, bresp, bvalid, output bready,
        output arid, araddr, arlen, arsize, arburst, arvalid, input arready,
        input  rid, rdata, rresp, rlast, rvalid, output rready
    );

    modport master_rd (
        output arid, araddr, arlen, arsize, arburst, arvalid, input arready,
        input  rid, rdata, rresp, rlast, rvalid, output rready
    );

    modport master_wr (
        output awid, awaddr, awlen, awsize, awburst, awvalid, input awready,
        output wdata, wstrb, wlast, wvalid, input wready,
        input  bid, bresp, bvalid, output bready
    );

    modport slave (
        input  awid, awaddr, awlen, awsize, awburst, awvalid, output awready,
        input  wdata, wstrb, wlast, wvalid, output wready,
        output bid, bresp, bvalid, input bready,
        input  arid, araddr, arlen, arsize, arburst, arvalid, output arready,
        output rid, rdata, rresp, rlast, rvalid, input rready
    );

    modport mon (
        input awid, awaddr, awlen, awsize, awburst, awvalid, awready,
        input wdata, wstrb, wlast, wvalid, wready,
        input bid, bresp, bvalid, bready,
        input arid, araddr, arlen, arsize, arburst, arvalid, arready,
        input rid, rdata, rresp, rlast, rvalid, rready
    );

`ifndef SYNTHESIS
    property p_aw_stable;
        @(posedge clk) disable iff (!rst_n)
        (awvalid && !awready) |=> (awvalid && $stable(awaddr) && $stable(awlen)
                                            && $stable(awsize) && $stable(awburst));
    endproperty
    a_aw_stable: assert property (p_aw_stable)
        else $error("axi4_if: AW payload changed while awvalid && !awready");

    property p_w_stable;
        @(posedge clk) disable iff (!rst_n)
        (wvalid && !wready) |=> (wvalid && $stable(wdata) && $stable(wstrb)
                                          && $stable(wlast));
    endproperty
    a_w_stable: assert property (p_w_stable)
        else $error("axi4_if: W payload changed while wvalid && !wready");

    property p_ar_stable;
        @(posedge clk) disable iff (!rst_n)
        (arvalid && !arready) |=> (arvalid && $stable(araddr) && $stable(arlen)
                                            && $stable(arsize) && $stable(arburst));
    endproperty
    a_ar_stable: assert property (p_ar_stable)
        else $error("axi4_if: AR payload changed while arvalid && !arready");
    a_aw_incr: assert property (@(posedge clk) disable iff (!rst_n)
        awvalid |-> (awburst == 2'b01))
        else $error("axi4_if: AWBURST != INCR (memory seam is INCR-only)");
    a_ar_incr: assert property (@(posedge clk) disable iff (!rst_n)
        arvalid |-> (arburst == 2'b01))
        else $error("axi4_if: ARBURST != INCR (memory seam is INCR-only)");
`endif

endinterface : axi4_if

`default_nettype wire
`endif
