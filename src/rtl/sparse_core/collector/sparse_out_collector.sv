
`timescale 1ns/1ps
`ifndef ARCHBETTER_SPARSE_OUT_COLLECTOR_SV
`define ARCHBETTER_SPARSE_OUT_COLLECTOR_SV
`default_nettype none

module sparse_out_collector
    import types_pkg::*;
#(
    parameter int unsigned WR_DATA_W = URAM_WIDTH_BITS
) (
    input  wire logic                   clk,
    input  wire logic                   rst_n,
    input  wire logic                   result_valid,
    input  wire tlmm_acc_vec_t          result_acc,
    input  wire logic [URAM_ADDR_W-1:0] wr_base_addr,
    output logic                        wr_en,
    output logic [URAM_ADDR_W-1:0]      wr_addr,
    output logic [WR_DATA_W-1:0]        wr_data,

    output logic                        busy_o
);
    initial begin : elab_checks
        if (WR_DATA_W < TLMM_ACC_W) begin
            $fatal(1, "sparse_out_collector: WR_DATA_W=%0d < TLMM_ACC_W=%0d",
                   WR_DATA_W, TLMM_ACC_W);
        end
    end
    localparam int unsigned LANE_CNT_W = $clog2(TLMM_LANES + 1);
    localparam int unsigned LANE_IDX_W = $clog2(TLMM_LANES);
    tlmm_acc_t              acc_q [TLMM_LANES];
    logic                   have_snap_q;
    logic [URAM_ADDR_W-1:0] wr_base_addr_q;
    logic [LANE_CNT_W-1:0]  lane_idx_q;

    logic drain_done;
    assign drain_done = (lane_idx_q == LANE_CNT_W'(TLMM_LANES));
    always_comb begin
        wr_en   = have_snap_q && !drain_done;
        wr_addr = URAM_ADDR_W'(wr_base_addr_q + URAM_ADDR_W'(lane_idx_q));
        wr_data = '0;
        if (wr_en) begin
            wr_data[TLMM_ACC_W-1:0] = acc_q[lane_idx_q[LANE_IDX_W-1:0]];
        end
    end

    assign busy_o = have_snap_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int ln = 0; ln < int'(TLMM_LANES); ln++) acc_q[ln] <= '0;
            have_snap_q    <= 1'b0;
            wr_base_addr_q <= '0;
            lane_idx_q     <= '0;
        end else begin
            if (result_valid && !have_snap_q) begin
                for (int ln = 0; ln < int'(TLMM_LANES); ln++) begin
                    acc_q[ln] <= result_acc[ln];
                end
                have_snap_q    <= 1'b1;
                wr_base_addr_q <= wr_base_addr;
                lane_idx_q     <= '0;
            end
            if (wr_en) begin
                lane_idx_q <= lane_idx_q + LANE_CNT_W'(1);
            end
            if (have_snap_q && drain_done) begin
                have_snap_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    a_no_snap_while_busy: assert property (
        @(posedge clk) disable iff (!rst_n)
        result_valid |-> !have_snap_q
    ) else $error("sparse_out_collector: result_valid while still draining previous snap");
    a_lane_idx_bound: assert property (
        @(posedge clk) disable iff (!rst_n)
        lane_idx_q <= LANE_CNT_W'(TLMM_LANES)
    ) else $error("sparse_out_collector: lane_idx_q exceeded TLMM_LANES");
`endif

endmodule : sparse_out_collector

`default_nettype wire
`endif
