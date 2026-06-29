
`ifndef ARCHBETTER_TB_DISPATCHER_NOC_SV
`define ARCHBETTER_TB_DISPATCHER_NOC_SV
`default_nettype none
`timescale 1ns/1ps

module tb_dispatcher_noc
    import types_pkg::*;
();
    localparam time T_CLK      = 10ns;
    localparam int  N_SOURCES  = 1;
    localparam int  IMEM_DEPTH = 64;
    localparam int  IMEM_ADDR_W = $clog2(IMEM_DEPTH);
    localparam int  DATA_W     = NOC_DATA_W;
    localparam int  USER_W     = NOC_USER_W;
    localparam noc_mask_t TGT_MASK = noc_mask_t'(64'h0000_0000_0000_000F);
    localparam logic [31:0] TGT_MASK_LO = TGT_MASK[31:0];
    localparam logic [31:0] TGT_MASK_HI = TGT_MASK[63:32];

    localparam logic [5:0] TGT_SRC_NODE    = 6'd0;
    localparam logic [2:0] TGT_PRIORITY    = 3'd0;
    localparam logic       TGT_IS_MULTICAST = 1'b1;

    localparam logic [NOC_PATH_ID_W-1:0] TGT_HANDLE = '0;
    logic clk, rst_n;
    initial clk = 1'b0;
    always  #(T_CLK/2) clk = ~clk;
    noc_cfg_if cfg_bus [N_SOURCES] (.clk(clk), .rst_n(rst_n));

    strm_if #(.DATA_W(DATA_W), .USER_W(USER_W))
        src [N_SOURCES] (.clk(clk), .rst_n(rst_n));
    strm_if #(.DATA_W(DATA_W), .USER_W(USER_W))
        dst [NOC_NODES]  (.clk(clk), .rst_n(rst_n));
    gemm_issue_if gemm_bus (.clk(clk), .rst_n(rst_n));
    tlmm_issue_if tlmm_bus (.clk(clk), .rst_n(rst_n));

    assign gemm_bus.beat_fire = 1'b0;
    assign tlmm_bus.done      = 1'b0;
    logic [NOC_PATH_ID_W-1:0] path_id [N_SOURCES];
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
    int n_errors;
    int n_checks;
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

        s0_data  = '0;
        s0_user  = '0;
        s0_valid = 1'b0;
        s0_last  = 1'b0;
        d_ready  = {NOC_NODES{1'b1}};

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
        $display("[%0t] P1: loading program into imem", $time);

        a = '0;
        imem_write(a, mk_instr(OP_NOP, 8'h00, 8'h00, 32'h0000_0000)); a++;
        imem_write(a, mk_instr(OP_CFG_NOC,
                               {6'd0, CFG_NOC_MASK_LO},
                               {3'd0, TGT_HANDLE},
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
        $display("[%0t] P2: start dispatcher", $time);
        n_checks++;
        if (u_fabric.gen_src[0].u_router.committed) begin
            n_errors++;
            $error("committed was already asserted before start");
        end

        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
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
        $display("[%0t] P5: streaming one beat through committed path", $time);

        beat = '0;
        for (int k = 0; k < DATA_W; k += 16) beat[k +: 16] = 16'hBEEF;
        stream_one_beat(beat, 1'b1, TGT_MASK);
        repeat (4) @(posedge clk);
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
`endif
