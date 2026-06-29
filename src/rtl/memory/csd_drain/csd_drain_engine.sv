
`timescale 1ns/1ps
`ifndef ARCHBETTER_CSD_DRAIN_ENGINE_SV
`define ARCHBETTER_CSD_DRAIN_ENGINE_SV
`default_nettype none

module csd_drain_engine
    import types_pkg::*;
#(
    parameter int unsigned URAM_DATA_W = URAM_WIDTH_BITS
) (
    input  wire logic                    clk,
    input  wire logic                    rst_n,
    input  wire csd_descriptor_t         desc_i,
    input  wire logic                    desc_valid_i,
    output logic                         desc_ready_o,
    output logic                         done_o,
    output logic                         rd_en_o,
    output logic [URAM_ADDR_W-1:0]       rd_addr_o,
    input  wire logic                    rd_valid_i,
    input  wire logic [URAM_DATA_W-1:0]  rd_data_i,
    csd_dram_wr_if.mgr                   dram_wr
);
    initial begin : elab_checks
        if (URAM_DATA_W != DRAM_BEAT_W) begin
            $fatal(1, "csd_drain_engine: URAM_DATA_W=%0d must equal DRAM_BEAT_W=%0d",
                   URAM_DATA_W, DRAM_BEAT_W);
        end
    end
    typedef enum logic [1:0] {
        S_IDLE   = 2'd0,
        S_REQ    = 2'd1,
        S_STREAM = 2'd2,
        S_DONE   = 2'd3
    } state_e;
    state_e state_q, state_d;

    csd_descriptor_t       desc_q;
    logic [DRAM_LEN_W-1:0] issued_q;
    logic [DRAM_LEN_W-1:0] pushed_q;
    logic [URAM_DATA_W-1:0] skid_q [0:1];
    logic [1:0]             skid_count_q;
    logic desc_fire;
    logic req_fire;
    logic wd_fire;
    logic capture_now;
    logic in_flight_full;

    assign desc_fire   = desc_valid_i && desc_ready_o;
    assign req_fire    = dram_wr.req_valid && dram_wr.req_ready;
    assign wd_fire     = dram_wr.wd_valid && dram_wr.wd_ready;
    assign capture_now = (state_q == S_STREAM) && rd_valid_i;
    logic [DRAM_LEN_W-1:0] outstanding;
    assign outstanding    = DRAM_LEN_W'(issued_q - pushed_q);
    assign in_flight_full = (outstanding >= DRAM_LEN_W'(2));

    logic issue_now;
    assign issue_now = (state_q == S_STREAM)
                     && (issued_q < desc_q.n_beats)
                     && !in_flight_full;
    assign desc_ready_o = (state_q == S_IDLE);
    assign done_o       = (state_q == S_DONE);

    assign rd_en_o   = issue_now;
    assign rd_addr_o = URAM_ADDR_W'(desc_q.uram_base
                                     + URAM_ADDR_W'(issued_q[URAM_ADDR_W-1:0]));

    assign dram_wr.req_valid = (state_q == S_REQ);
    assign dram_wr.req_addr  = desc_q.dram_base;
    assign dram_wr.req_len   = desc_q.n_beats;

    assign dram_wr.wd_valid = (state_q == S_STREAM) && (skid_count_q != 2'd0);
    assign dram_wr.wd_data  = skid_q[0];
    assign dram_wr.wd_last  = dram_wr.wd_valid
                              && (DRAM_LEN_W'(pushed_q + 1'b1) == desc_q.n_beats);
    always_comb begin
        state_d = state_q;
        unique case (state_q)
            S_IDLE:   if (desc_fire) state_d = S_REQ;
            S_REQ:    if (req_fire)  state_d = S_STREAM;
            S_STREAM: if (wd_fire && (DRAM_LEN_W'(pushed_q + 1'b1) == desc_q.n_beats))
                         state_d = S_DONE;
            S_DONE:                  state_d = S_IDLE;
            default:                 state_d = S_IDLE;
        endcase
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q      <= S_IDLE;
            desc_q       <= '0;
            issued_q     <= '0;
            pushed_q     <= '0;
            skid_count_q <= 2'd0;
            skid_q[0]    <= '0;
            skid_q[1]    <= '0;
        end else begin
            state_q <= state_d;
            if (desc_fire) begin
                desc_q       <= desc_i;
                issued_q     <= '0;
                pushed_q     <= '0;
                skid_count_q <= 2'd0;
            end
            if (issue_now) begin
                issued_q <= DRAM_LEN_W'(issued_q + 1'b1);
            end
            unique case ({capture_now, wd_fire})
                2'b10: begin
                    if (skid_count_q == 2'd0) begin
                        skid_q[0] <= rd_data_i;
                    end else begin
                        skid_q[1] <= rd_data_i;
                    end
                    skid_count_q <= 2'(skid_count_q + 1'b1);
                end
                2'b01: begin
                    skid_q[0]    <= skid_q[1];
                    skid_count_q <= 2'(skid_count_q - 1'b1);
                    pushed_q     <= DRAM_LEN_W'(pushed_q + 1'b1);
                end
                2'b11: begin
                    if (skid_count_q == 2'd1) begin
                        skid_q[0] <= rd_data_i;
                    end else begin
                        skid_q[0] <= skid_q[1];
                        skid_q[1] <= rd_data_i;
                    end
                    pushed_q   <= DRAM_LEN_W'(pushed_q   + 1'b1);
                end
                default: ;
            endcase
        end
    end

`ifndef SYNTHESIS
    a_no_compression: assert property (
        @(posedge clk) disable iff (!rst_n)
        desc_fire |-> (desc_i.compressed == 1'b0)
    ) else $error("csd_drain_engine: descriptor with compressed=1 (Phase 5 is pass-through)");

    a_nonzero_len: assert property (
        @(posedge clk) disable iff (!rst_n)
        desc_fire |-> (desc_i.n_beats != '0)
    ) else $error("csd_drain_engine: descriptor with n_beats=0");

    a_capture_in_stream: assert property (
        @(posedge clk) disable iff (!rst_n)
        rd_valid_i |-> (state_q == S_STREAM)
    ) else $error("csd_drain_engine: rd_valid_i outside S_STREAM");

    a_skid_bound: assert property (
        @(posedge clk) disable iff (!rst_n)
        (skid_count_q <= 2'd2)
    ) else $error("csd_drain_engine: skid_count_q overflowed 2");

    a_outstanding_bound: assert property (
        @(posedge clk) disable iff (!rst_n)
        ((state_q == S_STREAM) |-> (outstanding <= DRAM_LEN_W'(2)))
    ) else $error("csd_drain_engine: outstanding=%0d exceeds skid capacity 2",
                   outstanding);

    a_done_pulse: assert property (
        @(posedge clk) disable iff (!rst_n)
        done_o |=> !done_o
    ) else $error("csd_drain_engine: done_o held high > 1 cycle");
`endif

endmodule : csd_drain_engine

`default_nettype wire
`endif
