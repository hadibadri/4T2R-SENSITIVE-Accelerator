// -----------------------------------------------------------------------------
// tb_dispatcher_noc.sv
//
// Layer 1 integration testbench: dispatcher + noc_fabric.
//
// Topology under test:
//   * One dispatcher with its own 64-entry LUTRAM instruction memory.
//   * noc_fabric with N_SOURCES = 1, NOC_NODES destinations. The dispatcher's
//     noc_cfg master is wired directly to the fabric's single cfg slave.
//   * The TB drives the fabric's streaming src[0] directly (the dispatcher
//     does not yet issue compute ops, that is Layer 2).
//
// What this testbench checks:
//   P1. imem load : TB writes a small program into dispatcher imem via the
//                   imem_we / imem_wr_addr / imem_wr_data sideband.
//   P2. execute   : start pulse -> the dispatcher walks the program:
//                     0 : OP_NOP
//                     1 : OP_CFG_NOC MASK_LO handle=0, payload = mask[31:0]
//                     2 : OP_CFG_NOC MASK_HI handle=0, payload = mask[63:32]
//                     3 : OP_CFG_NOC META    handle=0, src_node=0, is_mc=1
//                     4 : OP_BARRIER
//                     5 : OP_COMMIT_NOC
//                     6 : OP_EOP
//                   program_done must assert after the EOP.
//   P3. committed : peek at the router's `committed` flag (hierarchical ref
//                   into the fabric) and confirm it went 0 -> 1 during P2.
//   P4. path_tab  : confirm the router's path_tab[0] holds the mask the
//                   program wrote. This is the real end-to-end correctness
//                   check of the CFG_NOC chunk staging logic.
//   P5. route     : with the NoC now committed, push one beat through src[0]
//                   and sample every destination. Only the masked destinations
//                   must see the beat.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_TB_DISPATCHER_NOC_SV
`define ARCHBETTER_TB_DISPATCHER_NOC_SV
`default_nettype none
`timescale 1ns/1ps

module tb_dispatcher_noc
    import types_pkg::*;
();

    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------
    localparam time T_CLK      = 10ns;
    localparam int  N_SOURCES  = 1;
    localparam int  IMEM_DEPTH = 64;
    localparam int  IMEM_ADDR_W = $clog2(IMEM_DEPTH);
    localparam int  DATA_W     = NOC_DATA_W;
    localparam int  USER_W     = NOC_USER_W;

    // Target mask: destinations {0,1,2,3}. Fits entirely in mask_lo.
    localparam noc_mask_t TGT_MASK = noc_mask_t'(64'h0000_0000_0000_000F);
    localparam logic [31:0] TGT_MASK_LO = TGT_MASK[31:0];
    localparam logic [31:0] TGT_MASK_HI = TGT_MASK[63:32];

    localparam logic [5:0] TGT_SRC_NODE    = 6'd0;
    localparam logic [2:0] TGT_PRIORITY    = 3'd0;
    localparam logic       TGT_IS_MULTICAST = 1'b1;

    localparam logic [NOC_PATH_ID_W-1:0] TGT_HANDLE = '0;

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    logic clk, rst_n;
    initial clk = 1'b0;
    always  #(T_CLK/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Interfaces
    // -------------------------------------------------------------------------
    // One cfg interface (shared master=dispatcher, slave=noc_fabric's router).
    // noc_fabric expects an interface array; we allocate size 1.
    noc_cfg_if cfg_bus [N_SOURCES] (.clk(clk), .rst_n(rst_n));

    strm_if #(.DATA_W(DATA_W), .USER_W(USER_W))
        src [N_SOURCES] (.clk(clk), .rst_n(rst_n));
    strm_if #(.DATA_W(DATA_W), .USER_W(USER_W))
        dst [NOC_NODES]  (.clk(clk), .rst_n(rst_n));

    // Layer 2 dispatcher exposes new issue sidebands. This Layer-1 program
    // exercises none of the compute opcodes, so we instantiate them as stubs
    // and tie their driver-side response signals inert (beat_fire=0, done=0).
    gemm_issue_if gemm_bus (.clk(clk), .rst_n(rst_n));
    tlmm_issue_if tlmm_bus (.clk(clk), .rst_n(rst_n));

    assign gemm_bus.beat_fire = 1'b0;
    assign tlmm_bus.done      = 1'b0;

    // path_id is now DRIVEN by the dispatcher (was TB-driven in the Layer-1
    // skeleton). We still wire it into the fabric the same way.
    logic [NOC_PATH_ID_W-1:0] path_id [N_SOURCES];

    // -------------------------------------------------------------------------
    // DUTs
    // -------------------------------------------------------------------------
    // Dispatcher control / imem load
    logic                         start;
    logic                         program_done;
    logic                         imem_we;
    logic [IMEM_ADDR_W-1:0]       imem_wr_addr;
    logic [MACRO_WORD_W-1:0]      imem_wr_data;

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
        .noc_cfg      (cfg_bus[0]),
        .gemm         (gemm_bus.disp),
        .tlmm         (tlmm_bus.disp),
        .dense_drain_busy (1'b0)
    );

    noc_fabric #(
        .N_SOURCES (N_SOURCES),
        .DATA_W    (DATA_W),
        .USER_W    (USER_W)
    ) u_fabric (
        .clk     (clk),
        .rst_n   (rst_n),
        .path_id (path_id),
        .cfg     (cfg_bus),
        .src     (src),
        .dst     (dst)
    );

    // -------------------------------------------------------------------------
    // Src / dst packed mirrors (interface-array elements are only constant-
    // indexable in procedural code).
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] s0_data;
    logic [USER_W-1:0] s0_user;
    logic              s0_valid;
    logic              s0_last;
    logic              s0_ready_obs;

    assign src[0].data  = s0_data;
    assign src[0].user  = s0_user;
    assign src[0].valid = s0_valid;
    assign src[0].last  = s0_last;
    assign s0_ready_obs = src[0].ready;

    logic [NOC_NODES-1:0][DATA_W-1:0] d_data;
    logic [NOC_NODES-1:0][USER_W-1:0] d_user;
    logic [NOC_NODES-1:0]             d_valid;
    logic [NOC_NODES-1:0]             d_last;
    logic [NOC_NODES-1:0]             d_ready;

    for (genvar D = 0; D < NOC_NODES; D++) begin : gen_dst_bind
        assign d_data [D]   = dst[D].data;
        assign d_user [D]   = dst[D].user;
        assign d_valid[D]   = dst[D].valid;
        assign d_last [D]   = dst[D].last;
        assign dst[D].ready = d_ready[D];
    end

    // -------------------------------------------------------------------------
    // Scoreboard
    // -------------------------------------------------------------------------
    int n_errors;
    int n_checks;

    // -------------------------------------------------------------------------
    // Instruction-word builder. The dispatcher reads macro_instr_t as a packed
    // struct; the low 32 bits of the word coincide with
    //   { col_cnt[9:0], k_cnt[9:0], flags[11:0] }
    // and CFG_NOC chunks repurpose those bits as the 32-bit chunk payload.
    // -------------------------------------------------------------------------
    function automatic logic [MACRO_WORD_W-1:0] mk_instr(
        input macro_opc_e      opc,
        input logic [7:0]      tile_id,
        input logic [7:0]      path_id_field,
        input logic [31:0]     low32
    );
        logic [MACRO_WORD_W-1:0] w;
        w            = '0;
        w[63:58]     = opc;
        w[57:50]     = tile_id;
        w[49:42]     = path_id_field;
        // w[41:32] = row_cnt; leave 0.
        w[31:0]      = low32;
        return w;
    endfunction

    function automatic logic [31:0] mk_meta_payload(
        input logic [5:0] src_node,
        input logic [2:0] priority_lvl,
        input logic       is_multicast
    );
        logic [31:0] p;
        p       = '0;
        p[9:4]  = src_node;
        p[3:1]  = priority_lvl;
        p[0]    = is_multicast;
        return p;
    endfunction

    // -------------------------------------------------------------------------
    // TB-side imem write. Drives imem_we/addr/data for one cycle.
    // -------------------------------------------------------------------------
    task automatic imem_write(
        input logic [IMEM_ADDR_W-1:0]  addr,
        input logic [MACRO_WORD_W-1:0] word
    );
        @(posedge clk);
        imem_we       = 1'b1;
        imem_wr_addr  = addr;
        imem_wr_data  = word;
        @(posedge clk);
        imem_we       = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Drive one streaming beat on src[0] with an explicit exp_mask (for
    // post-fire checks). Uses blocking writes so deassert lands in the same
    // time step as the sample.
    // -------------------------------------------------------------------------
    task automatic stream_one_beat(
        input logic [DATA_W-1:0] payload,
        input logic              last,
        input noc_mask_t         exp_mask
    );
        int waited;
        waited = 0;

        s0_data  = payload;
        s0_user  = 8'hA5;
        s0_valid = 1'b1;
        s0_last  = last;

        do begin
            @(posedge clk);
            waited++;
            if (waited > 64)
                $fatal(1, "stream_one_beat: src[0] stalled > 64 cycles");
        end while (!s0_ready_obs);

        // Fire. Sample every destination.
        for (int d = 0; d < NOC_NODES; d++) begin
            if (exp_mask[d]) begin
                n_checks++;
                if (!d_valid[d]) begin
                    n_errors++;
                    $error("dst[%0d] expected valid=1 on fire, got 0", d);
                end else if (d_data[d] !== payload) begin
                    n_errors++;
                    $error("dst[%0d] payload mismatch: exp=%h act=%h",
                           d, payload, d_data[d]);
                end
            end else begin
                // Non-masked destinations must stay quiet.
                n_checks++;
                if (d_valid[d]) begin
                    n_errors++;
                    $error("dst[%0d] unexpected valid=1 (not in mask)", d);
                end
            end
        end

        s0_valid = 1'b0;
        s0_last  = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin : main
        logic [IMEM_ADDR_W-1:0] a;
        int waited;
        logic [63:0]             committed_history;
        logic                    committed_now;
        noc_mask_t               observed_mask;
        logic [DATA_W-1:0]       beat;

        n_errors      = 0;
        n_checks      = 0;
        rst_n         = 1'b0;
        start         = 1'b0;
        imem_we       = 1'b0;
        imem_wr_addr  = '0;
        imem_wr_data  = '0;
        // path_id[] is driven by the dispatcher (Layer 2).

        s0_data  = '0;
        s0_user  = '0;
        s0_valid = 1'b0;
        s0_last  = 1'b0;
        d_ready  = {NOC_NODES{1'b1}};

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // ---------------------------------------------------------------------
        // P1 : write the program into imem.
        //   0: OP_NOP
        //   1: OP_CFG_NOC MASK_LO  handle=0   payload=TGT_MASK_LO
        //   2: OP_CFG_NOC MASK_HI  handle=0   payload=TGT_MASK_HI
        //   3: OP_CFG_NOC META     handle=0   payload={src_node,prio,is_mc}
        //   4: OP_BARRIER
        //   5: OP_COMMIT_NOC
        //   6: OP_EOP
        // ---------------------------------------------------------------------
        $display("[%0t] P1: loading program into imem", $time);

        a = '0;
        imem_write(a, mk_instr(OP_NOP, 8'h00, 8'h00, 32'h0000_0000)); a++;
        imem_write(a, mk_instr(OP_CFG_NOC,
                               {6'd0, CFG_NOC_MASK_LO},       // chunk sel in tile_id[1:0]
                               {3'd0, TGT_HANDLE},            // handle in path_id[NOC_PATH_ID_W-1:0]
                               TGT_MASK_LO));                 a++;
        imem_write(a, mk_instr(OP_CFG_NOC,
                               {6'd0, CFG_NOC_MASK_HI},
                               {3'd0, TGT_HANDLE},
                               TGT_MASK_HI));                 a++;
        imem_write(a, mk_instr(OP_CFG_NOC,
                               {6'd0, CFG_NOC_META},
                               {3'd0, TGT_HANDLE},
                               mk_meta_payload(TGT_SRC_NODE,
                                               TGT_PRIORITY,
                                               TGT_IS_MULTICAST))); a++;
        imem_write(a, mk_instr(OP_BARRIER,    8'h00, 8'h00, 32'h0)); a++;
        imem_write(a, mk_instr(OP_COMMIT_NOC, 8'h00, 8'h00, 32'h0)); a++;
        imem_write(a, mk_instr(OP_EOP,        8'h00, 8'h00, 32'h0)); a++;

        // ---------------------------------------------------------------------
        // P2 : execute the program.
        // ---------------------------------------------------------------------
        $display("[%0t] P2: start dispatcher", $time);

        // Confirm committed is still 0 before we start.
        n_checks++;
        if (u_fabric.gen_src[0].u_router.committed) begin
            n_errors++;
            $error("committed was already asserted before start");
        end

        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // Track committed history across the run so we can distinguish
        // "committed rose" vs "committed never fell" post-hoc.
        committed_history = '0;
        waited            = 0;
        while (!program_done) begin
            @(posedge clk);
            committed_history = (committed_history << 1)
                              | {63'b0, u_fabric.gen_src[0].u_router.committed};
            waited++;
            if (waited > 1024)
                $fatal(1, "P2: program_done never asserted (waited %0d cycles)", waited);
        end
        $display("[%0t] P2: program_done asserted after %0d cycles", $time, waited);

        // ---------------------------------------------------------------------
        // P3 : committed must have risen during the run.
        // ---------------------------------------------------------------------
        committed_now = u_fabric.gen_src[0].u_router.committed;
        n_checks++;
        if (!committed_now) begin
            n_errors++;
            $error("P3: committed not asserted at end of program (history=0x%0h)",
                   committed_history);
        end else begin
            $display("[%0t] P3: committed=1 (rose during run, history=0x%0h)",
                     $time, committed_history);
        end

        // ---------------------------------------------------------------------
        // P4 : the committed path_tab entry must match what the program wrote.
        // ---------------------------------------------------------------------
        observed_mask = u_fabric.gen_src[0].u_router.path_tab[0].dst_mask;
        n_checks++;
        if (observed_mask !== TGT_MASK) begin
            n_errors++;
            $error("P4: path_tab[0].dst_mask mismatch: exp=%h act=%h",
                   TGT_MASK, observed_mask);
        end else begin
            $display("[%0t] P4: path_tab[0].dst_mask = 0x%h (OK)", $time, observed_mask);
        end

        n_checks++;
        if (u_fabric.gen_src[0].u_router.path_tab[0].src_node
                !== TGT_SRC_NODE) begin
            n_errors++;
            $error("P4: path_tab[0].src_node mismatch: exp=%0d act=%0d",
                   TGT_SRC_NODE,
                   u_fabric.gen_src[0].u_router.path_tab[0].src_node);
        end

        n_checks++;
        if (u_fabric.gen_src[0].u_router.path_tab[0].is_multicast
                !== TGT_IS_MULTICAST) begin
            n_errors++;
            $error("P4: path_tab[0].is_multicast mismatch: exp=%0b act=%0b",
                   TGT_IS_MULTICAST,
                   u_fabric.gen_src[0].u_router.path_tab[0].is_multicast);
        end

        // ---------------------------------------------------------------------
        // P5 : push one beat through the committed NoC and verify routing.
        //       path_id[0] already points at handle 0, which is what we wrote.
        // ---------------------------------------------------------------------
        $display("[%0t] P5: streaming one beat through committed path", $time);

        beat = '0;
        for (int k = 0; k < DATA_W; k += 16) beat[k +: 16] = 16'hBEEF;
        stream_one_beat(beat, 1'b1, TGT_MASK);

        // Flush
        repeat (4) @(posedge clk);

        // ---------------------------------------------------------------------
        // Finish
        // ---------------------------------------------------------------------
        if (n_errors == 0 && n_checks > 0) begin
            $display("=========================================================");
            $display(" tb_dispatcher_noc: PASS  (%0d checks, 0 errors)", n_checks);
            $display("=========================================================");
        end else begin
            $display("=========================================================");
            $display(" tb_dispatcher_noc: FAIL  (%0d checks, %0d errors)",
                     n_checks, n_errors);
            $display("=========================================================");
        end
        $finish;
    end

    initial begin : watchdog
        #(T_CLK * 500_000);
        $fatal(1, "tb_dispatcher_noc: watchdog timeout");
    end

endmodule : tb_dispatcher_noc

`default_nettype wire
`endif // ARCHBETTER_TB_DISPATCHER_NOC_SV
