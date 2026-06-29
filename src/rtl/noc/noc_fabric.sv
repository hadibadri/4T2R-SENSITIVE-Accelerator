// -----------------------------------------------------------------------------
// noc_fabric.sv
//
// Circuit-switched multicast fabric for the ArchBetter accelerator.
//
// Structure:
//   * N_SOURCES source routers, each a noc_router with its own path table,
//     its own ingress stream, and its own committed path_id.
//   * All routers share the same global destination space of NOC_NODES nodes;
//     each router's egress port d drives global destination node d.
//   * The fabric OR-merges the per-source out_valid buses into a single
//     destination stream per node. The circuit-switched discipline requires
//     that at most ONE source drives any given destination on any given
//     cycle: the dispatcher is responsible for committing only non-overlapping
//     active masks. This invariant is asserted at simulation time.
//
// The fabric carries NO routing logic once committed - it is pure wire +
// register-free mux, which is the whole point of "circuit-switched".
//
// Boundary:
//   cfg      [N_SOURCES]  : per-source noc_cfg_if.slave. Each router has its
//                           own path table, so the dispatcher writes each.
//                           The path_commit pulse per-source freezes that
//                           source's table independently.
//   src      [N_SOURCES]  : per-source strm_if.sink. Upstream producers (the
//                           memory manager, dense_array row streams, etc.)
//                           feed these.
//   path_id  [N_SOURCES]  : per-source current path selector, driven by the
//                           dispatcher (changes only between drained beats).
//   dst      [NOC_NODES]  : per-destination strm_if.src. Consumers (dense
//                           groups, sparse tile, kv cache staging) attach.
//
// Resource class:
//   All LUT / flop. No DSP / BRAM / URAM. Scales as N_SOURCES * NOC_NODES
//   fan-out mux width.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_NOC_FABRIC_SV
`define ARCHBETTER_NOC_FABRIC_SV
`default_nettype none
`timescale 1ns/1ps

module noc_fabric
    import types_pkg::*;
#(
    parameter int unsigned N_SOURCES = 4,
    parameter int unsigned DATA_W    = NOC_DATA_W,
    parameter int unsigned USER_W    = NOC_USER_W
) (
    input  wire logic                             clk,
    input  wire logic                             rst_n,
    input  wire logic [NOC_PATH_ID_W-1:0]         path_id [N_SOURCES],
    noc_cfg_if.slave                              cfg     [N_SOURCES],
    strm_if.sink                                  src     [N_SOURCES],
    strm_if.src                                   dst     [NOC_NODES]
);

    // -------------------------------------------------------------------------
    // Per-source internal router interface and unpacked egress mirrors.
    // SystemVerilog interface arrays can only be indexed by a constant in
    // procedural code, so we flatten the router egress buses into packed
    // arrays that we CAN slice in always_comb.
    // -------------------------------------------------------------------------
    logic [N_SOURCES-1:0]                          src_ready;
    logic [N_SOURCES-1:0][NOC_NODES-1:0]           s_out_valid;
    logic [N_SOURCES-1:0][NOC_NODES-1:0]           s_out_last;
    logic [N_SOURCES-1:0][NOC_NODES-1:0][DATA_W-1:0] s_out_data;
    logic [N_SOURCES-1:0][NOC_NODES-1:0][USER_W-1:0] s_out_user;
    logic [N_SOURCES-1:0][NOC_NODES-1:0]           s_out_ready;

    // -------------------------------------------------------------------------
    // Destination-side unpacked mirrors. We drive dst[D].* from these via a
    // per-D generate, because dst is an interface array.
    // -------------------------------------------------------------------------
    logic [NOC_NODES-1:0]             d_valid;
    logic [NOC_NODES-1:0]             d_last;
    logic [NOC_NODES-1:0][DATA_W-1:0] d_data;
    logic [NOC_NODES-1:0][USER_W-1:0] d_user;
    logic [NOC_NODES-1:0]             d_ready;

    // -------------------------------------------------------------------------
    // One router per source. Each router is pure mux post-commit.
    // -------------------------------------------------------------------------
    for (genvar S = 0; S < N_SOURCES; S++) begin : gen_src
        noc_router_if #(
            .DATA_W (DATA_W),
            .USER_W (USER_W),
            .FANOUT (NOC_NODES)
        ) r (.clk(clk), .rst_n(rst_n));

        // Ingress binding: src[S] -> router in
        assign r.in_data     = src[S].data;
        assign r.in_user     = src[S].user;
        assign r.in_valid    = src[S].valid;
        assign r.in_last     = src[S].last;
        assign src_ready[S]  = r.in_ready;
        assign src[S].ready  = src_ready[S];

        // Path control: dispatcher drives path_id; path_commit is tied to the
        // cfg_if's commit pulse for this source.
        assign r.path_id     = path_id[S];
        assign r.path_commit = cfg[S].path_commit;

        // Egress binding: router out -> packed mirror.
        assign s_out_data [S] = r.out_data;
        assign s_out_user [S] = r.out_user;
        assign s_out_valid[S] = r.out_valid;
        assign s_out_last [S] = r.out_last;
        assign r.out_ready    = s_out_ready[S];

        noc_router #(
            .DATA_W    (DATA_W),
            .USER_W    (USER_W),
            .FANOUT    (NOC_NODES),
            .ROUTER_ID (S)
        ) u_router (
            .clk   (clk),
            .rst_n (rst_n),
            .cfg   (cfg[S]),
            .rt    (r)
        );
    end : gen_src

    // -------------------------------------------------------------------------
    // Aggregation per destination node:
    //   d_valid[D] = OR over sources of s_out_valid[*][D]
    //   d_data [D] = source-indexed mux (single-driver invariant asserted)
    //   s_out_ready[*][D] = d_ready[D]   (broadcast; only the active source
    //                                    actually honors it)
    // -------------------------------------------------------------------------
    always_comb begin
        for (int d = 0; d < NOC_NODES; d++) begin
            logic v;
            logic l;
            logic [DATA_W-1:0] dat;
            logic [USER_W-1:0] usr;
            v   = 1'b0;
            l   = 1'b0;
            dat = '0;
            usr = '0;
            // Priority-ordered selection. Under the circuit-switched contract
            // only one source's valid bit is ever high at once on a given D,
            // so this behaves as a one-hot mux; priority only matters when
            // the invariant is (wrongly) violated, in which case the assert
            // below catches it.
            for (int s = 0; s < N_SOURCES; s++) begin
                if (s_out_valid[s][d]) begin
                    v   = 1'b1;
                    l   = s_out_last [s][d];
                    dat = s_out_data [s][d];
                    usr = s_out_user [s][d];
                end
            end
            d_valid[d] = v;
            d_last [d] = l;
            d_data [d] = dat;
            d_user [d] = usr;

            // Broadcast destination readiness back to every source.
            for (int s = 0; s < N_SOURCES; s++) begin
                s_out_ready[s][d] = d_ready[d];
            end
        end
    end

    // Destination interface binding (per-D generate so index is constant).
    for (genvar D = 0; D < NOC_NODES; D++) begin : gen_dst
        assign dst[D].data  = d_data [D];
        assign dst[D].user  = d_user [D];
        assign dst[D].valid = d_valid[D];
        assign dst[D].last  = d_last [D];
        assign d_ready[D]   = dst[D].ready;
    end : gen_dst

`ifndef SYNTHESIS
    // Single-driver-per-destination invariant. At most one source may drive a
    // given destination's out_valid on any cycle. The dispatcher is
    // responsible for committing only non-overlapping active masks.
    for (genvar D = 0; D < NOC_NODES; D++) begin : gen_no_conflict
        always @(posedge clk) begin
            if (rst_n) begin
                automatic int cnt = 0;
                for (int s = 0; s < N_SOURCES; s++) begin
                    if (s_out_valid[s][D]) cnt++;
                end
                if (cnt > 1) begin
                    $error("noc_fabric: %0d sources simultaneously drive dst[%0d] (circuit-switched conflict)",
                           cnt, D);
                end
            end
        end
    end
`endif

endmodule : noc_fabric

`default_nettype wire
`endif // ARCHBETTER_NOC_FABRIC_SV
