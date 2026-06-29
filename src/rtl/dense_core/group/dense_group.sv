// -----------------------------------------------------------------------------
// dense_group.sv
//
// One 16x16 grouped vector systolic tile. Computes
//
//    y[j]  =  Sigma_k  Sigma_i  a_k[i] * W[i,j]           j = 0..15
//
// over K BFP12 activation blocks against a stationary 16x16 weight plane.
// Per-PE accumulation runs inside dense_pe; the group adds a combinational
// 16-input column-reduction tree and a 1-stage output pipeline register.
//
// Dataflow per accepted stream beat:
//   * 16 mantissas unpack out of a_strm.data (row r -> bits [r*12 +: 12])
//   * each row's mantissa is multicast to all 16 PEs in that row
//   * every PE sees the same a_valid/acc_clr/acc_snap control this cycle
//
// Circuit-switched invariant: the group is a SINK on a multicast path, so it
// never asserts backpressure (a_strm.ready = 1'b1 always). The stream source
// is the NoC fabric and has already guaranteed all destinations are ready.
//
// Contract timing (symmetric with dense_pe; Phase-8 fused-MACC latency):
//   t0            : first beat, acc_clr=1   a_strm.valid=1
//   t1..tK-1      : subsequent beats         a_strm.valid=1, acc_clr=0
//   tK,tK+1,tK+2  : a_strm.valid=0                  (3 fused-MACC drain cycles)
//   tK+3          : acc_snap=1
//   tK+4          : dense_pe latches cell accumulator -> acc_out_valid pulses
//   tK+4          : group reduction captured into y_out, y_valid pulses
//
// Mutex contracts (asserted):
//   * w_we must not co-fire with an accepted activation beat
//   * acc_clr is only meaningful on an accepted beat
//   * acc_snap must not co-fire with an accepted beat (snap is post-drain)
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE_GROUP_SV
`define ARCHBETTER_DENSE_GROUP_SV
`default_nettype none

module dense_group
    import types_pkg::*;
