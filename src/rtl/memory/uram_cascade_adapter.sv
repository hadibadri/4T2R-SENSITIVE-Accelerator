
`timescale 1ns/1ps
`ifndef ARCHBETTER_URAM_CASCADE_ADAPTER_SV
`define ARCHBETTER_URAM_CASCADE_ADAPTER_SV
`default_nettype none

module uram_cascade_adapter
    import types_pkg::*;
#(
    parameter int unsigned UP_DATA_W = URAM_WIDTH_BITS,
    parameter int unsigned DN_DATA_W = 2 * URAM_WIDTH_BITS,
    parameter int unsigned UP_ADDR_W = URAM_ADDR_W,
    parameter int unsigned DN_ADDR_W = URAM_ADDR_W,
    parameter int unsigned RD_DEPTH  = 8
) (
    input  wire logic       clk,
    input  wire logic       rst_n,
    pingpong_if.core    up,
    pingpong_if.mem_mgr dn
);
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
    typedef enum logic {
        I_LO = 1'b0,
        I_HI = 1'b1
    } issue_phase_e;
    localparam int unsigned PW = (RD_DEPTH > 1) ? $clog2(RD_DEPTH) : 1;

    logic [DN_ADDR_W-1:0]       addr_fifo [RD_DEPTH];
    logic [PW-1:0]              afifo_wr_q, afifo_rd_q;
    logic [PW:0]               afifo_cnt_q;
    issue_phase_e              iss_phase_q;

    logic afifo_full, afifo_empty;
    assign afifo_full  = (afifo_cnt_q == (PW+1)'(RD_DEPTH));
    assign afifo_empty = (afifo_cnt_q == '0);
    logic accept_dn;
    assign accept_dn = dn.rd_en && !afifo_full;
    logic up_rd_en_now;
    assign up_rd_en_now = !afifo_empty;
    logic do_pop;
    assign do_pop = up_rd_en_now && (iss_phase_q == I_HI);
    logic [UP_ADDR_W-1:0] up_addr_now;
    always_comb begin
        up_addr_now = (iss_phase_q == I_LO)
                    ? UP_ADDR_W'(addr_fifo[afifo_rd_q] << 1)
                    : UP_ADDR_W'((addr_fifo[afifo_rd_q] << 1) + UP_ADDR_W'(1));
    end
    typedef enum logic {
        C_LO = 1'b0,
        C_HI = 1'b1
    } cap_phase_e;

    cap_phase_e               cap_phase_q;
    logic [UP_DATA_W-1:0]     cap_lo_q;
    logic                     dn_rd_valid_q;
    logic [DN_DATA_W-1:0]     dn_rd_data_q;
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
            if (accept_dn) begin
                addr_fifo[afifo_wr_q] <= dn.rd_addr;
                afifo_wr_q <= (afifo_wr_q == PW'(RD_DEPTH-1)) ? '0 : afifo_wr_q + 1'b1;
            end
            if (up_rd_en_now) begin
                if (iss_phase_q == I_LO) begin
                    iss_phase_q <= I_HI;
                end else begin
                    iss_phase_q <= I_LO;
                    afifo_rd_q  <= (afifo_rd_q == PW'(RD_DEPTH-1)) ? '0 : afifo_rd_q + 1'b1;
                end
            end
            afifo_cnt_q <= afifo_cnt_q
                         + (accept_dn ? (PW+1)'(1) : (PW+1)'(0))
                         - (do_pop    ? (PW+1)'(1) : (PW+1)'(0));
            dn_rd_valid_q <= 1'b0;

            if (up.rd_valid) begin
                if (cap_phase_q == C_LO) begin
                    cap_lo_q    <= up.rd_data;
                    cap_phase_q <= C_HI;
                end else begin
                    dn_rd_data_q  <= { up.rd_data, cap_lo_q };
                    dn_rd_valid_q <= 1'b1;
                    cap_phase_q   <= C_LO;
                end
            end
        end
    end
    always_comb begin
        up.rd_en     = up_rd_en_now;
        up.rd_addr   = up_addr_now;
        up.drain_ack = dn.drain_ack;
    end
    always_comb begin
        dn.active_side = up.active_side;
        dn.side_valid  = up.side_valid;
        dn.rd_data     = dn_rd_data_q;
        dn.rd_valid    = dn_rd_valid_q;
        dn.drain_req   = up.drain_req;
    end
`ifndef SYNTHESIS
    a_no_dn_rden_when_full: assert property (
        @(posedge clk) disable iff (!rst_n)
        dn.rd_en |-> !afifo_full
    ) else $error("uram_cascade_adapter: dn.rd_en pulsed while accept FIFO full (depth %0d)", RD_DEPTH);
    a_dn_addr_top_bit_zero: assert property (
        @(posedge clk) disable iff (!rst_n)
        (dn.rd_en && (DN_ADDR_W >= 1)) |-> (dn.rd_addr[DN_ADDR_W-1] === 1'b0)
    ) else $error("uram_cascade_adapter: dn.rd_addr[%0d]=1; cascaded address out of upstream range",
                  DN_ADDR_W-1);
    a_drain_req_quiescent: assert property (
        @(posedge clk) disable iff (!rst_n)
        up.drain_req |-> (afifo_empty && (cap_phase_q == C_LO))
    ) else $error("uram_cascade_adapter: drain_req asserted while a cascade pair is in flight");
    a_dn_valid_only_after_hi: assert property (
        @(posedge clk) disable iff (!rst_n)
        dn.rd_valid |-> $past(up.rd_valid, 1) && ($past(cap_phase_q, 1) == C_HI)
    ) else $error("uram_cascade_adapter: dn.rd_valid emitted without a HI-phase upstream response");
`endif

endmodule : uram_cascade_adapter

`default_nettype wire
`endif
