
`ifndef ARCHBETTER_NOC_ROUTER_SV
`define ARCHBETTER_NOC_ROUTER_SV
`default_nettype none
`timescale 1ns/1ps

module noc_router
    import types_pkg::*;
#(
    parameter int unsigned DATA_W = NOC_DATA_W,
    parameter int unsigned USER_W = NOC_USER_W,
    parameter int unsigned FANOUT = NOC_NODES,
    parameter int unsigned ROUTER_ID = 0
) (
    input  wire logic     clk,
    input  wire logic     rst_n,
    noc_cfg_if.slave      cfg,
    noc_router_if.router  rt
);
    initial begin : elab_checks
        if (FANOUT > NOC_NODES) begin
            $fatal(1, "noc_router: FANOUT=%0d exceeds NOC_NODES=%0d",
                   FANOUT, NOC_NODES);
        end
    end
    noc_path_cfg_t path_tab [NOC_PATH_HANDLES];

    logic committed;
    assign cfg.cfg_ready = !committed;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            committed <= 1'b0;
        end else begin
            if (cfg.cfg_valid && cfg.cfg_ready) begin
                path_tab[cfg.handle] <= cfg.cfg;
            end
            if (cfg.path_commit) begin
                committed <= 1'b1;
            end
        end
    end
    noc_mask_t         cur_mask_full;
    logic [FANOUT-1:0] cur_mask;
    logic [FANOUT-1:0] egress_active;
    logic [FANOUT-1:0] egress_ok;

    always_comb begin
        cur_mask_full = path_tab[rt.path_id].dst_mask;
        cur_mask      = cur_mask_full[FANOUT-1:0];
        for (int d = 0; d < FANOUT; d++) begin
            egress_active[d] = committed && rt.in_valid && cur_mask[d];
            egress_ok[d]     = !cur_mask[d] || rt.out_ready[d];
        end
    end

    logic all_egress_ok;
    logic any_dst;
    assign all_egress_ok = &egress_ok;
    assign any_dst       = |cur_mask;
    assign rt.in_ready = committed && any_dst && all_egress_ok;
    always_comb begin
        for (int d = 0; d < FANOUT; d++) begin
            rt.out_data[d]  = rt.in_data;
            rt.out_user[d]  = rt.in_user;
            rt.out_last[d]  = rt.in_last;
            rt.out_valid[d] = egress_active[d];
        end
    end

`ifndef SYNTHESIS
    property p_no_stream_before_commit;
        @(posedge clk) disable iff (!rst_n)
        !committed |-> (rt.out_valid == '0) && (rt.in_ready == 1'b0);
    endproperty
    a_no_stream_before_commit: assert property (p_no_stream_before_commit)
        else $error("noc_router[%0d]: streamed or asserted in_ready before commit",
                    ROUTER_ID);
    property p_commit_is_sticky;
        @(posedge clk) disable iff (!rst_n)
        committed |=> committed;
    endproperty
    a_commit_is_sticky: assert property (p_commit_is_sticky)
        else $error("noc_router[%0d]: committed dropped after it was set",
                    ROUTER_ID);
    property p_path_id_stable_during_stall;
        @(posedge clk) disable iff (!rst_n)
        (rt.in_valid && !rt.in_ready) |=> $stable(rt.path_id);
    endproperty
    a_path_id_stable_during_stall: assert property (p_path_id_stable_during_stall)
        else $error("noc_router[%0d]: path_id changed while beat was stalled",
                    ROUTER_ID);
`endif

endmodule : noc_router

`default_nettype wire
`endif
