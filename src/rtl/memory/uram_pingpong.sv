// -----------------------------------------------------------------------------
// uram_pingpong.sv
//
// Quad-URAM ping-pong PAIR (one half of the four-bank pool — instantiated twice
// at the memory_manager level: one pair for the Dense Core, one pair for the
// Sparse Core). Wraps two `uram_bank` primitives and a tiny swap FSM.
//
// Roles:
//   - One bank is the "compute side": its read port is multiplexed onto the
//     `pingpong_if.mem_mgr` modport that the consuming compute core sees.
//   - The other bank is the "fill side": its write port is multiplexed onto
//     the dedicated `fill_wr_*` port that the CSD engine drives.
//
// Swap protocol (drain handshake):
//   - Memory manager pulses `swap_req` (1 cycle) when the fill bank is full
//     and the compute bank is consumed enough that a ping-pong is desired.
//   - This module asserts `core.drain_req` on the next cycle and holds it.
//   - Core finishes any in-flight reads, drains its rd_valid pipeline, and
//     pulses `core.drain_ack` (1 cycle) when it is safe to swap.
//   - On the cycle AFTER drain_ack, this module:
//       * flips `compute_side_q`
//       * deasserts `core.drain_req`
//       * pulses `swap_done` (1 cycle) back to the memory manager.
//
// What this module does NOT own:
//   - Whether the fill bank is actually full (CSD/memory-manager bookkeeping).
//   - Read-port pacing on the compute side (the consuming core's job).
//   - Cross-pair coordination with the sparse pair (memory_manager's job).
//
// Latency contract (for downstream timing budgets):
//   - Read latency through the active bank is the same 2 cycles that
//     `uram_bank` documents (URAM read pipe + OREG); the read mux is purely
//     combinational and adds no cycles.
//   - From `swap_req` to `swap_done` = 2 cycles + (drain wait) cycles, where
//     "drain wait" is the time the core takes to ack.
//
// Resource class:
//   - 2 x URAM288 (one per bank).
//   - Zero DSPs, zero BRAMs, zero LUTRAM.
//   - A handful of fabric flops for the FSM and the side register.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_URAM_PINGPONG_SV
`define ARCHBETTER_URAM_PINGPONG_SV
`default_nettype none
`timescale 1ns/1ps

module uram_pingpong
    import types_pkg::*;
#(
    parameter int unsigned DATA_W = URAM_WIDTH_BITS,  // 72 (total width = WIDE*72)
    parameter int unsigned DEPTH  = URAM_DEPTH,       // 4096
    parameter int unsigned ADDR_W = URAM_ADDR_W,      // 12
    // R6.8b: URAM288 leaves side-by-side per bank (wide read). WIDE=1 legacy;
    // WIDE=3 (DATA_W=216) = dense-activation wide read. Passed to both uram_banks.
    parameter int unsigned WIDE   = 1,
    parameter bank_sel_e   INIT_COMPUTE_SIDE = BANK_A
) (
    input  wire logic              clk,
    input  wire logic              rst_n,

    // Compute-side read port (exposed to the consuming core).
    pingpong_if.mem_mgr            core,

    // Fill-side write port (driven by the CSD engine).
    input  wire logic              fill_wr_en,
    input  wire logic [ADDR_W-1:0] fill_wr_addr,
    input  wire logic [DATA_W-1:0] fill_wr_data,

    // Swap control (driven by the memory manager).
    input  wire logic              swap_req,    // 1-cycle pulse
    output logic                   swap_done,   // 1-cycle pulse on side flip

    // State observation (for the memory manager / dispatcher status read).
    output bank_sel_e              compute_side_o,
    output bank_sel_e              fill_side_o
);

    // -------------------------------------------------------------------------
    // Elaboration-time consistency.
    // -------------------------------------------------------------------------
    initial begin : elab_checks
        if (DATA_W / WIDE > URAM_WIDTH_BITS) begin
            $fatal(1, "uram_pingpong: per-leaf width %0d (DATA_W/WIDE) exceeds URAM primitive width (%0d)",
                   DATA_W / WIDE, URAM_WIDTH_BITS);
        end
        if (DATA_W % WIDE != 0) begin
            $fatal(1, "uram_pingpong: DATA_W=%0d not divisible by WIDE=%0d", DATA_W, WIDE);
        end
        if (ADDR_W != $clog2(DEPTH)) begin
            $fatal(1, "uram_pingpong: ADDR_W=%0d inconsistent with DEPTH=%0d",
                   ADDR_W, DEPTH);
        end
    end

    // -------------------------------------------------------------------------
    // Side register + swap FSM.
    //
    // Two-state FSM: SWAP_IDLE, SWAP_DRAIN.
    //   IDLE  -> DRAIN on swap_req (registered drain_req goes high next cycle).
    //   DRAIN -> IDLE on core.drain_ack (registered side flip + swap_done pulse
    //           happen on the cycle the FSM returns to IDLE).
    // -------------------------------------------------------------------------
    typedef enum logic {
        SWAP_IDLE  = 1'b0,
        SWAP_DRAIN = 1'b1
    } swap_state_e;

    swap_state_e state_q, state_d;
    bank_sel_e   compute_side_q;
    logic        drain_req_q;
    logic        swap_done_q;

    always_comb begin
        state_d = state_q;
        unique case (state_q)
            SWAP_IDLE:  if (swap_req)         state_d = SWAP_DRAIN;
            SWAP_DRAIN: if (core.drain_ack)   state_d = SWAP_IDLE;
            default: state_d = SWAP_IDLE;
        endcase
    end

    // The "flip cycle" is the transition DRAIN -> IDLE: the next-state value
    // of state is IDLE while the current-state value is still DRAIN.
    logic flip_cycle;
    assign flip_cycle = (state_q == SWAP_DRAIN) && (state_d == SWAP_IDLE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q        <= SWAP_IDLE;
            compute_side_q <= INIT_COMPUTE_SIDE;
            drain_req_q    <= 1'b0;
            swap_done_q    <= 1'b0;
        end else begin
            state_q     <= state_d;
            // drain_req is the level encoding of "we are draining" — high while
            // FSM sits in SWAP_DRAIN, low otherwise.
            drain_req_q <= (state_d == SWAP_DRAIN);
            // swap_done is a one-cycle pulse on the flip cycle.
            swap_done_q <= flip_cycle;
            if (flip_cycle) begin
                compute_side_q <= (compute_side_q == BANK_A) ? BANK_B : BANK_A;
            end
        end
    end

    // Combinational view of the fill side (always the opposite of compute).
    bank_sel_e fill_side_w;
    assign fill_side_w = (compute_side_q == BANK_A) ? BANK_B : BANK_A;

    assign compute_side_o = compute_side_q;
    assign fill_side_o    = fill_side_w;

    // -------------------------------------------------------------------------
    // Bank instantiation: two `uram_bank` primitives.
    // -------------------------------------------------------------------------
    logic              bankA_wr_en;
    logic [ADDR_W-1:0] bankA_wr_addr;
    logic [DATA_W-1:0] bankA_wr_data;
    logic              bankA_rd_en;
    logic [ADDR_W-1:0] bankA_rd_addr;
    logic              bankA_rd_valid;
    logic [DATA_W-1:0] bankA_rd_data;

    logic              bankB_wr_en;
    logic [ADDR_W-1:0] bankB_wr_addr;
    logic [DATA_W-1:0] bankB_wr_data;
    logic              bankB_rd_en;
    logic [ADDR_W-1:0] bankB_rd_addr;
    logic              bankB_rd_valid;
    logic [DATA_W-1:0] bankB_rd_data;

    uram_bank #(
        .DATA_W(DATA_W),
        .DEPTH (DEPTH),
        .ADDR_W(ADDR_W),
        .WIDE  (WIDE)
    ) u_bank_a (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (bankA_wr_en),
        .wr_addr (bankA_wr_addr),
        .wr_data (bankA_wr_data),
        .rd_en   (bankA_rd_en),
        .rd_addr (bankA_rd_addr),
        .rd_valid(bankA_rd_valid),
        .rd_data (bankA_rd_data)
    );

    uram_bank #(
        .DATA_W(DATA_W),
        .DEPTH (DEPTH),
        .ADDR_W(ADDR_W),
        .WIDE  (WIDE)
    ) u_bank_b (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (bankB_wr_en),
        .wr_addr (bankB_wr_addr),
        .wr_data (bankB_wr_data),
        .rd_en   (bankB_rd_en),
        .rd_addr (bankB_rd_addr),
        .rd_valid(bankB_rd_valid),
        .rd_data (bankB_rd_data)
    );

    // -------------------------------------------------------------------------
    // Read mux: compute side bank's read port is driven by core.rd_*.
    // The other bank's read port is held quiescent (rd_en=0).
    // -------------------------------------------------------------------------
    always_comb begin
        bankA_rd_en   = 1'b0;
        bankA_rd_addr = '0;
        bankB_rd_en   = 1'b0;
        bankB_rd_addr = '0;
        unique case (compute_side_q)
            BANK_A: begin
                bankA_rd_en   = core.rd_en;
                bankA_rd_addr = core.rd_addr;
            end
            BANK_B: begin
                bankB_rd_en   = core.rd_en;
                bankB_rd_addr = core.rd_addr;
            end
            default: begin
                bankA_rd_en   = 1'b0;
                bankA_rd_addr = '0;
                bankB_rd_en   = 1'b0;
                bankB_rd_addr = '0;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Write mux: the fill-side bank gets fill_wr_*. The compute-side bank's
    // write port is held quiescent. This is the contract that lets the CSD
    // engine refill in the background without disturbing the active core.
    // -------------------------------------------------------------------------
    always_comb begin
        bankA_wr_en   = 1'b0;
        bankA_wr_addr = '0;
        bankA_wr_data = '0;
        bankB_wr_en   = 1'b0;
        bankB_wr_addr = '0;
        bankB_wr_data = '0;
        unique case (fill_side_w)
            BANK_A: begin
                bankA_wr_en   = fill_wr_en;
                bankA_wr_addr = fill_wr_addr;
                bankA_wr_data = fill_wr_data;
            end
            BANK_B: begin
                bankB_wr_en   = fill_wr_en;
                bankB_wr_addr = fill_wr_addr;
                bankB_wr_data = fill_wr_data;
            end
            default: begin
                bankA_wr_en   = 1'b0;
                bankA_wr_addr = '0;
                bankA_wr_data = '0;
                bankB_wr_en   = 1'b0;
                bankB_wr_addr = '0;
                bankB_wr_data = '0;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Read-data mux back to the core. The URAM read pipeline is internal to
    // each bank; we just steer the registered output of the active bank onto
    // pingpong_if.{rd_data,rd_valid}.
    //
    // Note: when a swap happens, any rd_valid that was in flight on the OLD
    // bank is by contract "drained" by the core before drain_ack — we will
    // never see a stale rd_valid land after the flip. The asserts in
    // pingpong_if pin this contract.
    // -------------------------------------------------------------------------
    logic              core_rd_data_mux_valid;
    logic [DATA_W-1:0] core_rd_data_mux;

    always_comb begin
        unique case (compute_side_q)
            BANK_A: begin
                core_rd_data_mux       = bankA_rd_data;
                core_rd_data_mux_valid = bankA_rd_valid;
            end
            BANK_B: begin
                core_rd_data_mux       = bankB_rd_data;
                core_rd_data_mux_valid = bankB_rd_valid;
            end
            default: begin
                core_rd_data_mux       = '0;
                core_rd_data_mux_valid = 1'b0;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Drive the pingpong_if.mem_mgr modport.
    //   active_side : the live compute side (combinational view of the reg).
    //   side_valid  : the read mux is always coherent in this design — the
    //                 mux always points at one well-defined bank — so we hold
    //                 it high after reset. The DRAIN-state hint to the core
    //                 is `drain_req`, not `side_valid`.
    //   rd_data     : muxed registered URAM output of the active bank.
    //   rd_valid    : muxed registered URAM rd_valid of the active bank.
    //   drain_req   : registered FSM output (level high during SWAP_DRAIN).
    // -------------------------------------------------------------------------
    assign core.active_side = compute_side_q;
    assign core.side_valid  = rst_n;             // only low during async-clear
    assign core.rd_data     = core_rd_data_mux;
    assign core.rd_valid    = core_rd_data_mux_valid;
    assign core.drain_req   = drain_req_q;

    assign swap_done = swap_done_q;

    // -------------------------------------------------------------------------
    // Simulation-only sanity checks. These are local to the wrapper; the
    // pingpong_if asserts cover the cross-module handshake.
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    // Should not see drain_ack when we are not asking for a drain.
    property p_ack_only_in_drain;
        @(posedge clk) disable iff (!rst_n)
        core.drain_ack |-> (state_q == SWAP_DRAIN);
    endproperty
    a_ack_only_in_drain: assert property (p_ack_only_in_drain)
        else $error("uram_pingpong: drain_ack while FSM not in SWAP_DRAIN");

    // swap_req must not arrive while a previous swap is still in flight.
    property p_no_overlapping_swaps;
        @(posedge clk) disable iff (!rst_n)
        swap_req |-> (state_q == SWAP_IDLE);
    endproperty
    a_no_overlapping_swaps: assert property (p_no_overlapping_swaps)
        else $error("uram_pingpong: swap_req asserted while previous swap not done");

    // Compute and fill must always be opposite banks.
    property p_compute_fill_opposite;
        @(posedge clk) disable iff (!rst_n)
        compute_side_o !== fill_side_o;
    endproperty
    a_compute_fill_opposite: assert property (p_compute_fill_opposite)
        else $error("uram_pingpong: compute_side == fill_side (impossible)");
`endif

endmodule : uram_pingpong

`default_nettype wire
`endif // ARCHBETTER_URAM_PINGPONG_SV
