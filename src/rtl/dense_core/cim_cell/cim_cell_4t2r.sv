
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
    input  wire bfp12_mant_t a_in,
    input  wire logic        a_valid,
    input  wire logic        w_we,
    input  wire bfp12_mant_t w_in,
    input  wire bfp12_mant_t noise_rd_in,
    input  wire logic        acc_clr,
    output dense_acc_t       acc_out,
    output logic             acc_valid
);
    bfp12_mant_t w_reg;

    always_ff @(posedge clk) begin
        if (!rst_n)        w_reg <= '0;
        else if (w_we)     w_reg <= w_in;
    end
    (* use_dsp = "yes" *) bfp12_mant_t a_areg1, a_areg2;
    (* use_dsp = "yes" *) bfp12_mant_t b_breg1, b_breg2;
    logic                              v_a1,   v_a2;
    logic                              clr_a1, clr_a2;
    bfp12_mant_t                       noise_a1, noise_a2;
    (* use_dsp = "yes" *) bfp12_prod_t m_reg;
    logic                              v_m;
    logic                              clr_m;
    (* use_dsp = "yes" *) dense_acc_t  p_reg;
    logic                              p_valid_q;
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
            a_areg1  <= a_in;
            b_breg1  <= w_reg;
            v_a1     <= a_valid;
            clr_a1   <= acc_clr;
            noise_a1 <= noise_rd_in;
            a_areg2  <= a_areg1;
            b_breg2  <= b_breg1;
            v_a2     <= v_a1;
            clr_a2   <= clr_a1;
            noise_a2 <= noise_a1;
            m_reg <= bfp12_prod_t'(a_areg2 * b_breg2) + noise_ext_a;
            v_m   <= v_a2;
            clr_m <= clr_a2;
            p_valid_q <= v_m;
            if (v_m) begin
                p_reg <= clr_m ? dense_acc_t'(m_reg)
                               : p_reg + dense_acc_t'(m_reg);
            end
        end
    end

    assign acc_out   = p_reg;
    assign acc_valid = p_valid_q;
`ifndef SYNTHESIS
    a_avalid_implies_accvalid: assert property (
        @(posedge clk) disable iff (!rst_n)
        a_valid |-> ##4 acc_valid
    ) else $error("cim_cell_4t2r[%0d]: a_valid not followed by acc_valid at +4", CELL_ID);

    a_no_we_with_avalid: assert property (
        @(posedge clk) disable iff (!rst_n)
        !(w_we && a_valid)
    ) else $error("cim_cell_4t2r[%0d]: w_we and a_valid asserted in the same cycle", CELL_ID);
    a_clr_with_avalid: assert property (
        @(posedge clk) disable iff (!rst_n)
        acc_clr |-> a_valid
    ) else $error("cim_cell_4t2r[%0d]: acc_clr without a co-firing a_valid", CELL_ID);
`endif

endmodule : cim_cell_4t2r

`default_nettype wire
`endif
