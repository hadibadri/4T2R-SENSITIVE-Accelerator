
`timescale 1ns/1ps
`ifndef ARCHBETTER_AXI4_BRAM_SLAVE_SV
`define ARCHBETTER_AXI4_BRAM_SLAVE_SV
`default_nettype none

module axi4_bram_slave #(
    parameter int unsigned AXI_DATA_W = 128,
    parameter int unsigned AXI_ADDR_W = 32,
    parameter int unsigned AXI_ID_W   = 4,
    parameter int unsigned DEPTH      = 2048
) (
    input  wire logic clk,
    input  wire logic rst_n,
    axi4_if.slave     axi
);

    localparam int unsigned BEAT_BYTES = AXI_DATA_W / 8;
    localparam int unsigned AXSIZE     = $clog2(BEAT_BYTES);
    localparam int unsigned IDX_W      = $clog2(DEPTH);
    initial begin : elab_checks
        if ((DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "axi4_bram_slave: DEPTH=%0d must be a power of two", DEPTH);
        if ((BEAT_BYTES & (BEAT_BYTES - 1)) != 0)
            $fatal(1, "axi4_bram_slave: BEAT_BYTES=%0d must be a power of two", BEAT_BYTES);
    end
    function automatic logic [IDX_W-1:0] a2idx(input logic [AXI_ADDR_W-1:0] a);
        return IDX_W'((a >> AXSIZE) & (AXI_ADDR_W'(DEPTH) - 1'b1));
    endfunction
    (* ram_style = "block" *)
    logic [AXI_DATA_W-1:0] mem [DEPTH];

    logic                  wr_en;
    logic [IDX_W-1:0]      wr_idx;
    logic [AXI_DATA_W-1:0] wr_data;
    logic                  rd_en;
    logic [IDX_W-1:0]      rd_idx;
    logic [AXI_DATA_W-1:0] rd_dout1, rd_dout2;

    always_ff @(posedge clk) begin
        if (wr_en) mem[wr_idx] <= wr_data;
        if (rd_en) rd_dout1    <= mem[rd_idx];
        rd_dout2 <= rd_dout1;
    end
    typedef enum logic [1:0] { R_IDLE, R_RD, R_WAIT, R_PRES } rstate_e;
    rstate_e             rstate_q;
    logic [IDX_W-1:0]    r_idx_q;
    logic [7:0]          r_cnt_q;
    logic [AXI_ID_W-1:0] r_id_q;

    assign axi.arready = (rstate_q == R_IDLE);
    assign axi.rvalid  = (rstate_q == R_PRES);
    assign axi.rdata   = rd_dout2;
    assign axi.rlast   = (rstate_q == R_PRES) && (r_cnt_q == 8'd0);
    assign axi.rid     = r_id_q;
    assign axi.rresp   = 2'b00;

    assign rd_en  = (rstate_q == R_RD);
    assign rd_idx = r_idx_q;

    logic ar_fire, r_fire;
    assign ar_fire = axi.arvalid && axi.arready;
    assign r_fire  = axi.rvalid  && axi.rready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rstate_q <= R_IDLE;
            r_idx_q  <= '0;
            r_cnt_q  <= '0;
            r_id_q   <= '0;
        end else begin
            unique case (rstate_q)
                R_IDLE: begin
                    if (ar_fire) begin
                        r_idx_q  <= a2idx(axi.araddr);
                        r_cnt_q  <= axi.arlen;
                        r_id_q   <= axi.arid;
                        rstate_q <= R_RD;
                    end
                end
                R_RD:   rstate_q <= R_WAIT;
                R_WAIT: rstate_q <= R_PRES;
                R_PRES: begin
                    if (r_fire) begin
                        if (r_cnt_q == 8'd0) begin
                            rstate_q <= R_IDLE;
                        end else begin
                            r_idx_q  <= IDX_W'(r_idx_q + 1'b1);
                            r_cnt_q  <= r_cnt_q - 8'd1;
                            rstate_q <= R_RD;
                        end
                    end
                end
                default: rstate_q <= R_IDLE;
            endcase
        end
    end
    typedef enum logic [1:0] { W_IDLE, W_DATA, W_RESP } wstate_e;
    wstate_e             wstate_q;
    logic [IDX_W-1:0]    w_idx_q;
    logic [AXI_ID_W-1:0] b_id_q;

    assign axi.awready = (wstate_q == W_IDLE);
    assign axi.wready  = (wstate_q == W_DATA);
    assign axi.bvalid  = (wstate_q == W_RESP);
    assign axi.bid     = b_id_q;
    assign axi.bresp   = 2'b00;
    assign wr_en   = (wstate_q == W_DATA) && axi.wvalid;
    assign wr_idx  = w_idx_q;
    assign wr_data = axi.wdata;

    logic aw_fire, w_fire, b_fire;
    assign aw_fire = axi.awvalid && axi.awready;
    assign w_fire  = axi.wvalid  && axi.wready;
    assign b_fire  = axi.bvalid  && axi.bready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wstate_q <= W_IDLE;
            w_idx_q  <= '0;
            b_id_q   <= '0;
        end else begin
            unique case (wstate_q)
                W_IDLE: begin
                    if (aw_fire) begin
                        w_idx_q  <= a2idx(axi.awaddr);
                        b_id_q   <= axi.awid;
                        wstate_q <= W_DATA;
                    end
                end
                W_DATA: begin
                    if (w_fire) begin
                        w_idx_q <= IDX_W'(w_idx_q + 1'b1);
                        if (axi.wlast) wstate_q <= W_RESP;
                    end
                end
                W_RESP: if (b_fire) wstate_q <= W_IDLE;
                default: wstate_q <= W_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    a_ar_incr: assert property (@(posedge clk) disable iff (!rst_n)
        ar_fire |-> (axi.arburst == 2'b01))
        else $error("axi4_bram_slave: non-INCR read burst");
    a_aw_incr: assert property (@(posedge clk) disable iff (!rst_n)
        aw_fire |-> (axi.awburst == 2'b01))
        else $error("axi4_bram_slave: non-INCR write burst");
    a_w_in_data: assert property (@(posedge clk) disable iff (!rst_n)
        w_fire |-> (wstate_q == W_DATA))
        else $error("axi4_bram_slave: W beat accepted outside W_DATA");
`endif

endmodule : axi4_bram_slave

`default_nettype wire
`endif
