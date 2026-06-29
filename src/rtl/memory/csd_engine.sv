
`ifndef ARCHBETTER_CSD_ENGINE_SV
`define ARCHBETTER_CSD_ENGINE_SV
`default_nettype none
`timescale 1ns/1ps

module csd_engine
    import types_pkg::*;
#(
    parameter int unsigned URAM_DATA_W = URAM_WIDTH_BITS
) (
    input  wire logic                  clk,
    input  wire logic                  rst_n,
    input  wire csd_descriptor_t       desc_i,
    input  wire logic                  desc_valid_i,
    output logic                       desc_ready_o,
    output logic                       done_o,
    csd_dram_if.mgr                    dram,
    output logic                       fill_wr_en_o,
    output logic [URAM_ADDR_W-1:0]     fill_wr_addr_o,
    output logic [URAM_DATA_W-1:0]     fill_wr_data_o,
    output logic                       fill_is_sparse_o
);
    initial begin : elab_checks
        if (URAM_DATA_W != DRAM_BEAT_W) begin
            $fatal(1, "csd_engine: URAM_DATA_W=%0d must equal DRAM_BEAT_W=%0d",
                   URAM_DATA_W, DRAM_BEAT_W);
        end
    end
    typedef enum logic [1:0] {
        S_IDLE = 2'b00,
        S_REQ  = 2'b01,
        S_RESP = 2'b10,
        S_DONE = 2'b11
    } state_e;

    state_e state_q, state_d;

    csd_descriptor_t       desc_q;
    logic [URAM_ADDR_W-1:0] offset_q;
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
    assign desc_ready_o = (state_q == S_IDLE);

    assign dram.req_addr  = desc_q.dram_base;
    assign dram.req_len   = desc_q.n_beats;
    assign dram.req_valid = (state_q == S_REQ);
    assign dram.rsp_ready = (state_q == S_RESP);

    assign fill_wr_en_o     = beat_fire;
    assign fill_wr_addr_o   = URAM_ADDR_W'(desc_q.uram_base + offset_q);
    assign fill_wr_data_o   = dram.rsp_data;
    assign fill_is_sparse_o = desc_q.is_sparse;
    assign done_o = (state_q == S_DONE);
`ifndef SYNTHESIS
    property p_phase2_no_compression;
        @(posedge clk) disable iff (!rst_n)
        desc_fire |-> (desc_i.compressed == 1'b0);
    endproperty
    a_phase2_no_compression: assert property (p_phase2_no_compression)
        else $error("csd_engine: descriptor with compressed=1 (Phase 2 is pass-through)");
    property p_nonzero_len;
        @(posedge clk) disable iff (!rst_n)
        desc_fire |-> (desc_i.n_beats != '0);
    endproperty
    a_nonzero_len: assert property (p_nonzero_len)
        else $error("csd_engine: descriptor with n_beats=0");
    property p_beat_only_in_resp;
        @(posedge clk) disable iff (!rst_n)
        beat_fire |-> (state_q == S_RESP);
    endproperty
    a_beat_only_in_resp: assert property (p_beat_only_in_resp)
        else $error("csd_engine: rsp_valid && rsp_ready outside S_RESP");
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
`endif
