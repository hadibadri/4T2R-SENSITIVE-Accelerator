
`timescale 1ns/1ps
`ifndef ARCHBETTER_DENSE_ARRAY_BANK_SV
`define ARCHBETTER_DENSE_ARRAY_BANK_SV
`default_nettype none

module dense_array_bank
    import types_pkg::*;
#(
    parameter int unsigned ARRAY_ID     = 0,
    parameter int unsigned BATCH_T      = 1,
    parameter int unsigned BANK_REG_MAX = 8
) (
    input  wire logic clk,
    input  wire logic rst_n,
    input  wire logic                                          tile_first,
    input  wire logic                                          upd_valid,
    input  wire logic [BATCH_TOK_W-1:0]                        upd_tok,
    input  wire logic [$clog2(DENSE_LOGICAL_TILE_COLS)-1:0]    upd_gc,
    input  wire logic                                          upd_last,
    input  wire logic                                          upd_first,
    input  wire array_acc_t [DENSE_PHYS_COLS-1:0]              phys_strip,
    input  wire logic [BATCH_TOK_W-1:0]                        batch_n,
    input  wire logic                                          drain_busy,

    output array_acc_t [DENSE_ARRAY_COLS-1:0]                  y_out,
    output logic                                               y_valid,
    output logic                                               drain_active
);

    localparam int unsigned PHYS_COLS = DENSE_PHYS_COLS;
    localparam int unsigned TILE_COLS = DENSE_LOGICAL_TILE_COLS;
    localparam int unsigned TILE_GC_W = $clog2(DENSE_LOGICAL_TILE_COLS);
    if (BATCH_T <= BANK_REG_MAX) begin : gen_reg

        array_acc_t [BATCH_T-1:0][DENSE_ARRAY_COLS-1:0] bank;

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                bank <= '0;
            end else if (tile_first) begin
                bank <= '0;
            end else if (upd_valid) begin
                for (int pc = 0; pc < int'(PHYS_COLS); pc++) begin
                    automatic int unsigned bank_idx =
                        (int'(upd_gc) * int'(PHYS_COLS)) + pc;
                    bank[upd_tok][bank_idx] <=
                        bank[upd_tok][bank_idx] + phys_strip[pc];
                end
            end
        end

        typedef enum logic [1:0] { DR_IDLE, DR_LOAD, DR_WAITFREE, DR_PULSE } dr_state_e;
        dr_state_e              dr_state_q;
        logic [BATCH_TOK_W-1:0] dr_idx_q;

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                dr_state_q <= DR_IDLE;
                dr_idx_q   <= '0;
                y_out      <= '0;
                y_valid    <= 1'b0;
            end else begin
                y_valid <= 1'b0;
                unique case (dr_state_q)
                    DR_IDLE: begin
                        if (upd_valid && upd_last) begin
                            dr_idx_q   <= '0;
                            dr_state_q <= DR_LOAD;
                        end
                    end
                    DR_LOAD: begin
                        y_out      <= bank[0];
                        dr_state_q <= DR_WAITFREE;
                    end
                    DR_WAITFREE: begin
                        if (!drain_busy) begin
                            y_valid    <= 1'b1;
                            dr_state_q <= DR_PULSE;
                        end
                    end
                    DR_PULSE: begin
                        if (dr_idx_q == (batch_n - BATCH_TOK_W'(1))) begin
                            dr_state_q <= DR_IDLE;
                        end else begin
                            dr_idx_q   <= dr_idx_q + BATCH_TOK_W'(1);
                            y_out      <= bank[dr_idx_q + BATCH_TOK_W'(1)];
                            dr_state_q <= DR_WAITFREE;
                        end
                    end
                    default: dr_state_q <= DR_IDLE;
                endcase
            end
        end

        logic layer_busy_q;
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                layer_busy_q <= 1'b0;
            end else if (tile_first) begin
                layer_busy_q <= 1'b1;
            end else if ((dr_state_q == DR_PULSE)
                      && (dr_idx_q == (batch_n - BATCH_TOK_W'(1)))) begin
                layer_busy_q <= 1'b0;
            end
        end
        assign drain_active = layer_busy_q;
    end else begin : gen_bram

        localparam int unsigned W_STRIP = PHYS_COLS * ARRAY_ACC_W;
        localparam int unsigned DEPTH   = BATCH_T * TILE_COLS;
        localparam int unsigned AW      = (DEPTH > 1) ? $clog2(DEPTH) : 1;

        function automatic logic [W_STRIP-1:0] pack_strip
            (input array_acc_t [PHYS_COLS-1:0] s);
            for (int i = 0; i < int'(PHYS_COLS); i++)
                pack_strip[i*ARRAY_ACC_W +: ARRAY_ACC_W] = s[i];
        endfunction

        (* ram_style = "block" *) logic [W_STRIP-1:0] bank_mem [DEPTH];
        initial for (int i = 0; i < int'(DEPTH); i++) bank_mem[i] = '0;

        function automatic logic [AW-1:0] mk_addr
            (input logic [BATCH_TOK_W-1:0] tok, input logic [TILE_GC_W-1:0] gc);
            mk_addr = AW'(int'(tok) * int'(TILE_COLS) + int'(gc));
        endfunction
        logic                   s1_valid_q, s2_valid_q;
        logic                   s1_first_q, s2_first_q;
        logic [AW-1:0]          s1_addr_q,  s2_addr_q;
        array_acc_t [PHYS_COLS-1:0] s1_strip_q, s2_strip_q;
        typedef enum logic [2:0]
            { DB_IDLE, DB_SETTLE, DB_FILL, DB_WAITFREE, DB_PULSE } db_state_e;
        db_state_e              db_state_q;
        logic [BATCH_TOK_W-1:0] db_idx_q;
        logic [TILE_GC_W:0]     db_step_q;
        logic [1:0]             db_settle_q;
        logic [AW-1:0]          rd_addr;
        logic                   rd_en;
        logic [W_STRIP-1:0]     ram_q;
        logic [W_STRIP-1:0]     rd_data_q;

        always_comb begin
            rd_en   = 1'b0;
            rd_addr = '0;
            if (db_state_q == DB_IDLE) begin
                rd_en   = upd_valid;
                rd_addr = mk_addr(upd_tok, upd_gc);
            end else if (db_state_q == DB_FILL) begin
                if (db_step_q < (TILE_GC_W+1)'(TILE_COLS)) begin
                    rd_en   = 1'b1;
                    rd_addr = mk_addr(db_idx_q, db_step_q[TILE_GC_W-1:0]);
                end
            end
        end
        always_ff @(posedge clk) begin
            if (rd_en) ram_q <= bank_mem[rd_addr];
            rd_data_q <= ram_q;
        end
        logic [W_STRIP-1:0] wr_data;
        logic [W_STRIP-1:0] s2_packed;
        always_comb begin
            s2_packed = pack_strip(s2_strip_q);
            if (s2_first_q) begin
                wr_data = s2_packed;
            end else begin
                wr_data = '0;
                for (int i = 0; i < int'(PHYS_COLS); i++)
                    wr_data[i*ARRAY_ACC_W +: ARRAY_ACC_W] =
                        rd_data_q[i*ARRAY_ACC_W +: ARRAY_ACC_W]
                      + s2_packed[i*ARRAY_ACC_W +: ARRAY_ACC_W];
            end
        end

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                s1_valid_q <= 1'b0; s1_first_q <= 1'b0; s1_addr_q <= '0; s1_strip_q <= '0;
                s2_valid_q <= 1'b0; s2_first_q <= 1'b0; s2_addr_q <= '0; s2_strip_q <= '0;
            end else begin
                s1_valid_q <= (db_state_q == DB_IDLE) && upd_valid;
                s1_first_q <= upd_first;
                s1_addr_q  <= mk_addr(upd_tok, upd_gc);
                s1_strip_q <= phys_strip;
                s2_valid_q <= s1_valid_q;
                s2_first_q <= s1_first_q;
                s2_addr_q  <= s1_addr_q;
                s2_strip_q <= s1_strip_q;
            end
        end

        always_ff @(posedge clk) begin
            if (s2_valid_q) bank_mem[s2_addr_q] <= wr_data;
        end
        logic layer_busy_q;
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                db_state_q  <= DB_IDLE;
                db_idx_q    <= '0;
                db_step_q   <= '0;
                db_settle_q <= '0;
                y_out       <= '0;
                y_valid     <= 1'b0;
            end else begin
                y_valid <= 1'b0;
                unique case (db_state_q)
                    DB_IDLE: begin
                        if (upd_valid && upd_last) begin
                            db_idx_q    <= '0;
                            db_settle_q <= 2'd3;
                            db_state_q  <= DB_SETTLE;
                        end
                    end
                    DB_SETTLE: begin
                        if (db_settle_q == 2'd0) begin
                            db_step_q  <= '0;
                            db_state_q <= DB_FILL;
                        end else begin
                            db_settle_q <= db_settle_q - 2'd1;
                        end
                    end
                    DB_FILL: begin
                        if (db_step_q >= (TILE_GC_W+1)'(2)) begin
                            automatic int unsigned cg = int'(db_step_q) - 2;
                            for (int pc = 0; pc < int'(PHYS_COLS); pc++)
                                y_out[cg*PHYS_COLS + pc] <=
                                    rd_data_q[pc*ARRAY_ACC_W +: ARRAY_ACC_W];
                        end
                        if (db_step_q == (TILE_GC_W+1)'(TILE_COLS+1)) begin
                            db_state_q <= DB_WAITFREE;
                        end else begin
                            db_step_q <= db_step_q + (TILE_GC_W+1)'(1);
                        end
                    end
                    DB_WAITFREE: begin
                        if (!drain_busy) begin
                            y_valid    <= 1'b1;
                            db_state_q <= DB_PULSE;
                        end
                    end
                    DB_PULSE: begin
                        if (db_idx_q == (batch_n - BATCH_TOK_W'(1))) begin
                            db_state_q <= DB_IDLE;
                        end else begin
                            db_idx_q   <= db_idx_q + BATCH_TOK_W'(1);
                            db_step_q  <= '0;
                            db_state_q <= DB_FILL;
                        end
                    end
                    default: db_state_q <= DB_IDLE;
                endcase
            end
        end

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                layer_busy_q <= 1'b0;
            end else if (tile_first) begin
                layer_busy_q <= 1'b1;
            end else if ((db_state_q == DB_PULSE)
                      && (db_idx_q == (batch_n - BATCH_TOK_W'(1)))) begin
                layer_busy_q <= 1'b0;
            end
        end
        assign drain_active = layer_busy_q;

`ifndef SYNTHESIS
        a_no_rmw_collision: assert property (
            @(posedge clk) disable iff (!rst_n)
            (db_state_q == DB_IDLE && upd_valid && s2_valid_q)
              |-> (mk_addr(upd_tok, upd_gc) != s2_addr_q)
        ) else $error("dense_array_bank[%0d]: RMW read aliases in-flight write addr %0d",
                      ARRAY_ID, s2_addr_q);
`endif

    end

`ifndef SYNTHESIS
    a_batch_n_fits: assert property (
        @(posedge clk) disable iff (!rst_n)
        (batch_n >= BATCH_TOK_W'(1)) && (batch_n <= BATCH_TOK_W'(BATCH_T))
    ) else $error("dense_array_bank[%0d]: batch_n=%0d out of range [1,%0d]",
                  ARRAY_ID, batch_n, BATCH_T);

    a_tok_fits: assert property (
        @(posedge clk) disable iff (!rst_n)
        upd_valid |-> (upd_tok < BATCH_TOK_W'(BATCH_T))
    ) else $error("dense_array_bank[%0d]: upd_tok=%0d >= BATCH_T=%0d",
                  ARRAY_ID, upd_tok, BATCH_T);
`endif

endmodule : dense_array_bank

`default_nettype wire
`endif
