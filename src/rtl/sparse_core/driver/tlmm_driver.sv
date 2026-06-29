
`timescale 1ns/1ps
`ifndef ARCHBETTER_TLMM_DRIVER_SV
`define ARCHBETTER_TLMM_DRIVER_SV
`default_nettype none

module tlmm_driver
    import types_pkg::*;
#(
    parameter int unsigned PP_DATA_W = 144
) (
    input  wire logic                    clk,
    input  wire logic                    rst_n,
    input  wire logic [URAM_ADDR_W-1:0]  base_addr,

    tlmm_issue_if.drv   tlmm,
    pingpong_if.core    pp,
    tlmm_ctrl_if.driver ctrl,
    output tlmm_acc_vec_t result_acc,
    output logic          result_valid
);
    localparam int unsigned PROG_BITS_PER_WORD    = 96;
    localparam int unsigned COMPUTE_BITS_PER_WORD = 128;

    localparam int unsigned PROG_PAYLOAD_W    = TLMM_TILE * BFP12_MANT_W;
    localparam int unsigned COMPUTE_PAYLOAD_W = TLMM_LANES * TLMM_TILE * 2;

    localparam int unsigned PROG_WORDS    = (PROG_PAYLOAD_W    + PROG_BITS_PER_WORD    - 1) / PROG_BITS_PER_WORD;
    localparam int unsigned COMPUTE_WORDS = (COMPUTE_PAYLOAD_W + COMPUTE_BITS_PER_WORD - 1) / COMPUTE_BITS_PER_WORD;

    localparam int unsigned WEIGHT_BASE_OFFSET = PROG_WORDS;
    localparam int unsigned ASM_W = COMPUTE_WORDS * COMPUTE_BITS_PER_WORD;

    localparam int unsigned WORDIDX_W    = $clog2(COMPUTE_WORDS + 1);
    localparam int unsigned MAX_INFLIGHT = 2;
    localparam int unsigned IFL_W        = $clog2(MAX_INFLIGHT + 1);
    initial begin : geom_check
        if (PP_DATA_W < COMPUTE_BITS_PER_WORD) begin
            $fatal(1, "tlmm_driver: PP_DATA_W=%0d must hold COMPUTE_BITS_PER_WORD=%0d",
                   PP_DATA_W, COMPUTE_BITS_PER_WORD);
        end
        if (COMPUTE_PAYLOAD_W != $bits(tern_lane_tiles_t)) begin
            $fatal(1, "tlmm_driver: COMPUTE_PAYLOAD_W=%0d != $bits(tern_lane_tiles_t)=%0d",
                   COMPUTE_PAYLOAD_W, $bits(tern_lane_tiles_t));
        end
        if (PROG_PAYLOAD_W != $bits(tlmm_tile_act_t)) begin
            $fatal(1, "tlmm_driver: PROG_PAYLOAD_W=%0d != $bits(tlmm_tile_act_t)=%0d",
                   PROG_PAYLOAD_W, $bits(tlmm_tile_act_t));
        end
    end
    typedef enum logic [2:0] {
        S_IDLE       = 3'd0,
        S_PROG_FETCH = 3'd1,
        S_PROG_PRES  = 3'd2,
        S_W_FETCH    = 3'd3,
        S_W_PRES     = 3'd4,
        S_DRAIN      = 3'd5,
        S_DONE       = 3'd6
    } state_e;

    state_e state_q, state_d;
    logic [MACRO_CNT_W-1:0] k_cnt_q;
    logic [MACRO_CNT_W-1:0] beats_issued_q;
    logic [MACRO_CNT_W-1:0] beats_out_q;
    logic [WORDIDX_W-1:0]   issue_idx_q;
    logic [WORDIDX_W-1:0]   capture_idx_q;
    logic [IFL_W-1:0]       in_flight_q;
    logic [ASM_W-1:0]       asm_q;
    tlmm_tile_act_t         prog_q;
    logic                   prog_valid_q;
    tern_lane_tiles_t       w_q;
    logic                   w_valid_q;
    logic                   tlmm_done_q;
    logic in_fetch;
    logic in_prog_fetch;
    logic in_w_fetch;
    assign in_prog_fetch = (state_q == S_PROG_FETCH);
    assign in_w_fetch    = (state_q == S_W_FETCH);
    assign in_fetch      = in_prog_fetch || in_w_fetch;

    logic [WORDIDX_W-1:0] words_needed;
    assign words_needed = in_prog_fetch ? WORDIDX_W'(PROG_WORDS)
                        : in_w_fetch    ? WORDIDX_W'(COMPUTE_WORDS)
                        :                  '0;

    logic all_captured;
    assign all_captured = (capture_idx_q == words_needed);
    logic [URAM_ADDR_W-1:0] base_for_phase;
    logic [URAM_ADDR_W-1:0] rd_addr_next;
    logic                   issue_now;
    logic                   capture_now;
    logic drain_ack_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            drain_ack_q <= 1'b0;
        end else begin
            drain_ack_q <= pp.drain_req && !drain_ack_q;
        end
    end

    always_comb begin
        if (in_prog_fetch) begin
            base_for_phase = base_addr;
        end else if (in_w_fetch) begin
            base_for_phase = URAM_ADDR_W'(base_addr
                           + URAM_ADDR_W'(WEIGHT_BASE_OFFSET)
                           + URAM_ADDR_W'(beats_issued_q) * URAM_ADDR_W'(COMPUTE_WORDS));
        end else begin
            base_for_phase = '0;
        end

        rd_addr_next = URAM_ADDR_W'(base_for_phase + URAM_ADDR_W'(issue_idx_q));

        issue_now = in_fetch && pp.side_valid
                 && (issue_idx_q < words_needed)
                 && (in_flight_q < IFL_W'(MAX_INFLIGHT));

        pp.rd_en     = issue_now;
        pp.rd_addr   = rd_addr_next;
        pp.drain_ack = drain_ack_q;
    end

    assign capture_now = pp.rd_valid && in_fetch;
    always_comb begin
        ctrl.prog_acts  = prog_q;
        ctrl.prog_valid = prog_valid_q;
        ctrl.w_tiles    = w_q;
        ctrl.w_valid    = w_valid_q;
        ctrl.o_ready    = tlmm.busy;
    end
    logic prog_fire;
    logic w_fire;
    logic o_fire;
    logic last_out_beat;

    assign prog_fire     = ctrl.prog_valid && ctrl.prog_ready;
    assign w_fire        = ctrl.w_valid    && ctrl.w_ready;
    assign o_fire        = ctrl.o_valid    && ctrl.o_ready;
    assign last_out_beat = o_fire && (beats_out_q == (k_cnt_q - MACRO_CNT_W'(1)));

    assign tlmm.done = tlmm_done_q;
    assign result_valid = tlmm_done_q;
    tlmm_acc_t tlmm_acc_q [TLMM_LANES];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int ln = 0; ln < int'(TLMM_LANES); ln++) tlmm_acc_q[ln] <= '0;
        end else if (state_q == S_IDLE && state_d == S_PROG_FETCH) begin
            for (int ln = 0; ln < int'(TLMM_LANES); ln++) tlmm_acc_q[ln] <= '0;
        end else if (o_fire) begin
            for (int ln = 0; ln < int'(TLMM_LANES); ln++) begin
                tlmm_acc_q[ln] <= tlmm_acc_q[ln]
                                + tlmm_acc_t'($signed(ctrl.o_parts[ln]));
            end
        end
    end
    always_comb begin
        for (int ln = 0; ln < int'(TLMM_LANES); ln++) begin
            result_acc[ln] = tlmm_acc_q[ln];
        end
    end
    always_comb begin
        state_d = state_q;
        unique case (state_q)
            S_IDLE:       if (tlmm.start)    state_d = S_PROG_FETCH;
            S_PROG_FETCH: if (all_captured)  state_d = S_PROG_PRES;
            S_PROG_PRES:  if (prog_fire)     state_d = S_W_FETCH;
            S_W_FETCH:    if (all_captured)  state_d = S_W_PRES;
            S_W_PRES:     if (w_fire) begin
                              state_d = (beats_issued_q == (k_cnt_q - MACRO_CNT_W'(1)))
                                      ? S_DRAIN : S_W_FETCH;
                          end
            S_DRAIN:      if (last_out_beat) state_d = S_DONE;
            S_DONE:                          state_d = S_IDLE;
            default:                         state_d = S_IDLE;
        endcase
    end
    logic fetch_entry;
    assign fetch_entry = ((state_q != S_PROG_FETCH) && (state_d == S_PROG_FETCH))
                      || ((state_q != S_W_FETCH)    && (state_d == S_W_FETCH));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q        <= S_IDLE;
            k_cnt_q        <= '0;
            beats_issued_q <= '0;
            beats_out_q    <= '0;
            issue_idx_q    <= '0;
            capture_idx_q  <= '0;
            in_flight_q    <= '0;
            asm_q          <= '0;
            prog_q         <= '0;
            prog_valid_q   <= 1'b0;
            w_q            <= '0;
            w_valid_q      <= 1'b0;
            tlmm_done_q    <= 1'b0;
        end else begin
            state_q <= state_d;
            if (state_q == S_IDLE && state_d == S_PROG_FETCH) begin
                k_cnt_q        <= tlmm.k_cnt;
                beats_issued_q <= '0;
                beats_out_q    <= '0;
            end
            if (fetch_entry) begin
                issue_idx_q   <= '0;
                capture_idx_q <= '0;
                in_flight_q   <= '0;
            end else begin
                if (issue_now)   issue_idx_q   <= issue_idx_q   + WORDIDX_W'(1);
                if (capture_now) capture_idx_q <= capture_idx_q + WORDIDX_W'(1);
                in_flight_q <= in_flight_q
                             + (issue_now   ? IFL_W'(1) : IFL_W'(0))
                             - (capture_now ? IFL_W'(1) : IFL_W'(0));
            end
            if (capture_now) begin
                if (in_prog_fetch) begin
                    asm_q[capture_idx_q * PROG_BITS_PER_WORD +: PROG_BITS_PER_WORD]
                        <= pp.rd_data[PROG_BITS_PER_WORD-1:0];
                end else if (in_w_fetch) begin
                    asm_q[capture_idx_q * COMPUTE_BITS_PER_WORD +: COMPUTE_BITS_PER_WORD]
                        <= pp.rd_data[COMPUTE_BITS_PER_WORD-1:0];
                end
            end
            if (state_q == S_PROG_FETCH && state_d == S_PROG_PRES) begin
                for (int i = 0; i < int'(TLMM_TILE); i++) begin
                    prog_q[i] <= asm_q[i*BFP12_MANT_W +: BFP12_MANT_W];
                end
                prog_valid_q <= 1'b1;
            end
            if (state_q == S_PROG_PRES && prog_fire) begin
                prog_valid_q <= 1'b0;
            end
            if (state_q == S_W_FETCH && state_d == S_W_PRES) begin
                for (int l = 0; l < int'(TLMM_LANES); l++) begin
                    for (int t = 0; t < int'(TLMM_TILE); t++) begin
                        w_q[l][t] <= tern_weight_e'(
                            asm_q[(l*int'(TLMM_TILE) + t)*2 +: 2]
                        );
                    end
                end
                w_valid_q <= 1'b1;
            end
            if (state_q == S_W_PRES && w_fire) begin
                w_valid_q      <= 1'b0;
                beats_issued_q <= beats_issued_q + MACRO_CNT_W'(1);
            end
            if (o_fire) begin
                beats_out_q <= beats_out_q + MACRO_CNT_W'(1);
            end
            tlmm_done_q <= (state_d == S_DONE);
        end
    end

`ifndef SYNTHESIS
    a_in_flight_bound: assert property (
        @(posedge clk) disable iff (!rst_n) (in_flight_q <= IFL_W'(MAX_INFLIGHT))
    ) else $error("tlmm_driver: in_flight_q exceeded MAX_INFLIGHT");

    a_beats_issued_bound: assert property (
        @(posedge clk) disable iff (!rst_n)
        (state_q != S_IDLE) |-> (beats_issued_q <= k_cnt_q)
    ) else $error("tlmm_driver: beats_issued_q exceeded k_cnt_q");

    a_beats_out_bound: assert property (
        @(posedge clk) disable iff (!rst_n)
        (state_q != S_IDLE) |-> (beats_out_q <= k_cnt_q)
    ) else $error("tlmm_driver: beats_out_q exceeded k_cnt_q");

    a_done_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) tlmm.done |-> tlmm.busy
    ) else $error("tlmm_driver: done asserted while busy=0");
`endif

endmodule : tlmm_driver

`default_nettype wire
`endif
