// -----------------------------------------------------------------------------
// csd_engine.sv
//
// Compressed Sparse Dense (CSD) engine - Phase 2 PASS-THROUGH variant.
//
// Role:
//   The CSD engine is the single DRAM consumer in the memory subsystem. It
//   accepts one `csd_descriptor_t` at a time from the Memory Manager, issues
//   the corresponding read on `csd_dram_if`, and streams returned beats into
//   the URAM fill port (one DRAM beat = one URAM word, by the DRAM_BEAT_W ==
//   URAM_WIDTH_BITS invariant in types_pkg).
//
//   The descriptor's `is_sparse` field is forwarded as `fill_is_sparse_o` so
//   the Memory Manager can demux the fill traffic to either the dense or the
//   sparse ping-pong pair. The engine itself is pool-agnostic.
//
// Phase 2 limitation:
//   The `compressed` field of the descriptor MUST be 0. A real RLE / CSD
//   front-end will land in Phase 2.5 once we have a workload to calibrate
//   against. Until then, the wire format is sized for compression but the
//   data path is a straight pipe: rsp_data is written verbatim into URAM at
//   `desc.uram_base + offset` for each accepted beat. We assert (sim-only)
//   that `compressed` is 0 on every accepted descriptor.
//
// Latency contract:
//   From `desc_valid && desc_ready` to `done` =
//      1 (capture) + (req_ready stalls) + n_beats + 1 (DONE pulse)
//
// FSM:
//   S_IDLE -> S_REQ on descriptor handshake
//   S_REQ  -> S_RESP on req_valid && req_ready
//   S_RESP -> S_DONE on rsp_valid && rsp_ready && rsp_last
//   S_DONE -> S_IDLE always (1-cycle pulse on done_o)
//
// Backpressure:
//   * The URAM write port has no flow control (fabric flop write), so the
//     engine drives `dram.rsp_ready = 1` at all times in S_RESP. There is no
//     scenario where the URAM cannot accept a beat - the only constraint is
//     the URAM's own read-write same-address rule, which the manager owns.
//
// Resource class:
//   A handful of fabric flops (FSM, latched descriptor, beat counter). Zero
//   DSPs, BRAMs, URAMs, LUTRAMs.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_CSD_ENGINE_SV
`define ARCHBETTER_CSD_ENGINE_SV
`default_nettype none
`timescale 1ns/1ps

module csd_engine
    import types_pkg::*;
#(
    parameter int unsigned URAM_DATA_W = URAM_WIDTH_BITS  // 72; matches DRAM_BEAT_W
) (
    input  wire logic                  clk,
    input  wire logic                  rst_n,

    // Descriptor input from the Memory Manager.
    input  wire csd_descriptor_t       desc_i,
    input  wire logic                  desc_valid_i,
    output logic                       desc_ready_o,

    // 1-cycle pulse: descriptor fully serviced (last beat written to URAM).
    output logic                       done_o,

    // DRAM stub master.
    csd_dram_if.mgr                    dram,

    // URAM fill output (Memory Manager demuxes by fill_is_sparse_o into the
    // selected ping-pong pair's fill port).
    output logic                       fill_wr_en_o,
    output logic [URAM_ADDR_W-1:0]     fill_wr_addr_o,
    output logic [URAM_DATA_W-1:0]     fill_wr_data_o,
    output logic                       fill_is_sparse_o
);

    // -------------------------------------------------------------------------
    // Elaboration-time consistency.
    // -------------------------------------------------------------------------
    initial begin : elab_checks
        if (URAM_DATA_W != DRAM_BEAT_W) begin
            $fatal(1, "csd_engine: URAM_DATA_W=%0d must equal DRAM_BEAT_W=%0d",
                   URAM_DATA_W, DRAM_BEAT_W);
        end
    end

    // -------------------------------------------------------------------------
    // FSM.
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE = 2'b00,
        S_REQ  = 2'b01,
        S_RESP = 2'b10,
        S_DONE = 2'b11
    } state_e;

    state_e state_q, state_d;

    csd_descriptor_t       desc_q;
    logic [URAM_ADDR_W-1:0] offset_q;   // counts URAM words written this descriptor

    // Handshake fires (combinational).
    logic desc_fire;
    logic req_fire;
    logic beat_fire;
    logic last_beat_fire;

    assign desc_fire      = desc_valid_i && desc_ready_o;
    assign req_fire       = dram.req_valid && dram.req_ready;
    assign beat_fire      = dram.rsp_valid && dram.rsp_ready;
    assign last_beat_fire = beat_fire && dram.rsp_last;

    always_comb begin
        state_d = state_q;
        unique case (state_q)
            S_IDLE: if (desc_fire)      state_d = S_REQ;
            S_REQ:  if (req_fire)       state_d = S_RESP;
            S_RESP: if (last_beat_fire) state_d = S_DONE;
            S_DONE:                     state_d = S_IDLE;
            default:                    state_d = S_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q  <= S_IDLE;
            desc_q   <= '0;
            offset_q <= '0;
        end else begin
            state_q <= state_d;

            if (desc_fire) begin
                desc_q   <= desc_i;
                offset_q <= '0;
            end else if (beat_fire) begin
                offset_q <= URAM_ADDR_W'(offset_q + 1'b1);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Outputs.
    //   desc_ready_o : combinational, high only in S_IDLE.
    //   dram.req_*   : combinational from desc_q while in S_REQ.
    //   dram.rsp_ready : 1 in S_RESP (URAM never stalls).
    //   fill_wr_*    : combinational write fired on every accepted beat.
    //   fill_is_sparse_o : pass-through of desc_q.is_sparse, valid through
    //                      the entire fill (including S_DONE so the manager
    //                      sees a coherent value when capturing done_o).
    //   done_o       : 1-cycle pulse, registered (= state in S_DONE).
    // -------------------------------------------------------------------------
    assign desc_ready_o = (state_q == S_IDLE);

    assign dram.req_addr  = desc_q.dram_base;
    assign dram.req_len   = desc_q.n_beats;
    assign dram.req_valid = (state_q == S_REQ);
    assign dram.rsp_ready = (state_q == S_RESP);

    assign fill_wr_en_o     = beat_fire;
    assign fill_wr_addr_o   = URAM_ADDR_W'(desc_q.uram_base + offset_q);
    assign fill_wr_data_o   = dram.rsp_data;
    assign fill_is_sparse_o = desc_q.is_sparse;

    // done_o is one cycle wide whenever state_q sits in S_DONE.
    assign done_o = (state_q == S_DONE);

    // -------------------------------------------------------------------------
    // Simulation-only sanity checks.
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    // Phase 2 contract: compressed must be 0.
    property p_phase2_no_compression;
        @(posedge clk) disable iff (!rst_n)
        desc_fire |-> (desc_i.compressed == 1'b0);
    endproperty
    a_phase2_no_compression: assert property (p_phase2_no_compression)
        else $error("csd_engine: descriptor with compressed=1 (Phase 2 is pass-through)");

    // n_beats must be non-zero (csd_dram_if also asserts this on the request,
    // but we want to fail at descriptor capture, not deep in the response).
    property p_nonzero_len;
        @(posedge clk) disable iff (!rst_n)
        desc_fire |-> (desc_i.n_beats != '0);
    endproperty
    a_nonzero_len: assert property (p_nonzero_len)
        else $error("csd_engine: descriptor with n_beats=0");

    // beat_fire only valid in S_RESP.
    property p_beat_only_in_resp;
        @(posedge clk) disable iff (!rst_n)
        beat_fire |-> (state_q == S_RESP);
    endproperty
    a_beat_only_in_resp: assert property (p_beat_only_in_resp)
        else $error("csd_engine: rsp_valid && rsp_ready outside S_RESP");

    // The DRAM slave must terminate the burst at exactly n_beats.
    // Counts the accepted beats; on rsp_last the count must match desc_q.n_beats.
    logic [DRAM_LEN_W-1:0] beats_accepted_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            beats_accepted_q <= '0;
        end else begin
            if (desc_fire)         beats_accepted_q <= '0;
            else if (beat_fire)    beats_accepted_q <= DRAM_LEN_W'(beats_accepted_q + 1'b1);
        end
    end

    property p_last_at_correct_count;
        @(posedge clk) disable iff (!rst_n)
        last_beat_fire |-> (DRAM_LEN_W'(beats_accepted_q + 1'b1) == desc_q.n_beats);
    endproperty
    a_last_at_correct_count: assert property (p_last_at_correct_count)
        else $error("csd_engine: rsp_last fired at wrong beat count (expected %0d, got %0d+1)",
                    desc_q.n_beats, beats_accepted_q);
`endif

endmodule : csd_engine

`default_nettype wire
`endif // ARCHBETTER_CSD_ENGINE_SV
