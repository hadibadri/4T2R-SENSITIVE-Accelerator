
`timescale 1ns/1ps
`default_nettype none

module tb_memory_manager;
    import types_pkg::*;
    localparam int unsigned URAM_DATA_W = URAM_WIDTH_BITS;
    localparam int unsigned URAM_DEP    = URAM_DEPTH;
    localparam int unsigned URAM_AW     = URAM_ADDR_W;
    localparam logic [39:0] DRAM_PATTERN_HI = 40'hCA_FEBA_BECA;

    localparam int unsigned N_DESC_RANDOM  = 12;
    localparam int unsigned MAX_BEATS      = 32;
    logic clk;
    logic rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;
    mem_issue_if    memif (.clk(clk), .rst_n(rst_n));
    kv_access_if    kvif  (.clk(clk), .rst_n(rst_n));
    pingpong_if #(.ADDR_W(URAM_AW), .DATA_W(DENSE_PP_URAM_W)) dense_pp
        (.clk(clk), .rst_n(rst_n));
    pingpong_if #(.ADDR_W(URAM_AW), .DATA_W(URAM_DATA_W)) sparse_pp
        (.clk(clk), .rst_n(rst_n));
    csd_dram_if     dramif    (.clk(clk), .rst_n(rst_n));
    csd_dram_wr_if  dram_wrif (.clk(clk), .rst_n(rst_n));
    logic              desc_we;
    logic [7:0]        desc_wr_addr;
    csd_descriptor_t   desc_wr_data;
    logic                       out_wr_en;
    logic [URAM_AW-1:0]         out_wr_addr;
    logic [URAM_DATA_W-1:0]     out_wr_data;
    memory_manager #(
        .DESC_DEPTH(256)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .issue        (memif.mgr),
        .kv           (kvif.slave),
        .dense_pp     (dense_pp.mem_mgr),
        .sparse_pp    (sparse_pp.mem_mgr),
        .dram         (dramif.mgr),
        .dram_wr      (dram_wrif.mgr),
        .out_wr_en    (out_wr_en),
        .out_wr_addr  (out_wr_addr),
        .out_wr_data  (out_wr_data),
        .desc_we      (desc_we),
        .desc_wr_addr (desc_wr_addr),
        .desc_wr_data (desc_wr_data)
    );
    typedef enum logic [1:0] {
        D_IDLE = 2'b00,
        D_REQ  = 2'b01,
        D_RESP = 2'b10
    } dram_state_e;

    dram_state_e            dram_state_q;
    logic [DRAM_ADDR_W-1:0] dram_addr_q;
    logic [DRAM_LEN_W-1:0]  dram_len_q;
    logic [DRAM_LEN_W-1:0]  dram_idx_q;

    logic                   stub_req_ready;
    logic                   stub_rsp_valid;
    logic                   stub_rsp_last;
    logic [DRAM_BEAT_W-1:0] stub_rsp_data;

    always_comb begin
        stub_req_ready = 1'b0;
        stub_rsp_valid = 1'b0;
        stub_rsp_last  = 1'b0;
        stub_rsp_data  = '0;
        unique case (dram_state_q)
            D_IDLE: begin
                stub_req_ready = 1'b0;
            end
            D_REQ: begin
                stub_req_ready = 1'b1;
            end
            D_RESP: begin
                stub_rsp_valid = 1'b1;
                stub_rsp_last  = (dram_idx_q == DRAM_LEN_W'(dram_len_q - 1'b1));
                stub_rsp_data  = {DRAM_PATTERN_HI,
                                   DRAM_ADDR_W'(dram_addr_q + DRAM_ADDR_W'(dram_idx_q << 3))};
            end
            default: ;
        endcase
    end

    assign dramif.req_ready = stub_req_ready;
    assign dramif.rsp_valid = stub_rsp_valid;
    assign dramif.rsp_last  = stub_rsp_last;
    assign dramif.rsp_data  = stub_rsp_data;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dram_state_q <= D_IDLE;
            dram_addr_q  <= '0;
            dram_len_q   <= '0;
            dram_idx_q   <= '0;
        end else begin
            unique case (dram_state_q)
                D_IDLE: begin
                    if (dramif.req_valid) begin
                        dram_state_q <= D_REQ;
                    end
                end
                D_REQ: begin
                    if (dramif.req_valid) begin
                        dram_addr_q  <= dramif.req_addr;
                        dram_len_q   <= dramif.req_len;
                        dram_idx_q   <= '0;
                        dram_state_q <= D_RESP;
                    end
                end
                D_RESP: begin
                    if (dramif.rsp_ready && stub_rsp_valid) begin
                        if (stub_rsp_last) begin
                            dram_state_q <= D_IDLE;
                        end else begin
                            dram_idx_q <= DRAM_LEN_W'(dram_idx_q + 1'b1);
                        end
                    end
                end
                default: dram_state_q <= D_IDLE;
            endcase
        end
    end
    typedef enum logic [1:0] {
        WR_IDLE = 2'b00,
        WR_DATA = 2'b01
    } wr_state_e;

    wr_state_e             wr_state_q;
    logic [DRAM_ADDR_W-1:0] wr_base_q;
    logic [DRAM_LEN_W-1:0]  wr_idx_q;

    typedef struct {
        logic [DRAM_BEAT_W-1:0] data;
        logic                   last;
        logic [DRAM_ADDR_W-1:0] base_addr;
        logic [DRAM_LEN_W-1:0]  beat_idx;
    } st_out_beat_t;

    st_out_beat_t st_out_beats [$];
    assign dram_wrif.req_ready = (wr_state_q == WR_IDLE);
    assign dram_wrif.wd_ready  = (wr_state_q == WR_DATA);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_state_q <= WR_IDLE;
            wr_base_q  <= '0;
            wr_idx_q   <= '0;
        end else begin
            unique case (wr_state_q)
                WR_IDLE: begin
                    if (dram_wrif.req_valid && dram_wrif.req_ready) begin
                        wr_base_q  <= dram_wrif.req_addr;
                        wr_idx_q   <= '0;
                        wr_state_q <= WR_DATA;
                    end
                end
                WR_DATA: begin
                    if (dram_wrif.wd_valid && dram_wrif.wd_ready) begin
                        if (dram_wrif.wd_last) begin
                            wr_state_q <= WR_IDLE;
                        end else begin
                            wr_idx_q <= DRAM_LEN_W'(wr_idx_q + 1'b1);
                        end
                    end
                end
                default: wr_state_q <= WR_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n
            && wr_state_q == WR_DATA
            && dram_wrif.wd_valid && dram_wrif.wd_ready) begin
            automatic st_out_beat_t b;
            b.data      = dram_wrif.wd_data;
            b.last      = dram_wrif.wd_last;
            b.base_addr = wr_base_q;
            b.beat_idx  = wr_idx_q;
            st_out_beats.push_back(b);
        end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dense_pp.drain_ack  <= 1'b0;
            sparse_pp.drain_ack <= 1'b0;
        end else begin
            dense_pp.drain_ack  <= dense_pp.drain_req  && !dense_pp.drain_ack;
            sparse_pp.drain_ack <= sparse_pp.drain_req && !sparse_pp.drain_ack;
        end
    end
    logic [URAM_DATA_W-1:0] gold_d_a [URAM_DEP];
    logic [URAM_DATA_W-1:0] gold_d_b [URAM_DEP];
    logic                   gold_d_a_w [URAM_DEP];
    logic                   gold_d_b_w [URAM_DEP];

    logic [URAM_DATA_W-1:0] gold_s_a [URAM_DEP];
    logic [URAM_DATA_W-1:0] gold_s_b [URAM_DEP];
    logic                   gold_s_a_w [URAM_DEP];
    logic                   gold_s_b_w [URAM_DEP];
    csd_descriptor_t        running_desc;
    logic                   running_active;
    int unsigned            running_idx;

    int unsigned checks    = 0;
    int unsigned errors    = 0;
    int unsigned tb_errors = 0;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            running_desc   <= '0;
            running_active <= 1'b0;
            running_idx    <= 0;
        end else begin
            if (memif.start
                && ((memif.opc == OP_LD_W_URAM) || (memif.opc == OP_LD_A_URAM))) begin
                running_desc   <= dut.desc_lookup;
                running_active <= 1'b1;
                running_idx    <= 0;
            end
            if (running_active && memif.done) begin
                running_active <= 1'b0;
            end
        end
    end
    task automatic score_fill(
        input logic is_sparse_pool,
        input bank_sel_e fill_side,
        input logic [URAM_AW-1:0] wr_addr,
        input logic [URAM_DATA_W-1:0] wr_data
    );
        logic [URAM_AW-1:0]     exp_addr;
        logic [URAM_DATA_W-1:0] exp_data;

        if (!running_active) begin
            tb_errors++;
            $display("[%0t] OBS: fill write with no active descriptor (pool=%0s)",
                     $time, is_sparse_pool ? "sparse" : "dense");
            return;
        end
        if (running_desc.is_sparse !== is_sparse_pool) begin
            tb_errors++;
            $display("[%0t] OBS: fill landed in wrong pool (desc.is_sparse=%0b, pool=%0s)",
                     $time, running_desc.is_sparse, is_sparse_pool ? "sparse" : "dense");
            return;
        end
        exp_addr = URAM_AW'(running_desc.uram_base + URAM_AW'(running_idx));
        exp_data = {DRAM_PATTERN_HI,
                    DRAM_ADDR_W'(running_desc.dram_base + DRAM_ADDR_W'(running_idx << 3))};
        checks++;
        if (wr_addr !== exp_addr) begin
            errors++;
            $display("[%0t] FILL ADDR MISMATCH pool=%0s idx=%0d exp=0x%0h got=0x%0h",
                     $time, is_sparse_pool ? "sparse" : "dense",
                     running_idx, exp_addr, wr_addr);
        end
        if (wr_data !== exp_data) begin
            errors++;
            $display("[%0t] FILL DATA MISMATCH pool=%0s idx=%0d exp=0x%0h got=0x%0h",
                     $time, is_sparse_pool ? "sparse" : "dense",
                     running_idx, exp_data, wr_data);
        end
        if (!is_sparse_pool) begin
            if (fill_side == BANK_A) begin
                gold_d_a[wr_addr]   = wr_data;
                gold_d_a_w[wr_addr] = 1'b1;
            end else begin
                gold_d_b[wr_addr]   = wr_data;
                gold_d_b_w[wr_addr] = 1'b1;
            end
        end else begin
            if (fill_side == BANK_A) begin
                gold_s_a[wr_addr]   = wr_data;
                gold_s_a_w[wr_addr] = 1'b1;
            end else begin
                gold_s_b[wr_addr]   = wr_data;
                gold_s_b_w[wr_addr] = 1'b1;
            end
        end

        running_idx++;
    endtask

    always_ff @(posedge clk) begin
        if (rst_n && dut.dense_fill_wr_en) begin
            score_fill(.is_sparse_pool(1'b0),
                       .fill_side(dut.dense_fill_side),
                       .wr_addr(dut.csd_fill_wr_addr),
                       .wr_data(dut.csd_fill_wr_data));
        end
        if (rst_n && dut.sparse_fill_wr_en) begin
            score_fill(.is_sparse_pool(1'b1),
                       .fill_side(dut.sparse_fill_side),
                       .wr_addr(dut.csd_fill_wr_addr),
                       .wr_data(dut.csd_fill_wr_data));
        end
    end
    logic [URAM_AW-1:0] d_rd_addr_q1, d_rd_addr_q2;
    logic               d_rd_en_q1,   d_rd_en_q2;
    bank_sel_e          d_rd_side_q1, d_rd_side_q2;

    logic [URAM_AW-1:0] s_rd_addr_q1, s_rd_addr_q2;
    logic               s_rd_en_q1,   s_rd_en_q2;
    bank_sel_e          s_rd_side_q1, s_rd_side_q2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            d_rd_addr_q1 <= '0; d_rd_addr_q2 <= '0;
            d_rd_en_q1   <= 1'b0; d_rd_en_q2 <= 1'b0;
            d_rd_side_q1 <= BANK_A; d_rd_side_q2 <= BANK_A;
            s_rd_addr_q1 <= '0; s_rd_addr_q2 <= '0;
            s_rd_en_q1   <= 1'b0; s_rd_en_q2 <= 1'b0;
            s_rd_side_q1 <= BANK_A; s_rd_side_q2 <= BANK_A;
        end else begin
            d_rd_addr_q1 <= dense_pp.rd_addr;
            d_rd_addr_q2 <= d_rd_addr_q1;
            d_rd_en_q1   <= dense_pp.rd_en;
            d_rd_en_q2   <= d_rd_en_q1;
            d_rd_side_q1 <= dut.dense_compute_side;
            d_rd_side_q2 <= d_rd_side_q1;

            s_rd_addr_q1 <= sparse_pp.rd_addr;
            s_rd_addr_q2 <= s_rd_addr_q1;
            s_rd_en_q1   <= sparse_pp.rd_en;
            s_rd_en_q2   <= s_rd_en_q1;
            s_rd_side_q1 <= dut.sparse_compute_side;
            s_rd_side_q2 <= s_rd_side_q1;
        end
    end
    always_ff @(posedge clk) begin
        if (rst_n && dense_pp.rd_valid) begin
            logic [DENSE_PP_URAM_W-1:0] d_exp;
            logic                       d_all_w;
            logic [URAM_AW-1:0]         d_nbase;
            d_exp   = '0;
            d_all_w = 1'b1;
            d_nbase = URAM_AW'(d_rd_addr_q2 << $clog2(DENSE_PP_URAM_WIDE));
            unique case (d_rd_side_q2)
                BANK_A: begin
                    for (int leaf = 0; leaf < int'(DENSE_PP_URAM_WIDE); leaf++) begin
                        if (gold_d_a_w[d_nbase + URAM_AW'(leaf)])
                            d_exp[leaf*URAM_DATA_W +: URAM_DATA_W] = gold_d_a[d_nbase + URAM_AW'(leaf)];
                        else
                            d_all_w = 1'b0;
                    end
                    if (d_all_w) begin
                        checks = checks + 1;
                        if (dense_pp.rd_data !== d_exp) begin
                            errors = errors + 1;
                            $display("[%0t] DENSE READBACK MISMATCH bank=A wide=0x%0h exp=0x%0h got=0x%0h",
                                     $time, d_rd_addr_q2, d_exp, dense_pp.rd_data);
                        end
                    end
                end
                BANK_B: begin
                    for (int leaf = 0; leaf < int'(DENSE_PP_URAM_WIDE); leaf++) begin
                        if (gold_d_b_w[d_nbase + URAM_AW'(leaf)])
                            d_exp[leaf*URAM_DATA_W +: URAM_DATA_W] = gold_d_b[d_nbase + URAM_AW'(leaf)];
                        else
                            d_all_w = 1'b0;
                    end
                    if (d_all_w) begin
                        checks = checks + 1;
                        if (dense_pp.rd_data !== d_exp) begin
                            errors = errors + 1;
                            $display("[%0t] DENSE READBACK MISMATCH bank=B wide=0x%0h exp=0x%0h got=0x%0h",
                                     $time, d_rd_addr_q2, d_exp, dense_pp.rd_data);
                        end
                    end
                end
                default: ;
            endcase
        end
        if (rst_n && sparse_pp.rd_valid) begin
            unique case (s_rd_side_q2)
                BANK_A: if (gold_s_a_w[s_rd_addr_q2]) begin
                    checks = checks + 1;
                    if (sparse_pp.rd_data !== gold_s_a[s_rd_addr_q2]) begin
                        errors = errors + 1;
                        $display("[%0t] SPARSE READBACK MISMATCH bank=A addr=0x%0h exp=0x%0h got=0x%0h",
                                 $time, s_rd_addr_q2, gold_s_a[s_rd_addr_q2], sparse_pp.rd_data);
                    end
                end
                BANK_B: if (gold_s_b_w[s_rd_addr_q2]) begin
                    checks = checks + 1;
                    if (sparse_pp.rd_data !== gold_s_b[s_rd_addr_q2]) begin
                        errors = errors + 1;
                        $display("[%0t] SPARSE READBACK MISMATCH bank=B addr=0x%0h exp=0x%0h got=0x%0h",
                                 $time, s_rd_addr_q2, gold_s_b[s_rd_addr_q2], sparse_pp.rd_data);
                    end
                end
                default: ;
            endcase
        end
    end
    logic [KV_DATA_W-1:0] gold_kv [KV_DEPTH];
    logic                 gold_kv_w [KV_DEPTH];
    logic [KV_ADDR_W-1:0] kv_rd_addr_q1, kv_rd_addr_q2;
    logic                 kv_rd_en_q1,   kv_rd_en_q2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            kv_rd_addr_q1 <= '0; kv_rd_addr_q2 <= '0;
            kv_rd_en_q1   <= 1'b0; kv_rd_en_q2 <= 1'b0;
        end else begin
            kv_rd_addr_q1 <= kvif.rd_addr;
            kv_rd_addr_q2 <= kv_rd_addr_q1;
            kv_rd_en_q1   <= kvif.rd_en;
            kv_rd_en_q2   <= kv_rd_en_q1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && kvif.rd_valid && gold_kv_w[kv_rd_addr_q2]) begin
            checks = checks + 1;
            if (kvif.rd_data !== gold_kv[kv_rd_addr_q2]) begin
                errors = errors + 1;
                $display("[%0t] KV MISMATCH addr=0x%0h exp=0x%0h got=0x%0h",
                         $time, kv_rd_addr_q2, gold_kv[kv_rd_addr_q2], kvif.rd_data);
            end
        end
    end
    task automatic drive_idle();
        memif.start     <= 1'b0;
        memif.busy      <= 1'b0;
        memif.opc       <= OP_NOP;
        memif.tile_id   <= '0;
        memif.is_sparse <= 1'b0;
        kvif.wr_en      <= 1'b0;
        kvif.wr_addr    <= '0;
        kvif.wr_data    <= '0;
        kvif.rd_en      <= 1'b0;
        kvif.rd_addr    <= '0;
        dense_pp.rd_en    <= 1'b0;
        dense_pp.rd_addr  <= '0;
        sparse_pp.rd_en   <= 1'b0;
        sparse_pp.rd_addr <= '0;
        desc_we      <= 1'b0;
        desc_wr_addr <= '0;
        desc_wr_data <= '0;
        out_wr_en    <= 1'b0;
        out_wr_addr  <= '0;
        out_wr_data  <= '0;
    endtask

    task automatic write_desc(input logic [7:0]       addr,
                              input csd_descriptor_t  d);
        @(negedge clk);
        desc_we      = 1'b1;
        desc_wr_addr = addr;
        desc_wr_data = d;
        @(posedge clk);
        @(negedge clk);
        desc_we      = 1'b0;
    endtask

    function automatic csd_descriptor_t mk_desc(
        input logic                    is_sparse,
        input logic [URAM_AW-1:0]      uram_base,
        input logic [DRAM_ADDR_W-1:0]  dram_base,
        input logic [DRAM_LEN_W-1:0]   n_beats);
        csd_descriptor_t d;
        d.compressed = 1'b0;
        d.is_sparse  = is_sparse;
        d.uram_base  = uram_base;
        d.dram_base  = dram_base;
        d.n_beats    = n_beats;
        return d;
    endfunction
    task automatic issue_mem_op(input macro_opc_e opc,
                                 input logic [7:0] tile_id,
                                 input logic       is_sparse);
        @(negedge clk);
        memif.opc       = opc;
        memif.tile_id   = tile_id;
        memif.is_sparse = is_sparse;
        memif.start     = 1'b1;
        memif.busy      = 1'b1;
        @(posedge clk);
        @(negedge clk);
        memif.start     = 1'b0;
        while (memif.done !== 1'b1) @(posedge clk);
        @(negedge clk);
        memif.busy      = 1'b0;
    endtask

    task automatic kv_write(input logic [KV_ADDR_W-1:0] a,
                             input logic [KV_DATA_W-1:0] d);
        @(negedge clk);
        kvif.wr_en   = 1'b1;
        kvif.wr_addr = a;
        kvif.wr_data = d;
        gold_kv[a]   = d;
        gold_kv_w[a] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        kvif.wr_en   = 1'b0;
    endtask

    task automatic kv_read(input logic [KV_ADDR_W-1:0] a);
        @(negedge clk);
        kvif.rd_en   = 1'b1;
        kvif.rd_addr = a;
        @(posedge clk);
        @(negedge clk);
        kvif.rd_en   = 1'b0;
    endtask
    task automatic dense_read(input logic [URAM_AW-1:0] a);
        @(negedge clk);
        dense_pp.rd_en   = 1'b1;
        dense_pp.rd_addr = a;
        @(posedge clk);
        @(negedge clk);
        dense_pp.rd_en   = 1'b0;
    endtask

    task automatic sparse_read(input logic [URAM_AW-1:0] a);
        @(negedge clk);
        sparse_pp.rd_en   = 1'b1;
        sparse_pp.rd_addr = a;
        @(posedge clk);
        @(negedge clk);
        sparse_pp.rd_en   = 1'b0;
    endtask

    function automatic logic [KV_DATA_W-1:0] rand_kv_data();
        logic [KV_DATA_W-1:0] d;
        d = {$urandom(), $urandom(), $urandom(), $urandom(), $urandom()};
        return d;
    endfunction
    always_ff @(posedge clk) begin
        if (rst_n && memif.done && $past(memif.done, 1)) begin
            tb_errors = tb_errors + 1;
            $display("[%0t] memif.done held high > 1 cycle", $time);
        end
    end
    initial begin : main
        for (int i = 0; i < URAM_DEP; i++) begin
            gold_d_a[i] = '0; gold_d_a_w[i] = 1'b0;
            gold_d_b[i] = '0; gold_d_b_w[i] = 1'b0;
            gold_s_a[i] = '0; gold_s_a_w[i] = 1'b0;
            gold_s_b[i] = '0; gold_s_b_w[i] = 1'b0;
        end
        for (int i = 0; i < KV_DEPTH; i++) begin
            gold_kv[i] = '0; gold_kv_w[i] = 1'b0;
        end

        rst_n = 1'b0;
        drive_idle();
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        $display("[%0t] STAGE 0: reset quiescent", $time);
        if (memif.done !== 1'b0) begin
            tb_errors++;
            $display("[%0t] STAGE 0 FAIL: memif.done=%0b", $time, memif.done);
        end
        if (dense_pp.drain_req !== 1'b0 || sparse_pp.drain_req !== 1'b0) begin
            tb_errors++;
            $display("[%0t] STAGE 0 FAIL: pingpong drain_req asserted", $time);
        end
        if (dut.dense_compute_side !== BANK_A || dut.sparse_compute_side !== BANK_A) begin
            tb_errors++;
            $display("[%0t] STAGE 0 FAIL: initial compute sides wrong (d=%s s=%s)",
                     $time, dut.dense_compute_side.name(), dut.sparse_compute_side.name());
        end
        if (kvif.rd_valid !== 1'b0) begin
            tb_errors++;
            $display("[%0t] STAGE 0 FAIL: kv.rd_valid=%0b", $time, kvif.rd_valid);
        end
        $display("[%0t] STAGE 1: dense OP_LD_W_URAM + OP_PINGPONG + readback", $time);
        write_desc(8'h00, mk_desc(.is_sparse(1'b0),
                                   .uram_base(URAM_AW'(12'h020)),
                                   .dram_base(32'h0000_1000),
                                   .n_beats(16'd8)));
        issue_mem_op(OP_LD_W_URAM, 8'h00, 1'b0);
        issue_mem_op(OP_PINGPONG, 8'h00, 1'b0);
        for (int j = 0; j < 8 / int'(DENSE_PP_URAM_WIDE); j++) begin
            dense_read(URAM_AW'((12'h020 >> $clog2(DENSE_PP_URAM_WIDE)) + j));
        end
        repeat (4) @(posedge clk);
        if (dut.dense_compute_side !== BANK_B) begin
            tb_errors++;
            $display("[%0t] STAGE 1 FAIL: dense compute side=%s after swap, expected BANK_B",
                     $time, dut.dense_compute_side.name());
        end
        $display("[%0t] STAGE 2: sparse OP_LD_A_URAM + OP_PINGPONG + readback", $time);
        write_desc(8'h01, mk_desc(.is_sparse(1'b1),
                                   .uram_base(URAM_AW'(12'h040)),
                                   .dram_base(32'h0000_2000),
                                   .n_beats(16'd16)));
        issue_mem_op(OP_LD_A_URAM, 8'h01, 1'b1);
        issue_mem_op(OP_PINGPONG, 8'h01, 1'b1);
        for (int i = 0; i < 16; i++) begin
            sparse_read(URAM_AW'(12'h040 + i));
        end
        repeat (4) @(posedge clk);
        if (dut.sparse_compute_side !== BANK_B) begin
            tb_errors++;
            $display("[%0t] STAGE 2 FAIL: sparse compute side=%s after swap, expected BANK_B",
                     $time, dut.sparse_compute_side.name());
        end
        if (dut.dense_compute_side !== BANK_B) begin
            tb_errors++;
            $display("[%0t] STAGE 2 FAIL: dense compute side disturbed (%s)",
                     $time, dut.dense_compute_side.name());
        end
        $display("[%0t] STAGE 3: OP_ST_OUT end-to-end drain", $time);
        begin : stage3
            localparam int unsigned ST_OUT_NBEATS = 32;
            localparam logic [URAM_AW-1:0]      ST_URAM_BASE = URAM_AW'(12'h0C0);
            localparam logic [DRAM_ADDR_W-1:0]  ST_DRAM_BASE = 32'hCAFE_0000;
            int unsigned wait_iters;
            for (int i = 0; i < int'(ST_OUT_NBEATS); i++) begin
                @(negedge clk);
                out_wr_en   = 1'b1;
                out_wr_addr = URAM_AW'(ST_URAM_BASE + URAM_AW'(i));
                out_wr_data = {40'hDA_DAFE_BABE,
                               32'(i) ^ 32'h13572468};
                @(posedge clk);
            end
            @(negedge clk); out_wr_en = 1'b0;
            repeat (2) @(posedge clk);
            write_desc(8'hFF, mk_desc(.is_sparse(1'b0),
                                      .uram_base(ST_URAM_BASE),
                                      .dram_base(ST_DRAM_BASE),
                                      .n_beats(DRAM_LEN_W'(ST_OUT_NBEATS))));
            wait_iters = st_out_beats.size();
            issue_mem_op(OP_ST_OUT, 8'hFF, 1'b0);
            repeat (16) @(posedge clk);
            if (st_out_beats.size() - wait_iters !== int'(ST_OUT_NBEATS)) begin
                tb_errors++;
                $display("[%0t] STAGE 3 FAIL: drained %0d beats, expected %0d",
                         $time, st_out_beats.size() - wait_iters, ST_OUT_NBEATS);
            end else begin
                for (int i = 0; i < int'(ST_OUT_NBEATS); i++) begin
                    automatic st_out_beat_t b;
                    automatic logic [URAM_DATA_W-1:0] exp_w;
                    b = st_out_beats[wait_iters + i];
                    exp_w = {40'hDA_DAFE_BABE,
                             32'(i) ^ 32'h13572468};
                    checks++;
                    if (b.data !== exp_w) begin
                        errors++;
                        $display("[%0t] STAGE 3 beat[%0d] data: exp=0x%0h got=0x%0h",
                                 $time, i, exp_w, b.data);
                    end
                    checks++;
                    if (b.base_addr !== ST_DRAM_BASE) begin
                        errors++;
                        $display("[%0t] STAGE 3 beat[%0d] base_addr: exp=0x%0h got=0x%0h",
                                 $time, i, ST_DRAM_BASE, b.base_addr);
                    end
                    checks++;
                    if (b.last !== (i == int'(ST_OUT_NBEATS) - 1)) begin
                        errors++;
                        $display("[%0t] STAGE 3 beat[%0d] last: exp=%0b got=%0b",
                                 $time, i, (i == int'(ST_OUT_NBEATS) - 1), b.last);
                    end
                end
            end
        end
        $display("[%0t] STAGE 4: KV directed write/read round-trip", $time);
        kv_write(14'h0010, {16'hFEED, 128'hAAAA_5555_AAAA_5555_AAAA_5555_AAAA_5555});
        kv_read(14'h0010);
        @(posedge clk); @(posedge clk);
        @(negedge clk);
        kvif.wr_en = 1'b1;
        for (int i = 0; i < 16; i++) begin
            kvif.wr_addr = KV_ADDR_W'(14'h0100 + i);
            kvif.wr_data = {16'(i), 128'hC0FFEE_DECAF_BAD_F00D_C0FFEE_DECAF_F00D};
            gold_kv[kvif.wr_addr]   = kvif.wr_data;
            gold_kv_w[kvif.wr_addr] = 1'b1;
            @(posedge clk); @(negedge clk);
        end
        kvif.wr_en = 1'b0;
        @(posedge clk);
        @(negedge clk);
        kvif.rd_en = 1'b1;
        for (int i = 0; i < 16; i++) begin
            kvif.rd_addr = KV_ADDR_W'(14'h0100 + i);
            @(posedge clk); @(negedge clk);
        end
        kvif.rd_en = 1'b0;
        repeat (3) @(posedge clk);
        $display("[%0t] STAGE 5: random %0d descriptors + interleaved KV", $time, N_DESC_RANDOM);
        begin : stage5
            for (int d = 0; d < N_DESC_RANDOM; d++) begin
                csd_descriptor_t desc;
                logic            is_sp;
                logic [URAM_AW-1:0] base;
                int unsigned     nb;

                is_sp = $urandom_range(0, 1);
                nb    = $urandom_range(1, MAX_BEATS);
                base  = URAM_AW'($urandom_range(0, URAM_DEP - MAX_BEATS - int'(DENSE_PP_URAM_WIDE)));
                if (!is_sp) begin
                    base = URAM_AW'(base & ~URAM_AW'(DENSE_PP_URAM_WIDE - 1));
                    nb   = ((nb + int'(DENSE_PP_URAM_WIDE) - 1) / int'(DENSE_PP_URAM_WIDE))
                           * int'(DENSE_PP_URAM_WIDE);
                end
                desc  = mk_desc(.is_sparse(is_sp),
                                 .uram_base(base),
                                 .dram_base({$urandom_range(0, 32'h00FF_FFFF), 3'b000}),
                                 .n_beats(DRAM_LEN_W'(nb)));
                write_desc(8'(d + 2), desc);
                issue_mem_op(OP_LD_W_URAM, 8'(d + 2), is_sp);
                if ((d % 3) == 0) begin
                    kv_write(KV_ADDR_W'($urandom_range(0, KV_DEPTH-1)), rand_kv_data());
                end
                if ((d % 4) == 3) begin
                    issue_mem_op(OP_PINGPONG, 8'h00, is_sp);
                    for (int i = 0; i < 4; i++) begin
                        automatic logic [URAM_AW-1:0] ra;
                        if (is_sp) begin
                            ra = URAM_AW'(desc.uram_base + URAM_AW'(i % nb));
                            sparse_read(ra);
                        end else begin
                            ra = URAM_AW'((desc.uram_base >> $clog2(DENSE_PP_URAM_WIDE))
                                          + URAM_AW'(i % (nb / int'(DENSE_PP_URAM_WIDE))));
                            dense_read(ra);
                        end
                    end
                    repeat (2) @(posedge clk);
                end
            end
            repeat (4) @(posedge clk);
        end
        $display("[%0t] STAGE 6: unsupported-opcode nop path", $time);
        issue_mem_op(OP_NOP, 8'h00, 1'b0);
        repeat (4) @(posedge clk);
        $display("=========================================================");
        if (errors == 0 && tb_errors == 0) begin
            $display(" tb_memory_manager: PASS  (%0d checks, 0 errors)", checks);
        end else begin
            $display(" tb_memory_manager: FAIL  (%0d checks, %0d compare errors, %0d tb errors)",
                     checks, errors, tb_errors);
        end
        $display("=========================================================");
        $finish;
    end
    initial begin : watchdog
        #(5_000_000);
        $fatal(1, "tb_memory_manager: watchdog expired");
    end

endmodule : tb_memory_manager

`default_nettype wire
