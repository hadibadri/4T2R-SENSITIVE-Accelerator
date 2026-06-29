
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE_ACT_STREAMER_SV
`define ARCHBETTER_DENSE_ACT_STREAMER_SV
`default_nettype none

module dense_act_streamer
    import types_pkg::*;
#(
    parameter int unsigned PP_DATA_W   = DENSE_PP_URAM_W,
    parameter int unsigned NOC_DW      = NOC_DATA_W,
    parameter int unsigned NOC_UW      = NOC_USER_W,
    parameter int unsigned MANT_HALF_W = BFP12_BLK * BFP12_MANT_W / 2,
    parameter int unsigned FIFO_DEPTH  = 8
) (
    input  wire logic                    clk,
    input  wire logic                    rst_n,

    input  wire logic [URAM_ADDR_W-1:0]  base_addr,
    input  wire logic [URAM_ADDR_W-1:0]  token_stride,

    gemm_issue_if.drv  gemm,
    pingpong_if.core   pp,
    strm_if.src        src
);
    localparam int unsigned CASCADE_HALF_W = PP_DATA_W / 2;
    localparam int unsigned CNT_W          = $clog2(FIFO_DEPTH + 1);

    initial begin : geometry_check
        if (PP_DATA_W < (CASCADE_HALF_W + MANT_HALF_W))
            $error("dense_act_streamer: PP_DATA_W=%0d cannot hold the hi mantissa half at [%0d +: %0d]",
                   PP_DATA_W, CASCADE_HALF_W, MANT_HALF_W);
        if (NOC_DW != (2 * MANT_HALF_W))
            $error("dense_act_streamer: NOC_DW=%0d != 2*MANT_HALF_W=%0d", NOC_DW, 2*MANT_HALF_W);
    end
    logic                    running_q;
    logic [MACRO_CNT_W-1:0]  total_beats_q;
    logic [URAM_ADDR_W-1:0]  beat_stride_q;

    logic op_start;
    assign op_start = gemm.busy && !running_q;
    logic [MACRO_CNT_W-1:0]  iss_beat_q;
    logic [URAM_ADDR_W-1:0]  iss_base_q;
    logic [CNT_W:0]          outstanding_q;

    logic iss_more;
    logic can_issue;
    assign iss_more  = running_q && (iss_beat_q < total_beats_q);
    assign can_issue = iss_more && pp.side_valid
                     && (outstanding_q < CNT_W'(FIFO_DEPTH));
    logic [URAM_ADDR_W-1:0] issue_addr;
    assign issue_addr = iss_base_q >> 1;
    logic issued_beat;
    assign issued_beat = can_issue;
    logic [MACRO_CNT_W-1:0] cap_beat_q;

    logic                 beat_ready;
    logic [NOC_DW-1:0]    beat_data;
    logic [NOC_UW-1:0]    beat_user;
    logic                 beat_last;
    assign beat_ready = pp.rd_valid;
    assign beat_data  = { pp.rd_data[CASCADE_HALF_W +: MANT_HALF_W],
                          pp.rd_data[MANT_HALF_W-1:0] };
    assign beat_user  = pp.rd_data[MANT_HALF_W +: BFP12_EXP_W];
    assign beat_last  = (cap_beat_q == (total_beats_q - 1));
    logic [NOC_DW-1:0] fifo_data [FIFO_DEPTH];
    logic [NOC_UW-1:0] fifo_user [FIFO_DEPTH];
    logic              fifo_last [FIFO_DEPTH];
    logic [$clog2(FIFO_DEPTH)-1:0] wr_ptr_q, rd_ptr_q;
    logic [CNT_W-1:0]              fifo_cnt_q;

    logic fifo_empty, fifo_full;
    assign fifo_empty = (fifo_cnt_q == '0);
    assign fifo_full  = (fifo_cnt_q == CNT_W'(FIFO_DEPTH));

    logic present_fire;
    assign present_fire = src.valid && src.ready;

    assign src.valid = !fifo_empty;
    assign src.data  = fifo_data[rd_ptr_q];
    assign src.user  = fifo_user[rd_ptr_q];
    assign src.last  = fifo_last[rd_ptr_q];

    assign gemm.beat_fire = present_fire;
    logic [MACRO_CNT_W-1:0] pres_beat_q;
    logic op_done;
    assign op_done = running_q && (pres_beat_q == total_beats_q);
    logic drain_ack_q;
    always_ff @(posedge clk) begin
        if (!rst_n) drain_ack_q <= 1'b0;
        else        drain_ack_q <= pp.drain_req && !drain_ack_q;
    end

    always_comb begin
        pp.rd_en     = can_issue;
        pp.rd_addr   = issue_addr;
        pp.drain_ack = drain_ack_q;
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            running_q     <= 1'b0;
            total_beats_q <= '0;
            beat_stride_q <= URAM_ADDR_W'(2);
            iss_beat_q    <= '0;
            iss_base_q    <= '0;
            outstanding_q <= '0;
            cap_beat_q    <= '0;
            wr_ptr_q      <= '0;
            rd_ptr_q      <= '0;
            fifo_cnt_q    <= '0;
            pres_beat_q   <= '0;
        end else begin
            if (op_start) begin
                running_q     <= 1'b1;
                if (gemm.stream_mode == GEMM_SNAP_CONTINUOUS) begin
                    total_beats_q <= MACRO_CNT_W'(gemm.batch_n);
                    beat_stride_q <= token_stride;
                end else begin
                    total_beats_q <= gemm.k_cnt;
                    beat_stride_q <= URAM_ADDR_W'(2);
                end
                iss_beat_q    <= '0;
                iss_base_q    <= base_addr;
                outstanding_q <= '0;
                cap_beat_q    <= '0;
                pres_beat_q   <= '0;
            end
            if (can_issue) begin
                iss_beat_q <= iss_beat_q + 1'b1;
                iss_base_q <= iss_base_q + beat_stride_q;
            end
            if (pp.rd_valid) begin
                cap_beat_q <= cap_beat_q + 1'b1;
            end
            outstanding_q <= outstanding_q
                           + (issued_beat  ? { {CNT_W{1'b0}}, 1'b1 } : '0)
                           - (present_fire ? { {CNT_W{1'b0}}, 1'b1 } : '0);
            if (beat_ready) begin
                fifo_data[wr_ptr_q] <= beat_data;
                fifo_user[wr_ptr_q] <= beat_user;
                fifo_last[wr_ptr_q] <= beat_last;
                wr_ptr_q <= (wr_ptr_q == ($clog2(FIFO_DEPTH))'(FIFO_DEPTH-1))
                          ? '0 : wr_ptr_q + 1'b1;
            end
            if (present_fire) begin
                rd_ptr_q <= (rd_ptr_q == ($clog2(FIFO_DEPTH))'(FIFO_DEPTH-1))
                          ? '0 : rd_ptr_q + 1'b1;
                pres_beat_q <= pres_beat_q + 1'b1;
            end
            fifo_cnt_q <= fifo_cnt_q
                        + (beat_ready   ? CNT_W'(1) : CNT_W'(0))
                        - (present_fire ? CNT_W'(1) : CNT_W'(0));
            if (op_done && !gemm.busy) begin
                running_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    a_no_fire_outside_busy: assert property (
        @(posedge clk) disable iff (!rst_n) present_fire |-> gemm.busy
    ) else $error("dense_act_streamer: src fired while gemm.busy=0");
    a_last_only_on_final: assert property (
        @(posedge clk) disable iff (!rst_n)
        (present_fire && src.last) |-> (pres_beat_q == (total_beats_q - 1))
    ) else $error("dense_act_streamer: src.last asserted on non-final beat");
    a_fifo_no_overflow: assert property (
        @(posedge clk) disable iff (!rst_n) !(beat_ready && fifo_full && !present_fire)
    ) else $error("dense_act_streamer: beat FIFO overflow");
    a_fifo_no_underflow: assert property (
        @(posedge clk) disable iff (!rst_n) present_fire |-> !fifo_empty
    ) else $error("dense_act_streamer: present from empty FIFO");
`endif

endmodule : dense_act_streamer

`default_nettype wire
`endif
