// -----------------------------------------------------------------------------
// uram_cascade_adapter.sv
//
// Phase-7 bridge: presents a 2-x-cascaded URAM read view (DN_DATA_W bits, with
// DN_DATA_W = 2 * URAM_WIDTH_BITS) to the consumer (dense_act_streamer or
// tlmm_driver), backed by a native 72-b pingpong port owned by memory_manager.
//
// Why this exists
// ---------------
// memory_manager exposes pingpong_if at URAM_WIDTH_BITS = 72 b, the native
// width of one UltraRAM288 column. The Phase-5 streamer/driver were written
// against a 144-b cascaded view because BFP12 mantissa blocks (16 * 12 = 192 b)
// straddle two native words and the consumer FSMs are simpler when each fetch
// returns a wider beat. Rather than rewriting memory_manager (which would
// break the existing memory unit tests) we slot a thin adapter between the
// two sides that:
//
//   * Doubles every consumer-issued read into a pair of upstream native
//     reads at addresses (2*A, 2*A+1) -- "lo" then "hi".
//   * Pairs the two corresponding upstream responses (in URAM issue order)
//     into one DN_DATA_W beat, with native @2A in the LOW half and native
//     @2A+1 in the HIGH half.
//   * Forwards active_side / side_valid combinationally and the drain
//     handshake conservatively (see the drain section).
//
// Latency / bandwidth contract
// ----------------------------
// The adapter issues one upstream rd_en per cycle whenever it has a pending
// half-pair to dispatch and the consumer has pulsed rd_en. With back-to-back
// consumer reads it sustains one consumer beat every 2 cycles (i.e. it
// exactly halves the upstream sustained rate). Worst-case per-beat latency
// is upstream_latency + 1: native @ 2A returns at cycle T+L, native @ 2A+1
// at T+L+1, the paired DN beat is presented at T+L+1.
//
// The pingpong_if interface assertion
//   rd_valid |-> $past(rd_en, 1) || $past(rd_en, 2)
// allows upstream URAM latencies of either 1 or 2 cycles. This adapter
// pairs by issue order, not by absolute cycle, so both latency values are
// supported without parameterization.
//
// Drain safety
// ------------
// pingpong_if.drain_req fires only when the consuming core is between ops
// (the streamer/driver each sit in S_IDLE while the dispatcher executes
// OP_PINGPONG). When in IDLE neither has a read in flight, so the adapter
// trivially has no pending half-pair either; we therefore forward drain_req
// downstream combinationally and reflect drain_ack back upstream
// combinationally. A defensive assertion guards the "no pair in flight on
// drain_req" invariant.
//
// Resource class
// --------------
// * No DSP48E2.
// * No BRAM/URAM (storage lives in upstream uram_pingpong).
// * One small FSM, one capture register (URAM_WIDTH_BITS wide), a few flops.
//
// Boundary contract
// -----------------
//   up.<modport=core>     : adapter acts as the CORE toward memory_manager
//   dn.<modport=mem_mgr>  : adapter acts as the MEM_MGR toward the consumer
//
// The pingpong_if modport names reflect "who drives what", so the adapter
// owning the .core modport upstream means it drives rd_addr/rd_en/drain_ack
// up to the manager, which is exactly the role we need.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_URAM_CASCADE_ADAPTER_SV
`define ARCHBETTER_URAM_CASCADE_ADAPTER_SV
`default_nettype none

module uram_cascade_adapter
    import types_pkg::*;
