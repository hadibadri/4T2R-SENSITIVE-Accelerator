// -----------------------------------------------------------------------------
// cim_cell_4t2r.sv  (Phase-8: fused single-DSP48E2 MACC)
//
// 4T2R memristor CIM cell — digital twin.
//
// Analog semantics modeled here:
//   * weight is stored as a differential G+/G- conductance pair; in the twin
//     this collapses to a single signed BFP12 mantissa (w_reg).
//   * activation is presented as a voltage; in the twin, as a signed BFP12
//     mantissa (a_in).
//   * cell output is the Ohm's-law product  i = V * (G+ - G-), i.e. the
//     signed mantissa product a_in * w_reg.
//   * the TEMPORAL reduction over the K activation beats (the dot product over
//     the reduction dimension) is integrated here in the DSP's P register.
//     This is NOT the spatial Kirchhoff bit-line sum across the 16 rows of a
//     group — that remains the dense_group column-reduction tree. Only the
//     per-cell temporal MACC lives in this DSP (CLAUDE.md sec 2.2 Phase-8).
//
// Phase-8 fused MACC (Phase-8b: AREG=2/BREG=2 fully-pipelined inputs)
// -------------------------------------------------------------------
// The previous form did a 1-cycle combinational multiply here and a SEPARATE
// fabric/ DSP accumulator in dense_pe. That cost two unpipelined DSP48E2 per PE
// (1024 total) and tripped DPIP-2 / DPOP-3 / DPOP-4 (no input/M/P pipelining),
// collapsing Fmax and bleeding dynamic power. This cell now infers ONE fully
// pipelined DSP48E2 per PE via the canonical MACC template, using BOTH of the
// DSP48E2's built-in A/B input registers (A1+A2, B1+B2):
//
//   Stage A1 : a_areg1 <= a_in    ; b_breg1 <= w_reg          (AREG/BREG stage 1)
//   Stage A2 : a_areg2 <= a_areg1 ; b_breg2 <= b_breg1        (AREG/BREG stage 2)
//   Stage M  : m_reg   <= a_areg2 * b_breg2                   (MREG)
//   Stage P  : p_reg   <= acc_clr ? m_reg : p_reg + m_reg     (PREG, load/accum)
//
// The second input register (A1/B1) is INSIDE the DSP48E2 — zero fabric area —
// and clears DPIP-2 ("DSP input not pipelined"), which the single-stage AREG=1
// form left open. It shortens the A/B-to-multiplier setup path, buying Fmax
// headroom on the dense critical path. Result: 512 DSP48E2 (was 1024), and
// DPIP-2 / DPOP-3 / DPOP-4 all clear.
//
// Latency contract:
//   * 4 cycles from a_in to its contribution landing in p_reg (acc_out).
//     a_in@t -> a_areg1@t+1 -> a_areg2@t+2 -> m_reg@t+3 -> p_reg@t+4.
//   * acc_valid is a_valid delayed by 4 cycles (the valid shift register).
//   * For a K-beat reduction with acc_clr co-firing the first beat, p_reg holds
//     the complete sum 4 cycles after the last beat; the enclosing dense_group
//     must therefore wait 3 drain cycles before acc_snap (was 2). The
//     dispatcher S_GEMM_DRAIN schedule (GEMM_DRAIN_CYCLES = 3) reflects this.
//
// Non-ideality hook:
//   * noise_rd_in is a per-beat read-noise term, aligned to the multiply and
//     folded into the product at the M register. When ENABLE_NOISE_HOOKS=0 the
//     term is a constant 0, prunes at elaboration, and the M stage infers the
//     clean DSP product. Hooks are only enabled for sim-time twin calibration,
//     where clean DSP inference does not matter.
//
// Resource target:
//   * 1 DSP48E2 per cell (signed 12x12 multiply + P-register MACC).
//   * Weight store is 1 FF vector (BFP12_MANT_W flops).
//
// Concurrency contract (dispatcher guarantee, checked by assertion):
//   * w_we and a_valid never pulse in the same cycle.
//   * acc_clr co-fires with the first a_valid of a reduction (load vs add).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_CIM_CELL_4T2R_SV
`define ARCHBETTER_CIM_CELL_4T2R_SV
`default_nettype none

module cim_cell_4t2r
    import types_pkg::*;
