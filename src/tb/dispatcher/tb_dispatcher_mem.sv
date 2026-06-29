// -----------------------------------------------------------------------------
// tb_dispatcher_mem.sv
//
// Layer-3 integration testbench: dispatcher + memory_manager.
//
// Scope:
//   Verifies the dispatcher's Layer-3 additions in isolation from the compute
//   cores. Exercises every new opcode the dispatcher learned in Layer 3:
//     * OP_LD_W_URAM  (mem_issue handshake, dense pool)
//     * OP_LD_A_URAM  (mem_issue handshake, sparse pool)
//     * OP_PINGPONG   (mem_issue handshake, compute-side drain handshake)
//     * OP_ST_OUT     (mem_issue handshake, stub)
//     * OP_KV_WRITE   (kv_access_if direct drive)
//     * OP_KV_READ    (kv_access_if direct drive, rd_valid 2 cycles later)
//
// This TB is intentionally NOT re-verifying the memory subsystem internals -
// tb_memory_manager already proves that end-to-end. The scoring here focuses
// on the dispatcher's own behavior:
//     1. For each memory opcode in the program, mem_issue carries the
//        correct opcode, tile_id, is_sparse, and the handshake closes.
//     2. For each KV opcode, kv_access_if carries the correct address /
//        data / direction, and the write/read round-trip returns the
//        original data.
//     3. program_done asserts after OP_EOP with no hangs.
//
// Stubs for unused dispatcher ports:
//     * noc_cfg : cfg_ready tied high; monitor but never exercised.
//     * gemm    : compute ports driven idle (no OP_GEMM_ALL in program).
//     * tlmm    : tlmm.done tied low; no OP_FFN_TLMM in program.
//
// Stubs for memory_manager ports:
//     * DRAM   : reuse tb_memory_manager's deterministic beat model
//                (payload = {DRAM_PATTERN_HI, addr + 8*i}).
//     * pingpong drain_ack : auto-ack one cycle after drain_req.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_TB_DISPATCHER_MEM_SV
`define ARCHBETTER_TB_DISPATCHER_MEM_SV
`default_nettype none
`timescale 1ns/1ps

module tb_dispatcher_mem
    import types_pkg::*;
();

    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------
    localparam time T_CLK       = 10ns;
    localparam int  IMEM_DEPTH  = 64;
    localparam int  IMEM_ADDR_W = $clog2(IMEM_DEPTH);
    localparam int  N_SOURCES   = 1;
    localparam int  URAM_DATA_W = URAM_WIDTH_BITS;  // 72
    localparam int  URAM_AW     = URAM_ADDR_W;      // 12
    localparam logic [39:0] DRAM_PATTERN_HI = 40'hCA_FEBA_BECA;

    localparam int  N_BEATS_SMALL = 8;   // keep per-fill small to speed sim

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    initial clk = 1'b0;
    always #(T_CLK/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Interfaces
    // -------------------------------------------------------------------------
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

    // Phase-8 DRAM write master (csd_drain_engine inside memory_manager). This
    // TB does not model a DRAM write target, so accept every beat immediately
    // (ready tied high). OP_ST_OUT is exercised structurally; the write stream
    // drains to nowhere, which is fine for the dispatcher/mem-op coverage here.
    csd_dram_wr_if dram_wr_if (.clk(clk), .rst_n(rst_n));
    assign dram_wr_if.req_ready = 1'b1;
    assign dram_wr_if.wd_ready  = 1'b1;

    // Phase-8 OUT-URAM write port (driven by memory_manager's drain path).
    // Observed-only here; no scoreboard on it in this TB.
    logic                       out_wr_en;
    logic [URAM_ADDR_W-1:0]     out_wr_addr;
    logic [URAM_WIDTH_BITS-1:0] out_wr_data;

    // Descriptor table write port (memory_manager).
    logic              desc_we;
    logic [7:0]        desc_wr_addr;
    csd_descriptor_t   desc_wr_data;

    // Phase-8 dense_sched_if. This TB issues memory ops only (no OP_GEMM_LAYER),
    // so the dispatcher's tile-walker stays idle. Tie off the streamer side.
    dense_sched_if sched_bus (.clk(clk), .rst_n(rst_n));
    assign sched_bus.load_done = 1'b0;
    assign sched_bus.w_we      = 1'b0;
    assign sched_bus.w_phys_gc = '0;
    assign sched_bus.w_pe_addr = '0;
    assign sched_bus.w_in      = '0;

    // -------------------------------------------------------------------------
    // Dispatcher sidebands
    // -------------------------------------------------------------------------
    logic                     start;
    logic                     program_done;
    logic                     imem_we;
    logic [IMEM_ADDR_W-1:0]   imem_wr_addr;
    logic [MACRO_WORD_W-1:0]  imem_wr_data;
    logic [NOC_PATH_ID_W-1:0] path_id [N_SOURCES];
    logic [KV_DATA_W-1:0]     kv_wr_data_sideband;

    // -------------------------------------------------------------------------
    // DUTs
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // noc_cfg stub: always ready. Program has no CFG_NOC, but the master-side
    // defaults need a ready to avoid assertion noise.
    // -------------------------------------------------------------------------
    assign cfg_bus.cfg_ready = 1'b1;

    // -------------------------------------------------------------------------
    // gemm / tlmm idle stubs. Program issues neither OP_GEMM_ALL nor
    // OP_FFN_TLMM, so these are just tied into a quiescent state.
    // -------------------------------------------------------------------------
    assign gemm_bus.beat_fire = 1'b0;
    assign tlmm_bus.done      = 1'b0;

    // -------------------------------------------------------------------------
    // DRAM stub (copied from tb_memory_manager pattern).
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Pingpong auto-ack (both pools).
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dense_pp.drain_ack  <= 1'b0;
            sparse_pp.drain_ack <= 1'b0;
        end else begin
            dense_pp.drain_ack  <= dense_pp.drain_req  && !dense_pp.drain_ack;
            sparse_pp.drain_ack <= sparse_pp.drain_req && !sparse_pp.drain_ack;
        end
    end

    // Compute-side reads: not exercised here. Tie rd_en low.
    assign dense_pp.rd_en   = 1'b0;
    assign dense_pp.rd_addr = '0;
    assign sparse_pp.rd_en  = 1'b0;
    assign sparse_pp.rd_addr = '0;

    // -------------------------------------------------------------------------
    // Expected mem_issue sequence (populated by main before start).
    //   Each entry = { opc, tile_id, is_sparse } as appeared on memif.
    //   A monitor captures every start pulse into the observed queue; at the
    //   end of the program we diff observed vs expected.
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Expected KV sequence and mirror.
    //   For WRITE : push {is_read=0, addr, data}.
    //   For READ  : push {is_read=1, addr, data=mirror[addr]}.
    //   A monitor captures every wr_en and rd_en pulse into mirror[wr_addr] or
    //   kv_reads_obs. rd_data is sampled when rd_valid fires (2 cycles later).
    // -------------------------------------------------------------------------
    logic [KV_DATA_W-1:0] kv_mirror [2**KV_ADDR_W];

    typedef struct packed {
        logic                 is_read;
        logic [KV_ADDR_W-1:0] addr;
        logic [KV_DATA_W-1:0] data;
    } kv_obs_t;

    kv_obs_t kv_exp_q [$];
    kv_obs_t kv_obs_q [$];

    // Capture writes at wr_en edge; capture reads at rd_valid edge. The KV BRAM
    // now has a 2-cycle read latency (output latch + OREG), so the rd_addr that
    // issued the read whose data arrives on the current rd_valid is the addr
    // from TWO cycles ago. A 2-stage shift shadow tracks it; because it shifts
    // every cycle (not gated on rd_en) it stays correct for back-to-back reads
    // as well — non-rd_en cycles never produce an rd_valid, so the shadow is
    // only ever sampled at an aligned slot.
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

    // -------------------------------------------------------------------------
    // Instruction builder
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Descriptor and imem write tasks
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Random 144b helper (paired 64b + 80b concats to stay portable)
    // -------------------------------------------------------------------------
    function automatic logic [KV_DATA_W-1:0] rand_kv();
        logic [KV_DATA_W-1:0] v;
        v = {$urandom(), $urandom(), $urandom(), $urandom(), $urandom()};
        v = v[KV_DATA_W-1:0];
        return v;
    endfunction

    // -------------------------------------------------------------------------
    // Scoreboard
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
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

        // ---------------------------------------------------------------------
        // STAGE 0: Load descriptors for tile_id 0 (dense) and 1 (sparse).
        // ---------------------------------------------------------------------
        $display("[%0t] STAGE 0: load descriptors", $time);
        write_desc(8'd0, /*is_sparse=*/ 1'b0, URAM_AW'(12'h010),
                   DRAM_ADDR_W'(32'h1000_0000), DRAM_LEN_W'(N_BEATS_SMALL));
        write_desc(8'd1, /*is_sparse=*/ 1'b1, URAM_AW'(12'h020),
                   DRAM_ADDR_W'(32'h2000_0000), DRAM_LEN_W'(N_BEATS_SMALL));

        // ---------------------------------------------------------------------
        // STAGE 1: Build program.
        //   Program exercises every Layer-3 opcode in order:
        //     pc 0 : OP_NOP
        //     pc 1 : OP_LD_W_URAM  tile_id=0, is_sparse flag=0
        //     pc 2 : OP_PINGPONG   tile_id=0, is_sparse flag=0 (dense pool)
        //     pc 3 : OP_LD_A_URAM  tile_id=1, is_sparse flag=1
        //     pc 4 : OP_PINGPONG   tile_id=1, is_sparse flag=1 (sparse pool)
        //     pc 5 : OP_KV_WRITE   addr=kv_addr_0, data=kv_val_0
        //     pc 6 : OP_KV_WRITE   addr=kv_addr_1, data=kv_val_1
        //     pc 7 : OP_KV_WRITE   addr=kv_addr_2, data=kv_val_2
        //     pc 8 : OP_KV_READ    addr=kv_addr_0
        //     pc 9 : OP_KV_READ    addr=kv_addr_2
        //     pc10 : OP_KV_READ    addr=kv_addr_1
        //     pc11 : OP_ST_OUT     tile_id=0, is_sparse=0 (stub)
        //     pc12 : OP_EOP
        // ---------------------------------------------------------------------
        kv_addr_0 = KV_ADDR_W'(14'h0042);
        kv_addr_1 = KV_ADDR_W'(14'h00A5);
        kv_addr_2 = KV_ADDR_W'(14'h1234);

        kv_val_0 = rand_kv();
        kv_val_1 = rand_kv();
        kv_val_2 = rand_kv();

        // Seed mirror for the values we intend to write.
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
        // KV ops: packed addr = { path_id[5:0], tile_id[7:0] }.
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

        // Build expected mem_issue sequence (5 handshakes, LD + swap dense,
        // LD + swap sparse, ST_OUT).
        mem_exp_q.push_back('{opc:OP_LD_W_URAM, tile_id:8'h00, is_sparse:1'b0});
        mem_exp_q.push_back('{opc:OP_PINGPONG,  tile_id:8'h00, is_sparse:1'b0});
        mem_exp_q.push_back('{opc:OP_LD_A_URAM, tile_id:8'h01, is_sparse:1'b1});
        mem_exp_q.push_back('{opc:OP_PINGPONG,  tile_id:8'h01, is_sparse:1'b1});
        mem_exp_q.push_back('{opc:OP_ST_OUT,    tile_id:8'h00, is_sparse:1'b0});

        // Build expected KV sequence.
        kv_exp_q.push_back('{is_read:1'b0, addr:kv_addr_0, data:kv_val_0});
        kv_exp_q.push_back('{is_read:1'b0, addr:kv_addr_1, data:kv_val_1});
        kv_exp_q.push_back('{is_read:1'b0, addr:kv_addr_2, data:kv_val_2});
        kv_exp_q.push_back('{is_read:1'b1, addr:kv_addr_0, data:kv_val_0});
        kv_exp_q.push_back('{is_read:1'b1, addr:kv_addr_2, data:kv_val_2});
        kv_exp_q.push_back('{is_read:1'b1, addr:kv_addr_1, data:kv_val_1});

        // ---------------------------------------------------------------------
        // STAGE 2: KV write-data sideband driver.
        //   The dispatcher samples kv_wr_data_i on the cycle it asserts wr_en.
        //   We drive the correct value from one cycle ahead of each KV_WRITE
        //   by tracking the upcoming opcode in the program counter visible in
        //   the dispatcher. Simplest scheme: at every rising edge where the
        //   NEXT opcode to decode is OP_KV_WRITE, drive the matching value.
        //   We use a lightweight lookup that matches the imem layout above.
        // ---------------------------------------------------------------------
        // A concurrent process drives the sideband; main continues to start.
        // (See kv_sideband_driver initial block below.)

        // ---------------------------------------------------------------------
        // STAGE 3: Start dispatcher and wait for program_done.
        // ---------------------------------------------------------------------
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

        // Let residual rd_valid / done pulses settle into the observed queues.
        repeat (8) @(posedge clk);

        // ---------------------------------------------------------------------
        // STAGE 4: compare.
        // ---------------------------------------------------------------------
        $display("[%0t] STAGE 4: compare observed vs expected", $time);
        compare_mem_queues();
        compare_kv_queues();

        // ---------------------------------------------------------------------
        // Finish
        // ---------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // KV sideband driver: watches dispatcher.pc -> current imem word; when the
    // next-to-decode opcode is OP_KV_WRITE, drive kv_wr_data_sideband with the
    // payload for that address. The dispatcher samples kv_wr_data_i on the
    // S_EXEC cycle when it fires kv_wr_en, so driving "while this opcode is
    // current" is the right window.
    // -------------------------------------------------------------------------
    always_comb begin
        kv_wr_data_sideband = '0;
        if (rst_n) begin
            // Decode current imem word via hierarchical peek.
            logic [MACRO_WORD_W-1:0] cur = u_disp.imem[u_disp.pc];
            logic [MACRO_OPC_W-1:0]  cur_opc = cur[63:58];
            logic [KV_ADDR_W-1:0]    cur_addr;
            cur_addr = {cur[47:42], cur[57:50]};
            if (cur_opc == OP_KV_WRITE) begin
                kv_wr_data_sideband = kv_mirror[cur_addr];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Watchdog
    // -------------------------------------------------------------------------
    initial begin : watchdog
        #(T_CLK * 50_000);
        $fatal(1, "tb_dispatcher_mem: watchdog timeout");
    end

endmodule : tb_dispatcher_mem

`default_nettype wire
`endif // ARCHBETTER_TB_DISPATCHER_MEM_SV
