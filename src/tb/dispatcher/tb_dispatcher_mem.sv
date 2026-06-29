
`ifndef ARCHBETTER_TB_DISPATCHER_MEM_SV
`define ARCHBETTER_TB_DISPATCHER_MEM_SV
`default_nettype none
`timescale 1ns/1ps

module tb_dispatcher_mem
    import types_pkg::*;
();
    localparam time T_CLK       = 10ns;
    localparam int  IMEM_DEPTH  = 64;
    localparam int  IMEM_ADDR_W = $clog2(IMEM_DEPTH);
    localparam int  N_SOURCES   = 1;
    localparam int  URAM_DATA_W = URAM_WIDTH_BITS;
    localparam int  URAM_AW     = URAM_ADDR_W;
    localparam logic [39:0] DRAM_PATTERN_HI = 40'hCA_FEBA_BECA;

    localparam int  N_BEATS_SMALL = 8;
    logic clk;
    logic rst_n;
    initial clk = 1'b0;
    always #(T_CLK/2) clk = ~clk;
    noc_cfg_if    cfg_bus (.clk(clk), .rst_n(rst_n));
    gemm_issue_if gemm_bus (.clk(clk), .rst_n(rst_n));
    tlmm_issue_if tlmm_bus (.clk(clk), .rst_n(rst_n));
    mem_issue_if  memif   (.clk(clk), .rst_n(rst_n));
    kv_access_if  kvif    (.clk(clk), .rst_n(rst_n));

    pingpong_if #(.ADDR_W(URAM_AW), .DATA_W(URAM_DATA_W)) dense_pp
        (.clk(clk), .rst_n(rst_n));
    pingpong_if #(.ADDR_W(URAM_AW), .DATA_W(URAM_DATA_W)) sparse_pp
        (.clk(clk), .rst_n(rst_n));
    csd_dram_if dramif (.clk(clk), .rst_n(rst_n));
    csd_dram_wr_if dram_wr_if (.clk(clk), .rst_n(rst_n));
    assign dram_wr_if.req_ready = 1'b1;
    assign dram_wr_if.wd_ready  = 1'b1;
    logic                       out_wr_en;
    logic [URAM_ADDR_W-1:0]     out_wr_addr;
    logic [URAM_WIDTH_BITS-1:0] out_wr_data;
    logic              desc_we;
    logic [7:0]        desc_wr_addr;
    csd_descriptor_t   desc_wr_data;
    dense_sched_if sched_bus (.clk(clk), .rst_n(rst_n));
    assign sched_bus.load_done = 1'b0;
    assign sched_bus.w_we      = 1'b0;
    assign sched_bus.w_phys_gc = '0;
    assign sched_bus.w_pe_addr = '0;
    assign sched_bus.w_in      = '0;
    logic                     start;
    logic                     program_done;
    logic                     imem_we;
    logic [IMEM_ADDR_W-1:0]   imem_wr_addr;
    logic [MACRO_WORD_W-1:0]  imem_wr_data;
    logic [NOC_PATH_ID_W-1:0] path_id [N_SOURCES];
    logic [KV_DATA_W-1:0]     kv_wr_data_sideband;
    dispatcher #(
        .IMEM_DEPTH    (IMEM_DEPTH),
        .N_NOC_SOURCES (N_SOURCES)
    ) u_disp (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .program_done (program_done),
        .imem_we      (imem_we),
        .imem_wr_addr (imem_wr_addr),
        .imem_wr_data (imem_wr_data),
        .path_id_o    (path_id),
        .noc_cfg      (cfg_bus.master),
        .gemm         (gemm_bus.disp),
        .tlmm         (tlmm_bus.disp),
        .sched        (sched_bus.walker),
        .mem_issue    (memif.disp),
        .kv           (kvif.master),
        .kv_wr_data_i (kv_wr_data_sideband),
        .dense_drain_busy (1'b0)
    );

    memory_manager #(
        .DESC_DEPTH (256)
    ) u_memmgr (
        .clk          (clk),
        .rst_n        (rst_n),
        .issue        (memif.mgr),
        .kv           (kvif.slave),
        .dense_pp     (dense_pp.mem_mgr),
        .sparse_pp    (sparse_pp.mem_mgr),
        .dram         (dramif.mgr),
        .dram_wr      (dram_wr_if.mgr),
        .out_wr_en    (out_wr_en),
        .out_wr_addr  (out_wr_addr),
        .out_wr_data  (out_wr_data),
        .desc_we      (desc_we),
        .desc_wr_addr (desc_wr_addr),
        .desc_wr_data (desc_wr_data)
    );
    assign cfg_bus.cfg_ready = 1'b1;
    assign gemm_bus.beat_fire = 1'b0;
    assign tlmm_bus.done      = 1'b0;
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
            D_IDLE: ;
            D_REQ : stub_req_ready = 1'b1;
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
                D_IDLE: if (dramif.req_valid) dram_state_q <= D_REQ;
                D_REQ : if (dramif.req_valid) begin
                    dram_addr_q  <= dramif.req_addr;
                    dram_len_q   <= dramif.req_len;
                    dram_idx_q   <= '0;
                    dram_state_q <= D_RESP;
                end
                D_RESP: if (dramif.rsp_ready && stub_rsp_valid) begin
                    if (stub_rsp_last) dram_state_q <= D_IDLE;
                    else               dram_idx_q   <= DRAM_LEN_W'(dram_idx_q + 1'b1);
                end
                default: dram_state_q <= D_IDLE;
            endcase
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
    assign dense_pp.rd_en   = 1'b0;
    assign dense_pp.rd_addr = '0;
    assign sparse_pp.rd_en  = 1'b0;
    assign sparse_pp.rd_addr = '0;
    typedef struct packed {
        macro_opc_e opc;
        logic [7:0] tile_id;
        logic       is_sparse;
    } mem_obs_t;

    mem_obs_t mem_exp_q [$];
    mem_obs_t mem_obs_q [$];

    always_ff @(posedge clk) begin
        if (rst_n && memif.start) begin
            mem_obs_t e;
            e.opc       = memif.opc;
            e.tile_id   = memif.tile_id;
            e.is_sparse = memif.is_sparse;
            mem_obs_q.push_back(e);
        end
    end
    logic [KV_DATA_W-1:0] kv_mirror [2**KV_ADDR_W];

    typedef struct packed {
        logic                 is_read;
        logic [KV_ADDR_W-1:0] addr;
        logic [KV_DATA_W-1:0] data;
    } kv_obs_t;

    kv_obs_t kv_exp_q [$];
    kv_obs_t kv_obs_q [$];
    logic [KV_ADDR_W-1:0] kv_rd_addr_s1, kv_rd_addr_s2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            kv_rd_addr_s1 <= '0;
            kv_rd_addr_s2 <= '0;
        end else begin
            kv_rd_addr_s1 <= kvif.rd_addr;
            kv_rd_addr_s2 <= kv_rd_addr_s1;

            if (kvif.wr_en) begin
                kv_obs_t e;
                e.is_read = 1'b0;
                e.addr    = kvif.wr_addr;
                e.data    = kvif.wr_data;
                kv_obs_q.push_back(e);
            end
            if (kvif.rd_valid) begin
                kv_obs_t e;
                e.is_read = 1'b1;
                e.addr    = kv_rd_addr_s2;
                e.data    = kvif.rd_data;
                kv_obs_q.push_back(e);
            end
        end
    end
    function automatic logic [MACRO_WORD_W-1:0] mk_instr(
        input macro_opc_e  opc,
        input logic [7:0]  tile_id,
        input logic [7:0]  path_id_f,
        input logic [11:0] flags
    );
        logic [MACRO_WORD_W-1:0] w;
        w        = '0;
        w[63:58] = opc;
        w[57:50] = tile_id;
        w[49:42] = path_id_f;
        w[11:0]  = flags;
        return w;
    endfunction
    task automatic imem_write(
        input logic [IMEM_ADDR_W-1:0]  addr,
        input logic [MACRO_WORD_W-1:0] word
    );
        @(negedge clk);
        imem_we      = 1'b1;
        imem_wr_addr = addr;
        imem_wr_data = word;
        @(negedge clk);
        imem_we      = 1'b0;
    endtask

    task automatic write_desc(
        input logic [7:0]             tile_id,
        input logic                   is_sparse,
        input logic [URAM_AW-1:0]     uram_base,
        input logic [DRAM_ADDR_W-1:0] dram_base,
        input logic [DRAM_LEN_W-1:0]  n_beats
    );
        csd_descriptor_t d;
        d.compressed = 1'b0;
        d.is_sparse  = is_sparse;
        d.uram_base  = uram_base;
        d.dram_base  = dram_base;
        d.n_beats    = n_beats;
        @(negedge clk);
        desc_we      = 1'b1;
        desc_wr_addr = tile_id;
        desc_wr_data = d;
        @(negedge clk);
        desc_we      = 1'b0;
    endtask
    function automatic logic [KV_DATA_W-1:0] rand_kv();
        logic [KV_DATA_W-1:0] v;
        v = {$urandom(), $urandom(), $urandom(), $urandom(), $urandom()};
        v = v[KV_DATA_W-1:0];
        return v;
    endfunction
    int n_errors;
    int n_checks;

    task automatic compare_mem_queues();
        int n_exp = mem_exp_q.size();
        int n_obs = mem_obs_q.size();
        n_checks++;
        if (n_exp != n_obs) begin
            n_errors++;
            $display("[%0t] MEM SEQ LENGTH MISMATCH exp=%0d obs=%0d",
                     $time, n_exp, n_obs);
        end
        for (int i = 0; i < ((n_exp < n_obs) ? n_exp : n_obs); i++) begin
            mem_obs_t e = mem_exp_q[i];
            mem_obs_t o = mem_obs_q[i];
            n_checks++;
            if (e.opc !== o.opc) begin
                n_errors++;
                $display("[%0t] MEM[%0d] opc mismatch exp=%0h obs=%0h",
                         $time, i, e.opc, o.opc);
            end
            if (e.tile_id !== o.tile_id) begin
                n_errors++;
                $display("[%0t] MEM[%0d] tile_id mismatch exp=%0h obs=%0h",
                         $time, i, e.tile_id, o.tile_id);
            end
            if (e.is_sparse !== o.is_sparse) begin
                n_errors++;
                $display("[%0t] MEM[%0d] is_sparse mismatch exp=%0b obs=%0b",
                         $time, i, e.is_sparse, o.is_sparse);
            end
        end
    endtask

    task automatic compare_kv_queues();
        int n_exp = kv_exp_q.size();
        int n_obs = kv_obs_q.size();
        n_checks++;
        if (n_exp != n_obs) begin
            n_errors++;
            $display("[%0t] KV SEQ LENGTH MISMATCH exp=%0d obs=%0d",
                     $time, n_exp, n_obs);
        end
        for (int i = 0; i < ((n_exp < n_obs) ? n_exp : n_obs); i++) begin
            kv_obs_t e = kv_exp_q[i];
            kv_obs_t o = kv_obs_q[i];
            n_checks++;
            if (e.is_read !== o.is_read) begin
                n_errors++;
                $display("[%0t] KV[%0d] direction mismatch exp_read=%0b obs_read=%0b",
                         $time, i, e.is_read, o.is_read);
            end
            if (e.addr !== o.addr) begin
                n_errors++;
                $display("[%0t] KV[%0d] addr mismatch exp=%0h obs=%0h",
                         $time, i, e.addr, o.addr);
            end
            if (e.data !== o.data) begin
                n_errors++;
                $display("[%0t] KV[%0d] data mismatch exp=%0h obs=%0h",
                         $time, i, e.data, o.data);
            end
        end
    endtask
    initial begin : main
        logic [IMEM_ADDR_W-1:0] a;
        int waited;
        logic [KV_DATA_W-1:0]   kv_val_0, kv_val_1, kv_val_2;
        logic [KV_ADDR_W-1:0]   kv_addr_0, kv_addr_1, kv_addr_2;

        n_errors            = 0;
        n_checks            = 0;
        rst_n               = 1'b0;
        start               = 1'b0;
        imem_we             = 1'b0;
        imem_wr_addr        = '0;
        imem_wr_data        = '0;
        desc_we             = 1'b0;
        desc_wr_addr        = '0;
        desc_wr_data        = '0;
        kv_wr_data_sideband = '0;

        for (int i = 0; i < 2**KV_ADDR_W; i++) kv_mirror[i] = '0;

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
        $display("[%0t] STAGE 0: load descriptors", $time);
        write_desc(8'd0,  1'b0, URAM_AW'(12'h010),
                   DRAM_ADDR_W'(32'h1000_0000), DRAM_LEN_W'(N_BEATS_SMALL));
        write_desc(8'd1,  1'b1, URAM_AW'(12'h020),
                   DRAM_ADDR_W'(32'h2000_0000), DRAM_LEN_W'(N_BEATS_SMALL));
        kv_addr_0 = KV_ADDR_W'(14'h0042);
        kv_addr_1 = KV_ADDR_W'(14'h00A5);
        kv_addr_2 = KV_ADDR_W'(14'h1234);

        kv_val_0 = rand_kv();
        kv_val_1 = rand_kv();
        kv_val_2 = rand_kv();
        kv_mirror[kv_addr_0] = kv_val_0;
        kv_mirror[kv_addr_1] = kv_val_1;
        kv_mirror[kv_addr_2] = kv_val_2;

        $display("[%0t] STAGE 1: load imem program", $time);
        a = '0;
        imem_write(a, mk_instr(OP_NOP,        8'h00, 8'h00, 12'h000)); a++;
        imem_write(a, mk_instr(OP_LD_W_URAM,  8'h00, 8'h00, 12'h000)); a++;
        imem_write(a, mk_instr(OP_PINGPONG,   8'h00, 8'h00, 12'h000)); a++;
        imem_write(a, mk_instr(OP_LD_A_URAM,  8'h01, 8'h00,
                               12'h000 | (1 << FLG_IS_SPARSE))); a++;
        imem_write(a, mk_instr(OP_PINGPONG,   8'h01, 8'h00,
                               12'h000 | (1 << FLG_IS_SPARSE))); a++;
        imem_write(a, mk_instr(OP_KV_WRITE,
                               kv_addr_0[7:0],
                               {2'b00, kv_addr_0[13:8]},
                               12'h000)); a++;
        imem_write(a, mk_instr(OP_KV_WRITE,
                               kv_addr_1[7:0],
                               {2'b00, kv_addr_1[13:8]},
                               12'h000)); a++;
        imem_write(a, mk_instr(OP_KV_WRITE,
                               kv_addr_2[7:0],
                               {2'b00, kv_addr_2[13:8]},
                               12'h000)); a++;
        imem_write(a, mk_instr(OP_KV_READ,
                               kv_addr_0[7:0],
                               {2'b00, kv_addr_0[13:8]},
                               12'h000)); a++;
        imem_write(a, mk_instr(OP_KV_READ,
                               kv_addr_2[7:0],
                               {2'b00, kv_addr_2[13:8]},
                               12'h000)); a++;
        imem_write(a, mk_instr(OP_KV_READ,
                               kv_addr_1[7:0],
                               {2'b00, kv_addr_1[13:8]},
                               12'h000)); a++;
        imem_write(a, mk_instr(OP_ST_OUT,     8'h00, 8'h00, 12'h000)); a++;
        imem_write(a, mk_instr(OP_EOP,        8'h00, 8'h00, 12'h000)); a++;
        mem_exp_q.push_back('{opc:OP_LD_W_URAM, tile_id:8'h00, is_sparse:1'b0});
        mem_exp_q.push_back('{opc:OP_PINGPONG,  tile_id:8'h00, is_sparse:1'b0});
        mem_exp_q.push_back('{opc:OP_LD_A_URAM, tile_id:8'h01, is_sparse:1'b1});
        mem_exp_q.push_back('{opc:OP_PINGPONG,  tile_id:8'h01, is_sparse:1'b1});
        mem_exp_q.push_back('{opc:OP_ST_OUT,    tile_id:8'h00, is_sparse:1'b0});
        kv_exp_q.push_back('{is_read:1'b0, addr:kv_addr_0, data:kv_val_0});
        kv_exp_q.push_back('{is_read:1'b0, addr:kv_addr_1, data:kv_val_1});
        kv_exp_q.push_back('{is_read:1'b0, addr:kv_addr_2, data:kv_val_2});
        kv_exp_q.push_back('{is_read:1'b1, addr:kv_addr_0, data:kv_val_0});
        kv_exp_q.push_back('{is_read:1'b1, addr:kv_addr_2, data:kv_val_2});
        kv_exp_q.push_back('{is_read:1'b1, addr:kv_addr_1, data:kv_val_1});
        $display("[%0t] STAGE 3: start dispatcher", $time);
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        waited = 0;
        while (!program_done) begin
            @(posedge clk);
            waited++;
            if (waited > 20_000) begin
                $fatal(1, "tb_dispatcher_mem: program_done never asserted after %0d cycles",
                       waited);
            end
        end
        $display("[%0t] program_done asserted after %0d cycles", $time, waited);
        repeat (8) @(posedge clk);
        $display("[%0t] STAGE 4: compare observed vs expected", $time);
        compare_mem_queues();
        compare_kv_queues();
        if (n_errors == 0 && n_checks > 0) begin
            $display("=========================================================");
            $display(" tb_dispatcher_mem: PASS  (%0d checks, 0 errors)", n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_dispatcher_mem: FAIL  (%0d checks, %0d errors)",
                     n_checks, n_errors);
            $display("=========================================================");
        end
        $finish;
    end
    always_comb begin
        kv_wr_data_sideband = '0;
        if (rst_n) begin
            logic [MACRO_WORD_W-1:0] cur = u_disp.imem[u_disp.pc];
            logic [MACRO_OPC_W-1:0]  cur_opc = cur[63:58];
            logic [KV_ADDR_W-1:0]    cur_addr;
            cur_addr = {cur[47:42], cur[57:50]};
            if (cur_opc == OP_KV_WRITE) begin
                kv_wr_data_sideband = kv_mirror[cur_addr];
            end
        end
    end
    initial begin : watchdog
        #(T_CLK * 50_000);
        $fatal(1, "tb_dispatcher_mem: watchdog timeout");
    end

endmodule : tb_dispatcher_mem

`default_nettype wire
`endif