#(
    parameter bit          ENABLE_NOISE_HOOKS = 1'b0,
    parameter int unsigned CELL_ID            = 0
) (
    input  wire logic        clk,
    input  wire logic        rst_n,

    // Activation fire
    input  wire bfp12_mant_t a_in,
    input  wire logic        a_valid,

    // Weight programming port
    input  wire logic        w_we,
    input  wire bfp12_mant_t w_in,

    // Non-ideality injection (read-noise folded into the product at MREG)
    input  wire bfp12_mant_t noise_rd_in,

    // Fused-MACC accumulator control. acc_clr co-fires with the first a_valid
    // of a reduction: it makes the first product LOAD the P register instead of
    // accumulating into it. It is pipelined internally to align with that
    // product reaching the P stage.
    input  wire logic        acc_clr,

    // Live accumulator (the DSP P register) and its valid.
    output dense_acc_t       acc_out,
    output logic             acc_valid
);

    // -------------------------------------------------------------------------
    // Weight storage. Analog model: differential memristor pair written under
    // SET/RESET pulses. Digital model: one-hot write-enable latches a mantissa.
    // -------------------------------------------------------------------------
    bfp12_mant_t w_reg;

    always_ff @(posedge clk) begin
        if (!rst_n)        w_reg <= '0;
        else if (w_we)     w_reg <= w_in;
    end

    // -------------------------------------------------------------------------
    // DSP register stages. The (* use_dsp *) hints steer Vivado to pack the
    // whole multiply-accumulate into one DSP48E2 with A/B/M/P all registered.
    // -------------------------------------------------------------------------
    // Stage A1/A2: two cascaded input registers (DSP A1+A2 / B1+B2) + a matched
    // 2-deep valid/clr/noise shift so control stays aligned with the operands.
    (* use_dsp = "yes" *) bfp12_mant_t a_areg1, a_areg2;
    (* use_dsp = "yes" *) bfp12_mant_t b_breg1, b_breg2;
    logic                              v_a1,   v_a2;
    logic                              clr_a1, clr_a2;
    bfp12_mant_t                       noise_a1, noise_a2;

    // Stage M: product register + valid/clr pipeline.
    (* use_dsp = "yes" *) bfp12_prod_t m_reg;
    logic                              v_m;
    logic                              clr_m;

    // Stage P: accumulator register (load or accumulate).
    (* use_dsp = "yes" *) dense_acc_t  p_reg;
    logic                              p_valid_q;

    // Read-noise, sign-extended to the product width. Constant 0 (and pruned)
    // when ENABLE_NOISE_HOOKS = 0. Aligned to the product at the M stage, so it
    // is taken from the second (A2-aligned) noise register.
    bfp12_prod_t noise_ext_a;
    assign noise_ext_a = ENABLE_NOISE_HOOKS ? bfp12_prod_t'(noise_a2) : '0;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            a_areg1   <= '0;
            a_areg2   <= '0;
            b_breg1   <= '0;
            b_breg2   <= '0;
            v_a1      <= 1'b0;
            v_a2      <= 1'b0;
            clr_a1    <= 1'b0;
            clr_a2    <= 1'b0;
            noise_a1  <= '0;
            noise_a2  <= '0;
            m_reg     <= '0;
            v_m       <= 1'b0;
            clr_m     <= 1'b0;
            p_reg     <= '0;
            p_valid_q <= 1'b0;
        end else begin
            // ---- Stage A1: latch operands + control (DSP A1/B1) ----
            a_areg1  <= a_in;
            b_breg1  <= w_reg;
            v_a1     <= a_valid;
            clr_a1   <= acc_clr;
            noise_a1 <= noise_rd_in;

            // ---- Stage A2: second input register (DSP A2/B2) ----
            a_areg2  <= a_areg1;
            b_breg2  <= b_breg1;
            v_a2     <= v_a1;
            clr_a2   <= clr_a1;
            noise_a2 <= noise_a1;

            // ---- Stage M: product (+ optional read-noise) ----
            m_reg <= bfp12_prod_t'(a_areg2 * b_breg2) + noise_ext_a;
            v_m   <= v_a2;
            clr_m <= clr_a2;

            // ---- Stage P: load on the first valid product of a reduction,
            //      accumulate thereafter. ----
            p_valid_q <= v_m;
            if (v_m) begin
                p_reg <= clr_m ? dense_acc_t'(m_reg)
                               : p_reg + dense_acc_t'(m_reg);
            end
        end
    end

    assign acc_out   = p_reg;
    assign acc_valid = p_valid_q;

    // -------------------------------------------------------------------------
    // Contract assertions (simulation only).
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    // 4-cycle MACC latency: a_valid propagates to acc_valid through the
    // A1/A2/M/P valid shift register.
    a_avalid_implies_accvalid: assert property (
        @(posedge clk) disable iff (!rst_n)
        a_valid |-> ##4 acc_valid
    ) else $error("cim_cell_4t2r[%0d]: a_valid not followed by acc_valid at +4", CELL_ID);

    a_no_we_with_avalid: assert property (
        @(posedge clk) disable iff (!rst_n)
        !(w_we && a_valid)
    ) else $error("cim_cell_4t2r[%0d]: w_we and a_valid asserted in the same cycle", CELL_ID);

    // acc_clr is only meaningful co-firing with an activation beat.
    a_clr_with_avalid: assert property (
        @(posedge clk) disable iff (!rst_n)
        acc_clr |-> a_valid
    ) else $error("cim_cell_4t2r[%0d]: acc_clr without a co-firing a_valid", CELL_ID);
`endif

endmodule : cim_cell_4t2r

`default_nettype wire
`endif // ARCHBETTER_CIM_CELL_4T2R_SV
