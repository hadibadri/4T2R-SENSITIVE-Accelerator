// -----------------------------------------------------------------------------
// csd_drain_engine.sv
//
// Phase-5e bridge: drains a region of the on-chip OUTPUT URAM back to off-chip
// DRAM, the inverse direction of csd_engine. Driven by OP_ST_OUT through the
// memory_manager: a descriptor specifies the (uram_base, dram_base, n_beats)
// triple, and the engine streams those beats out on csd_dram_wr_if.
//
// Why a separate module from csd_engine:
//   csd_engine is unidirectional (DRAM -> URAM) and shares the inbound DRAM
//   read interface. Drain traffic goes the OTHER way (URAM -> DRAM write
//   data path), so it needs its own master interface (csd_dram_wr_if) and a
//   different counter pattern (it issues URAM reads, not DRAM reads). Folding
//   the two into one engine would muddy the FSM and make the pin map noisy
//   in the SoC top - keeping them split keeps each module under the
//   "single-purpose" rule.
//
// Phase 5 limitation:
//   * No compression on the way out (parity with csd_engine pass-through).
//     desc.compressed must be 0; sim asserts this.
//   * Single-descriptor at a time. The memory_manager FSM serializes.
//
// Throughput contract:
//   The URAM read pipe has a 2-cycle latency. We keep up to 2 outstanding
//   reads (issued - received <= 2) and stage responses in a 2-deep skid
//   register so a stalled wd_ready does not waste URAM read slots. In steady
//   state with wd_ready=1 we sustain 1 beat/cycle.
//
// FSM:
//   S_IDLE   : waiting for a descriptor handshake.
//   S_REQ    : present the DRAM write request; wait for req_ready.
//   S_STREAM : interleave URAM reads with wd handshakes until n_beats pushed.
//   S_DONE   : 1-cycle done pulse, return to IDLE.
//
// Resource class:
//   * No DSP48E2.
//   * No URAM/BRAM/LUTRAM owned by this module - URAM lives in the
//     memory_manager wrapper; this engine only reads it.
//   * A handful of fabric flops for FSM + counters + a 2-deep data skid.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_CSD_DRAIN_ENGINE_SV
`define ARCHBETTER_CSD_DRAIN_ENGINE_SV
`default_nettype none

module csd_drain_engine
    import types_pkg::*;