#(
    parameter int unsigned UP_DATA_W = URAM_WIDTH_BITS,         // 72
    parameter int unsigned DN_DATA_W = 2 * URAM_WIDTH_BITS,     // 144
    parameter int unsigned UP_ADDR_W = URAM_ADDR_W,             // 12
    parameter int unsigned DN_ADDR_W = URAM_ADDR_W,             // 12 (consumer addresses cascaded words; high addr bit unused at top)
    // R6.8a-cont: number of consumer cascade reads the adapter can hold accepted-
    // but-not-fully-issued. The OLD design was effectively 2 (head + 1 pending) =
    // exactly one BFP beat (lo+hi), which made cross-beat prefetch impossible and
    // exposed the URAM round-trip latency on every beat. Deepening this lets a
    // prefetching consumer (dense_act_streamer) keep several beats' reads in flight
    // and hide the latency, approaching the native-throughput floor (1 cascade /
    // 2 cycles). Must be >= the consumer's max in-flight cascade reads. Measured:
    // depth 2->8 helped (II 12.3->10.3) but 8->16 did NOT (identical) -- beyond 8
    // the bottleneck is the DOWNSTREAM consume rate (dispatcher/NoC/array), not
    // fetch. 8 is the knee; deeper just wastes area.
    parameter int unsigned RD_DEPTH  = 8
) (
    input  wire logic       clk,
    input  wire logic       rst_n,

    // Upstream (toward memory_manager). Adapter is the .core.
    pingpong_if.core    up,

    // Downstream (toward streamer/driver). Adapter is the .mem_mgr.
    pingpong_if.mem_mgr dn
);

    // -------------------------------------------------------------------------
    // Elaboration sanity.
    // -------------------------------------------------------------------------
    initial begin : elab_checks
        if (DN_DATA_W != 2 * UP_DATA_W) begin
            $fatal(1, "uram_cascade_adapter: DN_DATA_W=%0d must equal 2*UP_DATA_W=%0d",
                   DN_DATA_W, 2 * UP_DATA_W);
        end
        if (UP_DATA_W != URAM_WIDTH_BITS) begin
            $fatal(1, "uram_cascade_adapter: UP_DATA_W=%0d != URAM_WIDTH_BITS=%0d (this adapter only doubles)",
                   UP_DATA_W, URAM_WIDTH_BITS);
        end
    end

    // =========================================================================
    // Issue side: split each downstream rd_en into a (lo, hi) pair upstream.
    //
    // We accept the consumer's rd_en as a request; the FIRST cycle of any
    // issued pair, we drive up.rd_en with addr = 2*A; the SECOND cycle (if no
    // new consumer rd_en arrived simultaneously, otherwise we still alternate
    // by phase), we drive up.rd_en with addr = 2*A_pending+1. A 1-deep pending
    // FIFO holds the next downstream addr while the previous pair completes
    // its issue phase. This keeps up.rd_en active every cycle the consumer is
    // back-to-back issuing, halving throughput as expected.
    // =========================================================================
    typedef enum logic {
        I_LO = 1'b0,  // next upstream issue is the LO of the front pair
        I_HI = 1'b1   // next upstream issue is the HI of the front pair
    } issue_phase_e;

    // R6.8a-cont: RD_DEPTH-deep address FIFO of accepted cascade reads, issued in
    // order (front pair's lo then hi, then the next pair). Replaces the old
    // head + 1-pending pair, lifting the cross-beat prefetch ceiling.
    localparam int unsigned PW = (RD_DEPTH > 1) ? $clog2(RD_DEPTH) : 1;

    logic [DN_ADDR_W-1:0]       addr_fifo [RD_DEPTH];  // consumer cascade addresses
    logic [PW-1:0]              afifo_wr_q, afifo_rd_q;
    logic [PW:0]               afifo_cnt_q;
    issue_phase_e              iss_phase_q;            // lo/hi of the FRONT pair

    logic afifo_full, afifo_empty;
    assign afifo_full  = (afifo_cnt_q == (PW+1)'(RD_DEPTH));
    assign afifo_empty = (afifo_cnt_q == '0);

    // Accept a new consumer read whenever the FIFO has room.
    logic accept_dn;
    assign accept_dn = dn.rd_en && !afifo_full;

    // Issue an upstream native every cycle the FIFO is non-empty.
    logic up_rd_en_now;
    assign up_rd_en_now = !afifo_empty;

    // A front pair finishes issuing when its HI native goes out -> pop the FIFO.
    logic do_pop;
    assign do_pop = up_rd_en_now && (iss_phase_q == I_HI);

    // Doubled upstream address (cascaded word index * 2, + lo/hi). Truncation via
    // UP_ADDR_W cast is safe: the consumer keeps cascaded addr < 2048 (asserted).
    logic [UP_ADDR_W-1:0] up_addr_now;
    always_comb begin
        up_addr_now = (iss_phase_q == I_LO)
                    ? UP_ADDR_W'(addr_fifo[afifo_rd_q] << 1)
                    : UP_ADDR_W'((addr_fifo[afifo_rd_q] << 1) + UP_ADDR_W'(1));
    end

    // =========================================================================
    // Capture side: pair upstream responses in issue order. The first response
    // of every pair lands in cap_lo_q; the second response is combined with
    // the latched lo on the same cycle and presented downstream.
    // =========================================================================
    typedef enum logic {
        C_LO = 1'b0,  // next response goes to cap_lo_q
        C_HI = 1'b1   // next response is the HI half; emit downstream beat
    } cap_phase_e;

    cap_phase_e               cap_phase_q;
    logic [UP_DATA_W-1:0]     cap_lo_q;
    logic                     dn_rd_valid_q;
    logic [DN_DATA_W-1:0]     dn_rd_data_q;

    // =========================================================================
    // Sequential.
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            iss_phase_q    <= I_LO;
            afifo_wr_q     <= '0;
            afifo_rd_q     <= '0;
            afifo_cnt_q    <= '0;

            cap_phase_q    <= C_LO;
            cap_lo_q       <= '0;
            dn_rd_valid_q  <= 1'b0;
            dn_rd_data_q   <= '0;
        end else begin
            // ---- Accept new consumer reads: push the cascade addr ------------
            if (accept_dn) begin
                addr_fifo[afifo_wr_q] <= dn.rd_addr;
                afifo_wr_q <= (afifo_wr_q == PW'(RD_DEPTH-1)) ? '0 : afifo_wr_q + 1'b1;
            end

            // ---- Issue front pair lo->hi; pop after hi -----------------------
            if (up_rd_en_now) begin
                if (iss_phase_q == I_LO) begin
                    iss_phase_q <= I_HI;
                end else begin
                    iss_phase_q <= I_LO;
                    afifo_rd_q  <= (afifo_rd_q == PW'(RD_DEPTH-1)) ? '0 : afifo_rd_q + 1'b1;
                end
            end

            // ---- FIFO occupancy (push - pop) ---------------------------------
            afifo_cnt_q <= afifo_cnt_q
                         + (accept_dn ? (PW+1)'(1) : (PW+1)'(0))
                         - (do_pop    ? (PW+1)'(1) : (PW+1)'(0));

            // ---- Capture upstream responses ---------------------------------
            // Default: drop any single-cycle valid we asserted last cycle.
            dn_rd_valid_q <= 1'b0;

            if (up.rd_valid) begin
                if (cap_phase_q == C_LO) begin
                    cap_lo_q    <= up.rd_data;
                    cap_phase_q <= C_HI;
                end else begin
                    // HI received: present a downstream beat now.
                    dn_rd_data_q  <= { up.rd_data, cap_lo_q };
                    dn_rd_valid_q <= 1'b1;
                    cap_phase_q   <= C_LO;
                end
            end
        end
    end

    // =========================================================================
    // Drive upstream pingpong port (we are .core upstream).
    // =========================================================================
    always_comb begin
        up.rd_en     = up_rd_en_now;
        up.rd_addr   = up_addr_now;
        // drain_ack is forwarded combinationally from the downstream consumer.
        // See drain discussion in the file header.
        up.drain_ack = dn.drain_ack;
    end

    // =========================================================================
    // Drive downstream pingpong port (we are .mem_mgr downstream).
    // =========================================================================
    always_comb begin
        dn.active_side = up.active_side;
        dn.side_valid  = up.side_valid;
        dn.rd_data     = dn_rd_data_q;
        dn.rd_valid    = dn_rd_valid_q;
        dn.drain_req   = up.drain_req;
    end

    // =========================================================================
    // Sim-only sanity assertions.
    // =========================================================================
`ifndef SYNTHESIS
    // No new dn.rd_en when the accept FIFO is full.
    a_no_dn_rden_when_full: assert property (
        @(posedge clk) disable iff (!rst_n)
        dn.rd_en |-> !afifo_full
    ) else $error("uram_cascade_adapter: dn.rd_en pulsed while accept FIFO full (depth %0d)", RD_DEPTH);

    // Upstream addressing must remain in range. dn.rd_addr is consumer-side
    // (cascaded word index); the doubled upstream address is at most
    // (2 * 2^(DN_ADDR_W-1)) - 1, but our DN_ADDR_W matches UP_ADDR_W = 12 and
    // upstream depth is 2^12 = 4096 native words. Therefore the consumer must
    // keep dn.rd_addr in [0, 2047] -- the high bit must be zero.
    a_dn_addr_top_bit_zero: assert property (
        @(posedge clk) disable iff (!rst_n)
        (dn.rd_en && (DN_ADDR_W >= 1)) |-> (dn.rd_addr[DN_ADDR_W-1] === 1'b0)
    ) else $error("uram_cascade_adapter: dn.rd_addr[%0d]=1; cascaded address out of upstream range",
                  DN_ADDR_W-1);

    // drain_req should only fire when the adapter has no in-flight pair.
    // (Streamer/driver are guaranteed IDLE when drain_req can rise.)
    a_drain_req_quiescent: assert property (
        @(posedge clk) disable iff (!rst_n)
        up.drain_req |-> (afifo_empty && (cap_phase_q == C_LO))
    ) else $error("uram_cascade_adapter: drain_req asserted while a cascade pair is in flight");

    // The pair-capture FSM must not desync: every dn.rd_valid we emit must
    // have been preceded by a HI capture.
    a_dn_valid_only_after_hi: assert property (
        @(posedge clk) disable iff (!rst_n)
        dn.rd_valid |-> $past(up.rd_valid, 1) && ($past(cap_phase_q, 1) == C_HI)
    ) else $error("uram_cascade_adapter: dn.rd_valid emitted without a HI-phase upstream response");
`endif

endmodule : uram_cascade_adapter

`default_nettype wire
`endif // ARCHBETTER_URAM_CASCADE_ADAPTER_SV
