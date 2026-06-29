
`ifndef ARCHBETTER_MEMORY_MANAGER_SV
`define ARCHBETTER_MEMORY_MANAGER_SV
`default_nettype none
`timescale 1ns/1ps

module memory_manager
    import types_pkg::*;
#(
    parameter int unsigned DESC_DEPTH = 256
) (
    input  wire logic clk,
    input  wire logic rst_n,
    mem_issue_if.mgr   issue,
    kv_access_if.slave kv,
    pingpong_if.mem_mgr dense_pp,
    pingpong_if.mem_mgr sparse_pp,
    csd_dram_if.mgr    dram,
    csd_dram_wr_if.mgr dram_wr,
    input  wire logic                       out_wr_en,
    input  wire logic [URAM_ADDR_W-1:0]     out_wr_addr,
    input  wire logic [URAM_WIDTH_BITS-1:0] out_wr_data,
    input  wire logic               desc_we,
    input  wire logic [7:0]         desc_wr_addr,
    input  wire csd_descriptor_t    desc_wr_data
);
    initial begin : elab_checks
        if (DESC_DEPTH != 256) begin
            $fatal(1, "memory_manager: DESC_DEPTH=%0d, expected 256 (matches tile_id width 8)",
                   DESC_DEPTH);
        end
    end
    (* ram_style = "registers" *)
    csd_descriptor_t desc_table [DESC_DEPTH];

    csd_descriptor_t desc_lookup;
    assign desc_lookup = desc_table[issue.tile_id];

    always_ff @(posedge clk) begin
        if (desc_we) begin
            desc_table[desc_wr_addr] <= desc_wr_data;
        end
    end
    typedef enum logic [3:0] {
        M_IDLE         = 4'd0,
        M_CSD_REQ      = 4'd1,
        M_CSD_WAIT     = 4'd2,
        M_PP_PULSE     = 4'd3,
        M_PP_WAIT      = 4'd4,
        M_NOP          = 4'd5,
        M_ST_OUT_REQ   = 4'd6,
        M_ST_OUT_WAIT  = 4'd7,
        M_DONE         = 4'd8
    } mstate_e;

    mstate_e         state_q, state_d;
    macro_opc_e      opc_q;
    logic [7:0]      tile_id_q;
    logic            is_sparse_q;
    csd_descriptor_t desc_q;
    logic                  csd_desc_valid;
    logic                  csd_desc_ready;
    logic                  csd_done;
    logic                       csd_fill_wr_en;
    logic [URAM_ADDR_W-1:0]     csd_fill_wr_addr;
    logic [URAM_WIDTH_BITS-1:0] csd_fill_wr_data;
    logic                       csd_fill_is_sparse;
    logic                       dense_fill_wr_en;
    logic                       sparse_fill_wr_en;
    logic dense_swap_req;
    logic dense_swap_done;
    logic sparse_swap_req;
    logic sparse_swap_done;
    logic                       drain_desc_valid;
    logic                       drain_desc_ready;
    logic                       drain_done;
    logic                       out_rd_en;
    logic [URAM_ADDR_W-1:0]     out_rd_addr;
    logic                       out_rd_valid;
    logic [URAM_WIDTH_BITS-1:0] out_rd_data;

    bank_sel_e dense_compute_side;
    bank_sel_e dense_fill_side;
    bank_sel_e sparse_compute_side;
    bank_sel_e sparse_fill_side;
    logic sel_swap_done;
    assign sel_swap_done = is_sparse_q ? sparse_swap_done : dense_swap_done;
    always_comb begin
        state_d = state_q;
        unique case (state_q)
            M_IDLE: begin
                if (issue.start) begin
                    unique case (issue.opc)
                        OP_LD_W_URAM, OP_LD_A_URAM: state_d = M_CSD_REQ;
                        OP_PINGPONG:                state_d = M_PP_PULSE;
                        OP_ST_OUT:                  state_d = M_ST_OUT_REQ;
                        default:                    state_d = M_NOP;
                    endcase
                end
            end
            M_CSD_REQ: begin
                if (csd_desc_valid && csd_desc_ready) state_d = M_CSD_WAIT;
            end
            M_CSD_WAIT: begin
                if (csd_done) state_d = M_DONE;
            end
            M_PP_PULSE: begin
                state_d = M_PP_WAIT;
            end
            M_PP_WAIT: begin
                if (sel_swap_done) state_d = M_DONE;
            end
            M_ST_OUT_REQ: begin
                if (drain_desc_valid && drain_desc_ready) state_d = M_ST_OUT_WAIT;
            end
            M_ST_OUT_WAIT: begin
                if (drain_done) state_d = M_DONE;
            end
            M_NOP: begin
                state_d = M_DONE;
            end
            M_DONE: begin
                state_d = M_IDLE;
            end
            default: state_d = M_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q     <= M_IDLE;
            opc_q       <= OP_NOP;
            tile_id_q   <= '0;
            is_sparse_q <= 1'b0;
            desc_q      <= '0;
        end else begin
            state_q <= state_d;
            if ((state_q == M_IDLE) && issue.start) begin
                opc_q       <= issue.opc;
                tile_id_q   <= issue.tile_id;
                is_sparse_q <= issue.is_sparse;
                desc_q      <= desc_lookup;
            end
        end
    end
    assign issue.done = (state_q == M_DONE);
    assign csd_desc_valid = (state_q == M_CSD_REQ);

    csd_descriptor_t csd_desc_in;
    assign csd_desc_in = desc_q;

    csd_engine #(
        .URAM_DATA_W(URAM_WIDTH_BITS)
    ) u_csd (
        .clk             (clk),
        .rst_n           (rst_n),
        .desc_i          (csd_desc_in),
        .desc_valid_i    (csd_desc_valid),
        .desc_ready_o    (csd_desc_ready),
        .done_o          (csd_done),
        .dram            (dram),
        .fill_wr_en_o    (csd_fill_wr_en),
        .fill_wr_addr_o  (csd_fill_wr_addr),
        .fill_wr_data_o  (csd_fill_wr_data),
        .fill_is_sparse_o(csd_fill_is_sparse)
    );
    assign dense_fill_wr_en  = csd_fill_wr_en && !csd_fill_is_sparse;
    assign sparse_fill_wr_en = csd_fill_wr_en &&  csd_fill_is_sparse;
    logic                       dense_wide_fill_en;
    logic [URAM_ADDR_W-1:0]     dense_wide_fill_addr;
    logic [DENSE_PP_URAM_W-1:0] dense_wide_fill_data;

    csd_wide_fill #(
        .WIDE  (DENSE_PP_URAM_WIDE),
        .LEAF_W(URAM_WIDTH_BITS),
        .ADDR_W(URAM_ADDR_W)
    ) u_dense_wide_fill (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_wr_en   (dense_fill_wr_en),
        .in_wr_addr (csd_fill_wr_addr),
        .in_wr_data (csd_fill_wr_data),
        .out_wr_en  (dense_wide_fill_en),
        .out_wr_addr(dense_wide_fill_addr),
        .out_wr_data(dense_wide_fill_data)
    );
    assign dense_swap_req  = (state_q == M_PP_PULSE) && !is_sparse_q;
    assign sparse_swap_req = (state_q == M_PP_PULSE) &&  is_sparse_q;
    uram_pingpong #(
        .DATA_W(DENSE_PP_URAM_W),
        .DEPTH (URAM_DEPTH),
        .ADDR_W(URAM_ADDR_W),
        .WIDE  (DENSE_PP_URAM_WIDE),
        .INIT_COMPUTE_SIDE(BANK_A)
    ) u_dense_pp (
        .clk            (clk),
        .rst_n          (rst_n),
        .core           (dense_pp),
        .fill_wr_en     (dense_wide_fill_en),
        .fill_wr_addr   (dense_wide_fill_addr),
        .fill_wr_data   (dense_wide_fill_data),
        .swap_req       (dense_swap_req),
        .swap_done      (dense_swap_done),
        .compute_side_o (dense_compute_side),
        .fill_side_o    (dense_fill_side)
    );

    uram_pingpong #(
        .DATA_W(URAM_WIDTH_BITS),
        .DEPTH (URAM_DEPTH),
        .ADDR_W(URAM_ADDR_W),
        .INIT_COMPUTE_SIDE(BANK_A)
    ) u_sparse_pp (
        .clk            (clk),
        .rst_n          (rst_n),
        .core           (sparse_pp),
        .fill_wr_en     (sparse_fill_wr_en),
        .fill_wr_addr   (csd_fill_wr_addr),
        .fill_wr_data   (csd_fill_wr_data),
        .swap_req       (sparse_swap_req),
        .swap_done      (sparse_swap_done),
        .compute_side_o (sparse_compute_side),
        .fill_side_o    (sparse_fill_side)
    );
    uram_bank #(
        .DATA_W(URAM_WIDTH_BITS),
        .DEPTH (URAM_DEPTH),
        .ADDR_W(URAM_ADDR_W)
    ) u_out_uram (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (out_wr_en),
        .wr_addr (out_wr_addr),
        .wr_data (out_wr_data),
        .rd_en   (out_rd_en),
        .rd_addr (out_rd_addr),
        .rd_valid(out_rd_valid),
        .rd_data (out_rd_data)
    );
    assign drain_desc_valid = (state_q == M_ST_OUT_REQ);

    csd_drain_engine #(
        .URAM_DATA_W(URAM_WIDTH_BITS)
    ) u_drain (
        .clk         (clk),
        .rst_n       (rst_n),
        .desc_i      (desc_q),
        .desc_valid_i(drain_desc_valid),
        .desc_ready_o(drain_desc_ready),
        .done_o      (drain_done),
        .rd_en_o     (out_rd_en),
        .rd_addr_o   (out_rd_addr),
        .rd_valid_i  (out_rd_valid),
        .rd_data_i   (out_rd_data),
        .dram_wr     (dram_wr)
    );
    kv_bram #(
        .DATA_W(KV_DATA_W),
        .DEPTH (KV_DEPTH),
        .ADDR_W(KV_ADDR_W)
    ) u_kv (
        .clk  (clk),
        .rst_n(rst_n),
        .kv   (kv)
    );
`ifndef SYNTHESIS
    property p_desc_we_only_in_idle;
        @(posedge clk) disable iff (!rst_n)
        desc_we |-> (state_q == M_IDLE);
    endproperty
    a_desc_we_only_in_idle: assert property (p_desc_we_only_in_idle)
        else $error("memory_manager: desc_we asserted while FSM busy (state=%0d)", state_q);
    property p_start_only_in_idle;
        @(posedge clk) disable iff (!rst_n)
        issue.start |-> (state_q == M_IDLE);
    endproperty
    a_start_only_in_idle: assert property (p_start_only_in_idle)
        else $error("memory_manager: issue.start while FSM not IDLE (state=%0d)", state_q);
    always_ff @(posedge clk) begin
        if (rst_n && (state_q == M_IDLE) && issue.start) begin
            unique case (issue.opc)
                OP_LD_W_URAM, OP_LD_A_URAM, OP_PINGPONG, OP_ST_OUT: ;
                default:   $warning("memory_manager: unsupported opcode 0x%02h on mem_issue_if (acked as nop)",
                                    issue.opc);
            endcase
        end
    end
`endif

endmodule : memory_manager

`default_nettype wire
`endif