#(
    parameter int unsigned URAM_DATA_W = URAM_WIDTH_BITS  // 72; matches DRAM_BEAT_W
) (
    input  wire logic                    clk,
    input  wire logic                    rst_n,

    // Descriptor handshake (memory_manager presents one ST_OUT desc at a time).
    input  wire csd_descriptor_t         desc_i,
    input  wire logic                    desc_valid_i,
    output logic                         desc_ready_o,

    // 1-cycle pulse: descriptor fully drained (last beat accepted by DRAM).
    output logic                         done_o,

    // URAM read port (output URAM region inside memory_manager).
    output logic                         rd_en_o,
    output logic [URAM_ADDR_W-1:0]       rd_addr_o,
    input  wire logic                    rd_valid_i,
    input  wire logic [URAM_DATA_W-1:0]  rd_data_i,

    // DRAM write master.
    csd_dram_wr_if.mgr                   dram_wr
);

    // -------------------------------------------------------------------------
    // Elaboration consistency.
    // -------------------------------------------------------------------------
    initial begin : elab_checks
        if (URAM_DATA_W != DRAM_BEAT_W) begin
            $fatal(1, "csd_drain_engine: URAM_DATA_W=%0d must equal DRAM_BEAT_W=%0d",
                   URAM_DATA_W, DRAM_BEAT_W);
        end
    end

    // -------------------------------------------------------------------------
    // FSM.
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE   = 2'd0,
        S_REQ    = 2'd1,
        S_STREAM = 2'd2,
        S_DONE   = 2'd3
    } state_e;
    state_e state_q, state_d;

    csd_descriptor_t       desc_q;
    logic [DRAM_LEN_W-1:0] issued_q;     // URAM reads issued so far
    // (received_q removed — was a tracking counter with no reader and no
    // assertion consuming it; Synth 8-6014 was correctly flagging dead state.
    // If a future debug assertion needs "URAM responses captured so far",
    // re-introduce it as a `ifndef SYNTHESIS counter scoped to the assertion.)
    logic [DRAM_LEN_W-1:0] pushed_q;     // wd beats accepted so far

    // 2-deep skid for URAM responses awaiting a wd slot. slot[0] is head.
    logic [URAM_DATA_W-1:0] skid_q [0:1];
    logic [1:0]             skid_count_q;

    // Handshake fires.
    logic desc_fire;
    logic req_fire;
    logic wd_fire;
    logic capture_now;
    logic in_flight_full;

    assign desc_fire   = desc_valid_i && desc_ready_o;
    assign req_fire    = dram_wr.req_valid && dram_wr.req_ready;
    assign wd_fire     = dram_wr.wd_valid && dram_wr.wd_ready;
    assign capture_now = (state_q == S_STREAM) && rd_valid_i;

    // Total commitments waiting for a wd slot = (issued - pushed). Bound by 2
    // (=skid capacity) so a URAM response always has room.
    logic [DRAM_LEN_W-1:0] outstanding;
    assign outstanding    = DRAM_LEN_W'(issued_q - pushed_q);
    assign in_flight_full = (outstanding >= DRAM_LEN_W'(2));

    logic issue_now;
    assign issue_now = (state_q == S_STREAM)
                     && (issued_q < desc_q.n_beats)
                     && !in_flight_full;

    // -------------------------------------------------------------------------
    // Outputs.
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Next-state.
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Sequential.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q      <= S_IDLE;
            desc_q       <= '0;
            issued_q     <= '0;
            // received_q removed — see header comment
            pushed_q     <= '0;
            skid_count_q <= 2'd0;
            skid_q[0]    <= '0;
            skid_q[1]    <= '0;
        end else begin
            state_q <= state_d;

            // Op start: latch desc, clear counters.
            if (desc_fire) begin
                desc_q       <= desc_i;
                issued_q     <= '0;
                // received_q removed — see header comment
                pushed_q     <= '0;
                skid_count_q <= 2'd0;
            end

            // Issue counter.
            if (issue_now) begin
                issued_q <= DRAM_LEN_W'(issued_q + 1'b1);
            end

            // Skid + push/capture book-keeping.
            unique case ({capture_now, wd_fire})
                2'b10: begin
                    // Capture only.
                    if (skid_count_q == 2'd0) begin
                        skid_q[0] <= rd_data_i;
                    end else begin
                        skid_q[1] <= rd_data_i;
                    end
                    skid_count_q <= 2'(skid_count_q + 1'b1);
                    // received_q tracking removed (dead counter; see header)
                end
                2'b01: begin
                    // Push only -- shift slot1 -> slot0.
                    skid_q[0]    <= skid_q[1];
                    skid_count_q <= 2'(skid_count_q - 1'b1);
                    pushed_q     <= DRAM_LEN_W'(pushed_q + 1'b1);
                end
                2'b11: begin
                    // Simultaneous push + capture: net change to skid_count = 0.
                    if (skid_count_q == 2'd1) begin
                        skid_q[0] <= rd_data_i;
                    end else begin
                        // skid_count_q == 2 : slot0 shifts out, slot1 -> slot0,
                        // new capture fills slot1.
                        skid_q[0] <= skid_q[1];
                        skid_q[1] <= rd_data_i;
                    end
                    // received_q tracking removed (see header)
                    pushed_q   <= DRAM_LEN_W'(pushed_q   + 1'b1);
                end
                default: ;
            endcase
        end
    end

`ifndef SYNTHESIS
    // -------------------------------------------------------------------------
    // Sim-only sanity asserts.
    // -------------------------------------------------------------------------

    // Phase-5 compression contract (parity with csd_engine).
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
`endif // ARCHBETTER_CSD_DRAIN_ENGINE_SV