#(
    parameter bit          ENABLE_NOISE_HOOKS = 1'b0,
    parameter int unsigned GROUP_ID           = 0
) (
    input  wire logic                                   clk,
    input  wire logic                                   rst_n,

    // Multicast activation stream sink (192b = 16 * BFP12_MANT_W per beat)
    strm_if.sink                                        a_strm,

    // Per-beat sideband control, co-driven by the caller with the stream beat
    input  wire logic                                   acc_clr,
    input  wire logic                                   acc_snap,

    // Snap mode (R6 / v2). Broadcast to every PE: PER_TOKEN (v1, acc_snap) vs
    // CONTINUOUS (v2, per-beat cell valid). Default-equivalent: when the caller
    // ties this to PER_TOKEN the group is bit-identical to its pre-R6 behavior.
    input  wire gemm_stream_mode_e                      stream_mode,

    // Weight programming (C1.5 parallel scan: one word = 8 PEs per beat).
    // w_addr is the base PE addr of the 8 (mult. of 8); w_in carries the 8
    // mantissas. A PE writes when its addr/8 matches w_addr/8.
    input  wire logic                                   w_we,
    input  wire logic [$clog2(DENSE_PE_PER_GROUP)-1:0]  w_addr,
    input  wire bfp12_mant_t [(BFP12_BLK/2)-1:0]        w_in,

    // 16-column group output, registered; y_valid is a 1-cycle pulse.
    // y_valid is driven from a local named register so the per-group valid
    // signal can be referenced by name in lint/waiver scopes.
    output group_acc_t [DENSE_GROUP_COLS-1:0]      y_out,
    output logic                                   y_valid
);

    localparam int unsigned PE_ADDR_W = $clog2(DENSE_PE_PER_GROUP);
    localparam int unsigned WSCAN     = BFP12_BLK / 2;        // 8 PEs per scan word
    localparam int unsigned SLOT_W    = $clog2(WSCAN);        // 3
    localparam int unsigned WGRP_W    = PE_ADDR_W - SLOT_W;   // 5 (word-group field)

    // -------------------------------------------------------------------------
    // Stream always-ready: the group is a multicast sink on a circuit-switched
    // fabric; upstream has guaranteed all destinations accept in lockstep.
    // -------------------------------------------------------------------------
    assign a_strm.ready = 1'b1;

    logic a_fire;
    assign a_fire = a_strm.valid && a_strm.ready;

    // -------------------------------------------------------------------------
    // Unpack the 16-mantissa activation block. Row r consumes bits [r*12 +:12].
    // -------------------------------------------------------------------------
    bfp12_mant_t [DENSE_GROUP_ROWS-1:0] a_vec;
    for (genvar r = 0; r < int'(DENSE_GROUP_ROWS); r++) begin : g_unpack
        assign a_vec[r] = a_strm.data[r*BFP12_MANT_W +: BFP12_MANT_W];
    end

    // -------------------------------------------------------------------------
    // PE grid. PE(r,c) holds W[r,c] and sees a_vec[r] as its activation.
    // -------------------------------------------------------------------------
    dense_acc_t [DENSE_GROUP_ROWS-1:0][DENSE_GROUP_COLS-1:0] pe_acc_out;
    logic       [DENSE_GROUP_ROWS-1:0][DENSE_GROUP_COLS-1:0] pe_acc_valid;

    for (genvar r = 0; r < int'(DENSE_GROUP_ROWS); r++) begin : g_row
        for (genvar c = 0; c < int'(DENSE_GROUP_COLS); c++) begin : g_col
            localparam int unsigned LOCAL_PE_IDX =
                r * DENSE_GROUP_COLS + c;

            localparam int unsigned PE_WORD = LOCAL_PE_IDX / WSCAN; // word-group
            localparam int unsigned PE_SLOT = LOCAL_PE_IDX % WSCAN; // slot in word

            logic pe_w_we;
            assign pe_w_we = w_we &&
                (w_addr[PE_ADDR_W-1:SLOT_W] == WGRP_W'(PE_WORD));

            dense_pe #(
                .ENABLE_NOISE_HOOKS (ENABLE_NOISE_HOOKS),
                .PE_ID              (GROUP_ID * DENSE_PE_PER_GROUP + LOCAL_PE_IDX)
            ) u_pe (
                .clk           (clk),
                .rst_n         (rst_n),
                .a_in          (a_vec[r]),
                .a_valid       (a_fire),
                .w_we          (pe_w_we),
                .w_in          (w_in[PE_SLOT]),
                .noise_rd_in   ('0),
                .acc_clr       (acc_clr && a_fire),
                .acc_snap      (acc_snap),
                .stream_mode   (stream_mode),
                .acc_out       (pe_acc_out[r][c]),
                .acc_out_valid (pe_acc_valid[r][c])
            );
        end
    end

    // -------------------------------------------------------------------------
    // Combinational column reduction: 16 dense_acc_t -> 1 group_acc_t per col.
    // Widening cast prevents overflow (see GROUP_ACC_W rationale in types_pkg).
    // -------------------------------------------------------------------------
    group_acc_t [DENSE_GROUP_COLS-1:0] col_sum;
    always_comb begin
        for (int c = 0; c < int'(DENSE_GROUP_COLS); c++) begin
            group_acc_t s;
            s = '0;
            for (int rr = 0; rr < int'(DENSE_GROUP_ROWS); rr++) begin
                s += group_acc_t'(pe_acc_out[rr][c]);
            end
            col_sum[c] = s;
        end
    end

    // -------------------------------------------------------------------------
    // Output pipeline register. All 256 PE acc_out_valid pulses rise together
    // (they share acc_snap), so sampling PE(0,0)'s valid is representative.
    // Per-group fanout of y_valid_q is bounded by array geometry (one consumer
    // in the array snap collector); the elab-time RFFH-1 advisory is
    // structurally over-counted on this generate-replicated pattern and is
    // waived in waivers.tcl rather than mitigated with a max_fanout decoration.
    // -------------------------------------------------------------------------
    logic any_pe_valid;
    assign any_pe_valid = pe_acc_valid[0][0];

    logic y_valid_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            y_out     <= '0;
            y_valid_q <= 1'b0;
        end else begin
            y_valid_q <= any_pe_valid;
            if (any_pe_valid) y_out <= col_sum;
        end
    end

    assign y_valid = y_valid_q;

    // -------------------------------------------------------------------------
    // Contract assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    a_no_wwe_with_afire: assert property (
        @(posedge clk) disable iff (!rst_n)
        !(w_we && a_fire)
    ) else $error("dense_group[%0d]: w_we during an activation beat", GROUP_ID);

    a_clr_requires_fire: assert property (
        @(posedge clk) disable iff (!rst_n)
        acc_clr |-> a_fire
    ) else $error("dense_group[%0d]: acc_clr without an accepted beat", GROUP_ID);

    a_no_snap_with_fire: assert property (
        @(posedge clk) disable iff (!rst_n)
        !(acc_snap && a_fire)
    ) else $error("dense_group[%0d]: acc_snap co-fired with an activation beat", GROUP_ID);
`endif

endmodule : dense_group

`default_nettype wire
`endif // ARCHBETTER_DENSE_GROUP_SV
