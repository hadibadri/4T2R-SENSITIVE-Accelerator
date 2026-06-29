// -----------------------------------------------------------------------------
// dense_pe.sv  (Phase-8: fused-MACC wrapper)
//
// Weight-stationary processing element for the dense core. Wraps one
// cim_cell_4t2r — which now contains the full fused multiply-accumulate in a
// single DSP48E2 (AREG/BREG/MREG/PREG) — and adds only the snapshot output
// stage. The temporal reduction accumulator that used to live here as fabric
// logic (acc_reg / acc_next) has moved INTO the cell's DSP P register, halving
// dense-core DSP usage (1024 -> 512) and clearing DPIP-2 / DPOP-3 / DPOP-4.
//
// The group-local accumulation invariant from CLAUDE.md still holds: no partial
// sum leaves this PE until acc_snap latches the live accumulator into acc_out.
//
// Contract timing for one K-beat reduction (acc_clr co-fires the first beat):
//   t0          : acc_clr = 1, a_valid = 1, a_in = x[0]   -- start fresh (LOAD)
//   t1..tK-1    : acc_clr = 0, a_valid = 1, a_in = x[i]   -- accumulate
//   tK,tK+1,tK+2: a_valid = 0                              -- 3 drain cycles
//                                                            (A1+A2+MREG+PREG fill)
//   tK+3        : acc_snap = 1                             -- latch final sum
//   tK+4        : acc_out_valid pulses with Sigma x[i]*w   -- result stable
//
// Why THREE drain cycles: the fused MACC has a 4-cycle latency (a_in -> p_reg)
// now that the A/B inputs use both DSP registers (AREG=2/BREG=2, added to clear
// DPIP-2). The last product reaches the P register 4 cycles after its a_valid
// beat, so acc_snap must wait three post-stream cycles. The dispatcher
// S_GEMM_DRAIN schedule (GEMM_DRAIN_CYCLES = 3) issues exactly these cycles.
//
// Mutex contracts (checked by assertions; the group controller must honour):
//   * w_we && a_valid            -- illegal (from cim_cell_4t2r)
//   * acc_clr && acc_snap        -- illegal (same-cycle clear + snap)
//
// Resource target:
//   * 1 DSP48E2 (the fused MACC inside the CIM cell)
//   * 1 register bank of DENSE_ACC_W FFs for the snapshot output + 1 valid FF
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE_PE_SV
`define ARCHBETTER_DENSE_PE_SV
`default_nettype none

module dense_pe
    import types_pkg::*;
#(
    parameter bit          ENABLE_NOISE_HOOKS = 1'b0,
    parameter int unsigned PE_ID              = 0
) (
    input  wire logic        clk,
    input  wire logic        rst_n,

    // Multicast activation sink (no backpressure; symmetric with cim_cell)
    input  wire bfp12_mant_t a_in,
    input  wire logic        a_valid,

    // Weight programming
    input  wire logic        w_we,
    input  wire bfp12_mant_t w_in,

    // Non-ideality hook (pruned when ENABLE_NOISE_HOOKS = 0)
    input  wire bfp12_mant_t noise_rd_in,

    // Accumulator control
    input  wire logic        acc_clr,   // co-fires with first a_valid of a reduction
    input  wire logic        acc_snap,  // latch live accumulator into acc_out

    // Snap mode (R6 / v2). PER_TOKEN (v1): latch on acc_snap (post-drain, one
    // per token). CONTINUOUS (v2): latch the live cell accumulator every cycle
    // the cell emits a fresh per-beat result (cell_acc_valid, +4 from a_valid),
    // so K=1 token-beats streamed at II=1 fall out one complete product/cycle.
    // Default = PER_TOKEN keeps every existing instantiation bit-identical.
    input  wire gemm_stream_mode_e stream_mode,

    // Snapshot output. acc_out_valid is driven from a local register so the
    // PE-internal valid signal can be referenced by name in lint/waiver scopes.
    output dense_acc_t  acc_out,
    output logic        acc_out_valid
);

    // -------------------------------------------------------------------------
    // Inner fused-MACC CIM cell. The cell's acc_out is the LIVE accumulator
    // (DSP P register); this PE samples it on acc_snap.
    // -------------------------------------------------------------------------
    dense_acc_t cell_acc;
    logic       cell_acc_valid;

    cim_cell_4t2r #(
        .ENABLE_NOISE_HOOKS (ENABLE_NOISE_HOOKS),
        .CELL_ID            (PE_ID)
    ) u_cell (
        .clk         (clk),
        .rst_n       (rst_n),
        .a_in        (a_in),
        .a_valid     (a_valid),
        .w_we        (w_we),
        .w_in        (w_in),
        .noise_rd_in (noise_rd_in),
        .acc_clr     (acc_clr),
        .acc_out     (cell_acc),
        .acc_valid   (cell_acc_valid)
    );

    // -------------------------------------------------------------------------
    // Snapshot register. acc_out is stable until the next acc_snap.
    // Per-PE fanout of acc_out_valid_q is bounded by group geometry (one
    // consumer in the enclosing group's snap latch); RFFH-1 advisory at
    // elaboration is structurally over-counted and is waived in waivers.tcl
    // rather than mitigated with a max_fanout decoration.
    // -------------------------------------------------------------------------
    logic acc_out_valid_q;

    // Snap trigger: v1 latches on the dispatcher's post-drain acc_snap pulse;
    // v2 latches on the cell's per-beat result valid. Identical register
    // structure either way, so DENSE_PE_SNAP_REGS (=1) holds in both modes.
    logic do_snap;
    always_comb begin
        do_snap = (stream_mode == GEMM_SNAP_CONTINUOUS) ? cell_acc_valid : acc_snap;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_out         <= '0;
            acc_out_valid_q <= 1'b0;
        end else begin
            acc_out_valid_q <= do_snap;
            if (do_snap) acc_out <= cell_acc;
        end
    end

    assign acc_out_valid = acc_out_valid_q;

    // -------------------------------------------------------------------------
    // Contract assertions (sim only)
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    a_no_clr_and_snap: assert property (
        @(posedge clk) disable iff (!rst_n)
        !(acc_clr && acc_snap)
    ) else $error("dense_pe[%0d]: acc_clr and acc_snap asserted in the same cycle", PE_ID);

    // Replaces the v1-only a_valid_follows_snap. acc_out_valid is do_snap delayed
    // one cycle in BOTH modes (do_snap = acc_snap in v1, cell_acc_valid in v2),
    // so this is the exact register contract and carries full coverage across
    // the mode split — no net loss vs the original assertion (R6 discipline).
    a_valid_follows_snap: assert property (
        @(posedge clk) disable iff (!rst_n)
        acc_out_valid |-> $past(do_snap, 1)
    ) else $error("dense_pe[%0d]: acc_out_valid high without prior-cycle snap trigger", PE_ID);

    // v2 contract: continuous snap must be driven only by the cell's real per-beat
    // valid, never by a stray acc_snap (the dispatcher holds acc_snap low in v2).
    a_no_acc_snap_in_continuous: assert property (
        @(posedge clk) disable iff (!rst_n)
        (stream_mode == GEMM_SNAP_CONTINUOUS) |-> !acc_snap
    ) else $error("dense_pe[%0d]: acc_snap pulsed while in CONTINUOUS snap mode", PE_ID);
`endif

endmodule : dense_pe

`default_nettype wire
`endif // ARCHBETTER_DENSE_PE_SV
