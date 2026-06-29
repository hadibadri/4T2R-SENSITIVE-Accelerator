
`ifndef ARCHBETTER_URAM_PINGPONG_SV
`define ARCHBETTER_URAM_PINGPONG_SV
`default_nettype none
`timescale 1ns/1ps

module uram_pingpong
    import types_pkg::*;
#(
    parameter int unsigned DATA_W = URAM_WIDTH_BITS,
    parameter int unsigned DEPTH  = URAM_DEPTH,
    parameter int unsigned ADDR_W = URAM_ADDR_W,
    parameter int unsigned WIDE   = 1,
    parameter bank_sel_e   INIT_COMPUTE_SIDE = BANK_A
) (
    input  wire logic              clk,
    input  wire logic              rst_n,
    pingpong_if.mem_mgr            core,
    input  wire logic              fill_wr_en,
    input  wire logic [ADDR_W-1:0] fill_wr_addr,
    input  wire logic [DATA_W-1:0] fill_wr_data,
    input  wire logic              swap_req,
    output logic                   swap_done,
    output bank_sel_e              compute_side_o,
    output bank_sel_e              fill_side_o
);
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
            drain_req_q <= (state_d == SWAP_DRAIN);
            swap_done_q <= flip_cycle;
            if (flip_cycle) begin
                compute_side_q <= (compute_side_q == BANK_A) ? BANK_B : BANK_A;
            end
        end
    end
    bank_sel_e fill_side_w;
    assign fill_side_w = (compute_side_q == BANK_A) ? BANK_B : BANK_A;

    assign compute_side_o = compute_side_q;
    assign fill_side_o    = fill_side_w;
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
    assign core.active_side = compute_side_q;
    assign core.side_valid  = rst_n;
    assign core.rd_data     = core_rd_data_mux;
    assign core.rd_valid    = core_rd_data_mux_valid;
    assign core.drain_req   = drain_req_q;

    assign swap_done = swap_done_q;
`ifndef SYNTHESIS
    property p_ack_only_in_drain;
        @(posedge clk) disable iff (!rst_n)
        core.drain_ack |-> (state_q == SWAP_DRAIN);
    endproperty
    a_ack_only_in_drain: assert property (p_ack_only_in_drain)
        else $error("uram_pingpong: drain_ack while FSM not in SWAP_DRAIN");
    property p_no_overlapping_swaps;
        @(posedge clk) disable iff (!rst_n)
        swap_req |-> (state_q == SWAP_IDLE);
    endproperty
    a_no_overlapping_swaps: assert property (p_no_overlapping_swaps)
        else $error("uram_pingpong: swap_req asserted while previous swap not done");
    property p_compute_fill_opposite;
        @(posedge clk) disable iff (!rst_n)
        compute_side_o !== fill_side_o;
    endproperty
    a_compute_fill_opposite: assert property (p_compute_fill_opposite)
        else $error("uram_pingpong: compute_side == fill_side (impossible)");
`endif

endmodule : uram_pingpong

`default_nettype wire
`endif
