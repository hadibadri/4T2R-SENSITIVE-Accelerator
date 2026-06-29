
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE_OUT_COLLECTOR_SV
`define ARCHBETTER_DENSE_OUT_COLLECTOR_SV
`default_nettype none

module dense_out_collector
    import types_pkg::*;
#(
    parameter int unsigned WR_DATA_W = URAM_WIDTH_BITS
) (
    input  wire logic                              clk,
    input  wire logic                              rst_n,

    input  wire logic                              y_valid,
    input  wire array_acc_t [DENSE_ARRAY_COLS-1:0] y_out,

    input  wire logic [URAM_ADDR_W-1:0]            wr_base_addr,

    output logic                                   wr_en,
    output logic [URAM_ADDR_W-1:0]                 wr_addr,
    output logic [WR_DATA_W-1:0]                   wr_data,

    dense2sparse_if.dense                          d2s,

    output logic                                   busy_o
);
    initial begin : elab_checks
        if (WR_DATA_W < ARRAY_ACC_W) begin
            $fatal(1, "dense_out_collector: WR_DATA_W=%0d < ARRAY_ACC_W=%0d",
                   WR_DATA_W, ARRAY_ACC_W);
        end
        if ((DENSE_ARRAY_COLS % BFP12_BLK) != 0) begin
            $fatal(1, "dense_out_collector: DENSE_ARRAY_COLS=%0d not a multiple of BFP12_BLK=%0d",
                   DENSE_ARRAY_COLS, BFP12_BLK);
        end
    end
    localparam int unsigned NUM_D2S_BEATS = DENSE_ARRAY_COLS / BFP12_BLK;
    localparam int unsigned URAM_CNT_W    = $clog2(DENSE_ARRAY_COLS + 1);
    localparam int unsigned D2S_CNT_W     = $clog2(NUM_D2S_BEATS + 1);
    localparam int unsigned MSB_POS_W     = $clog2(ARRAY_ACC_W + 1);
    array_acc_t y_out_q [DENSE_ARRAY_COLS];
    logic       have_snap_q;

    logic [URAM_CNT_W-1:0] uram_idx_q;
    logic                  uram_done;
    assign uram_done = (uram_idx_q == URAM_CNT_W'(DENSE_ARRAY_COLS));

    logic [URAM_ADDR_W-1:0] wr_base_addr_q;

    always_comb begin
        wr_en   = have_snap_q && !uram_done;
        wr_addr = URAM_ADDR_W'(wr_base_addr_q + URAM_ADDR_W'(uram_idx_q));
        wr_data = '0;
        if (wr_en) begin
            wr_data[ARRAY_ACC_W-1:0] = y_out_q[uram_idx_q[URAM_CNT_W-2:0]];
        end
    end
    function automatic logic [ARRAY_ACC_W-1:0] abs_val (input array_acc_t v);
        logic [ARRAY_ACC_W-1:0] raw;
        raw = v;
        return (v < 0) ? ((~raw) + 1'b1) : raw;
    endfunction

    function automatic logic [MSB_POS_W-1:0] find_msb_pos (
        input logic [ARRAY_ACC_W-1:0] w
    );
        logic [MSB_POS_W-1:0] pos;
        pos = '0;
        for (int b = ARRAY_ACC_W-1; b >= 0; b--) begin
            if (w[b]) begin
                pos = MSB_POS_W'(b);
                break;
            end
        end
        return pos;
    endfunction
    logic                         d2s_valid_q;
    logic [BFP12_BLK*BFP12_MANT_W-1:0] d2s_data_q;
    logic [BFP12_EXP_W-1:0]       d2s_user_q;
    logic                         d2s_last_q;

    logic stall;
    logic adv;
    assign stall = d2s_valid_q && !d2s.ready;
    assign adv   = !stall;

    assign d2s.valid = d2s_valid_q;
    assign d2s.data  = d2s_data_q;
    assign d2s.user  = d2s_user_q;
    assign d2s.last  = d2s_last_q;
    logic [D2S_CNT_W-1:0] d2s_issue_idx_q;
    logic                 issue_now;
    assign issue_now = have_snap_q
                    && (d2s_issue_idx_q != D2S_CNT_W'(NUM_D2S_BEATS))
                    && adv;
    logic                   s1_v_q;
    logic [D2S_CNT_W-1:0]   s1_idx_q;
    logic                   s1_last_q;
    array_acc_t             s1_blk_q  [BFP12_BLK];
    logic [ARRAY_ACC_W-1:0] s1_abs_q  [BFP12_BLK];

    array_acc_t             s1_blk_w  [BFP12_BLK];
    logic [ARRAY_ACC_W-1:0] s1_abs_w  [BFP12_BLK];
    always_comb begin
        for (int i = 0; i < int'(BFP12_BLK); i++) begin
            automatic int idx;
            idx = int'(d2s_issue_idx_q) * int'(BFP12_BLK) + i;
            s1_blk_w[i] = y_out_q[idx < int'(DENSE_ARRAY_COLS) ? idx : 0];
            s1_abs_w[i] = abs_val(s1_blk_w[i]);
        end
    end
    logic                   s2_v_q;
    logic                   s2_last_q;
    array_acc_t             s2_blk_q [BFP12_BLK];
    logic [ARRAY_ACC_W-1:0] s2_or_q;

    logic [ARRAY_ACC_W-1:0] s2_or_w;
    always_comb begin
        s2_or_w = '0;
        for (int i = 0; i < int'(BFP12_BLK); i++) begin
            s2_or_w = s2_or_w | s1_abs_q[i];
        end
    end
    logic            s3_v_q;
    logic            s3_last_q;
    array_acc_t      s3_blk_q [BFP12_BLK];
    bfp12_exp_t      s3_exp_q;

    logic [MSB_POS_W-1:0] s3_msb_w;
    bfp12_exp_t           s3_exp_w;
    always_comb begin
        s3_msb_w = find_msb_pos(s2_or_q);
        if (s3_msb_w > MSB_POS_W'(BFP12_MANT_W - 2)) begin
            s3_exp_w = bfp12_exp_t'(s3_msb_w - MSB_POS_W'(BFP12_MANT_W - 2));
        end else begin
            s3_exp_w = '0;
        end
    end
    logic         s4_v_q;
    logic         s4_last_q;
    bfp12_mant_t  s4_mants_q [BFP12_BLK];
    bfp12_exp_t   s4_exp_q;

    bfp12_mant_t  s4_mants_w [BFP12_BLK];
    always_comb begin
        for (int i = 0; i < int'(BFP12_BLK); i++) begin
            automatic array_acc_t shifted;
            shifted        = s3_blk_q[i] >>> s3_exp_q;
            s4_mants_w[i]  = bfp12_mant_t'(shifted);
        end
    end
    logic [BFP12_BLK*BFP12_MANT_W-1:0] s5_packed_w;
    always_comb begin
        s5_packed_w = '0;
        for (int i = 0; i < int'(BFP12_BLK); i++) begin
            s5_packed_w[i*BFP12_MANT_W +: BFP12_MANT_W] = s4_mants_q[i];
        end
    end
    logic pipeline_empty;
    assign pipeline_empty = !s1_v_q && !s2_v_q && !s3_v_q && !s4_v_q
                         && !d2s_valid_q;

    logic d2s_done;
    assign d2s_done = (d2s_issue_idx_q == D2S_CNT_W'(NUM_D2S_BEATS))
                   && pipeline_empty;

    logic both_done;
    assign both_done = uram_done && d2s_done;

    assign busy_o = have_snap_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < int'(DENSE_ARRAY_COLS); i++) y_out_q[i] <= '0;
            have_snap_q       <= 1'b0;
            uram_idx_q        <= '0;
            wr_base_addr_q    <= '0;
            d2s_issue_idx_q   <= '0;
            s1_v_q     <= 1'b0; s1_idx_q  <= '0; s1_last_q <= 1'b0;
            s2_v_q     <= 1'b0; s2_last_q <= 1'b0; s2_or_q  <= '0;
            s3_v_q     <= 1'b0; s3_last_q <= 1'b0; s3_exp_q <= '0;
            s4_v_q     <= 1'b0; s4_last_q <= 1'b0; s4_exp_q <= '0;
            for (int i = 0; i < int'(BFP12_BLK); i++) begin
                s1_blk_q[i] <= '0; s1_abs_q[i] <= '0;
                s2_blk_q[i] <= '0;
                s3_blk_q[i] <= '0;
                s4_mants_q[i] <= '0;
            end
            d2s_valid_q <= 1'b0;
            d2s_data_q  <= '0;
            d2s_user_q  <= '0;
            d2s_last_q  <= 1'b0;
        end else begin
            if (y_valid && !have_snap_q) begin
                for (int i = 0; i < int'(DENSE_ARRAY_COLS); i++) begin
                    y_out_q[i] <= y_out[i];
                end
                have_snap_q     <= 1'b1;
                uram_idx_q      <= '0;
                d2s_issue_idx_q <= '0;
                wr_base_addr_q  <= wr_base_addr;
            end
            if (wr_en) begin
                uram_idx_q <= uram_idx_q + URAM_CNT_W'(1);
            end
            if (adv) begin
                s1_v_q    <= issue_now;
                if (issue_now) begin
                    s1_idx_q  <= d2s_issue_idx_q;
                    s1_last_q <= (d2s_issue_idx_q == D2S_CNT_W'(NUM_D2S_BEATS - 1));
                    for (int i = 0; i < int'(BFP12_BLK); i++) begin
                        s1_blk_q[i] <= s1_blk_w[i];
                        s1_abs_q[i] <= s1_abs_w[i];
                    end
                    d2s_issue_idx_q <= d2s_issue_idx_q + D2S_CNT_W'(1);
                end
                s2_v_q    <= s1_v_q;
                s2_last_q <= s1_last_q;
                if (s1_v_q) begin
                    s2_or_q <= s2_or_w;
                    for (int i = 0; i < int'(BFP12_BLK); i++) begin
                        s2_blk_q[i] <= s1_blk_q[i];
                    end
                end
                s3_v_q    <= s2_v_q;
                s3_last_q <= s2_last_q;
                if (s2_v_q) begin
                    s3_exp_q <= s3_exp_w;
                    for (int i = 0; i < int'(BFP12_BLK); i++) begin
                        s3_blk_q[i] <= s2_blk_q[i];
                    end
                end
                s4_v_q    <= s3_v_q;
                s4_last_q <= s3_last_q;
                if (s3_v_q) begin
                    s4_exp_q <= s3_exp_q;
                    for (int i = 0; i < int'(BFP12_BLK); i++) begin
                        s4_mants_q[i] <= s4_mants_w[i];
                    end
                end
                d2s_valid_q <= s4_v_q;
                if (s4_v_q) begin
                    d2s_data_q  <= s5_packed_w;
                    d2s_user_q  <= s4_exp_q;
                    d2s_last_q  <= s4_last_q;
                end
            end
            if (have_snap_q && both_done) begin
                have_snap_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    a_no_snap_while_busy: assert property (
        @(posedge clk) disable iff (!rst_n)
        y_valid |-> !have_snap_q
    ) else $error("dense_out_collector: y_valid while still draining previous snap");
    int unsigned last_count_q;
    always_ff @(posedge clk) begin
        if (!rst_n)                                   last_count_q <= 0;
        else if (y_valid && !have_snap_q)             last_count_q <= 0;
        else if (d2s_valid_q && d2s.ready && d2s_last_q) last_count_q <= last_count_q + 1;
    end
    a_one_last_per_snap: assert property (
        @(posedge clk) disable iff (!rst_n)
        (d2s_valid_q && d2s.ready && d2s_last_q) |-> (last_count_q == 0)
    ) else $error("dense_out_collector: d2s.last pulsed more than once per snap");
`endif

endmodule : dense_out_collector

`default_nettype wire
`endif
