// -----------------------------------------------------------------------------
// memory_manager.sv
//
// Top of the memory subsystem. Wraps:
//   * 2 x uram_pingpong                  (dense pool, sparse pool)
//   * 1 x csd_engine                     (single DRAM consumer; writes are
//                                         demuxed to either pool by the
//                                         engine's fill_is_sparse_o output)
//   * 1 x kv_bram                        (KV cache, addressable by dispatcher
//                                         directly via kv_access_if)
//   * 1 x distributed-RAM descriptor table indexed by tile_id [0..255]
//   * a small command FSM that decodes mem_issue_if and routes to the right
//     submodule (CSD fill / pingpong swap / nop)
//
// Opcodes accepted on mem_issue_if (per the modport contract in interfaces.sv):
//   OP_LD_W_URAM, OP_LD_A_URAM
//       Look up desc_table[tile_id] (loaded out-of-band at startup), hand it
//       to csd_engine, wait for done. Both opcodes share the same code path
//       in Phase 2 - the descriptor's is_sparse field selects the pool.
//   OP_PINGPONG
//       Pulse swap_req on the pool selected by issue.is_sparse, wait for
//       swap_done from the pingpong.
//   OP_ST_OUT
//       Look up desc_table[tile_id] (loaded out-of-band like the LD_*
//       descriptors) and hand it to csd_drain_engine, which streams the
//       output-URAM region described by (uram_base, n_beats) to off-chip
//       DRAM at dram_base via the new csd_dram_wr_if master. Wait for the
//       engine's done pulse before pulsing memif.done. Phase 5 contract:
//       descriptor's compressed must be 0 (engine asserts this in sim).
//   anything else
//       1-cycle ack with $warning. KV ops (OP_KV_*) come in over kv_access_if
//       directly, NOT mem_issue_if, so seeing them here is a bug.
//
// Descriptor table:
//   256 entries x csd_descriptor_t (62b). Distributed-RAM by attribute. Loaded
//   through a dedicated write port (desc_we / desc_wr_addr / desc_wr_data) by
//   the host or the testbench BEFORE asserting issue.start. The table read is
//   combinational (one-cycle path tile_id -> csd_engine.desc_i).
//
// busy semantics:
//   mem_issue_if puts `busy` on the DISPATCHER side (modport disp outputs
//   busy). The dispatcher is responsible for tracking its own busy state for
//   the duration of an op; the memory_manager only drives `done`. We pulse
//   done for one cycle on the FSM transition out of the work state, which is
//   the cycle the dispatcher uses to drop busy and advance pc.
//
// Resource class:
//   * 4 x URAM288 via the 2 ping-pong wrappers (dense + sparse, 2 banks each)
//   * 1 x URAM288 for the OUTPUT region (Phase 5: written by the dense out
//     collector, drained by csd_drain_engine on OP_ST_OUT)
//   * ~64 BRAM36 via kv_bram
//   * ~16 LUT6 of distributed RAM for the descriptor table
//   * a handful of fabric flops for the command FSM
// -----------------------------------------------------------------------------
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

    // Dispatcher control plane.
    mem_issue_if.mgr   issue,

    // KV cache. memory_manager wraps kv_bram and exposes the slave-side port;
    // the dispatcher connects with .master at the SoC top.
    kv_access_if.slave kv,

    // Compute-core ping-pong ports.
    pingpong_if.mem_mgr dense_pp,
    pingpong_if.mem_mgr sparse_pp,

    // Off-chip DRAM masters.
    //   dram    : read side, driven by csd_engine for OP_LD_*_URAM fills.
    //   dram_wr : write side, driven by csd_drain_engine for OP_ST_OUT drains.
    csd_dram_if.mgr    dram,
    csd_dram_wr_if.mgr dram_wr,

    // OUTPUT URAM write port (driven by dense_out_collector in the SoC top;
    // the Phase-5 unit TB drives it directly). Reads are owned internally by
    // csd_drain_engine.
    input  wire logic                       out_wr_en,
    input  wire logic [URAM_ADDR_W-1:0]     out_wr_addr,
    input  wire logic [URAM_WIDTH_BITS-1:0] out_wr_data,

    // Descriptor table write port (host / TB load). desc_we is gated to IDLE
    // by a sim assertion below (writing while a fill is in flight would race
    // with the table read used by csd_engine).
    input  wire logic               desc_we,
    input  wire logic [7:0]         desc_wr_addr,
    input  wire csd_descriptor_t    desc_wr_data
);

    // -------------------------------------------------------------------------
    // Elaboration consistency.
    // -------------------------------------------------------------------------
    initial begin : elab_checks
        if (DESC_DEPTH != 256) begin
            $fatal(1, "memory_manager: DESC_DEPTH=%0d, expected 256 (matches tile_id width 8)",
                   DESC_DEPTH);
        end
    end

    // -------------------------------------------------------------------------
    // Descriptor table - 256 x csd_descriptor_t register file.
    //
    // Note (Phase-7d): the original code carried `(* ram_style = "distributed" *)`
    // here, but Vivado refused to infer LUTRAM (Synth 8-7186) because the packed
    // struct access pattern cracks per-field; it implements as a register file
    // instead. The RRRS-1 waiver in waivers.tcl already targets the resulting
    // *_reg* cells and stays valid.
    //
    // Phase-8 (SYNTH-6 fix): with no explicit style, Vivado still tried to pack
    // the two widest fields (dram_base, n_beats) into a BRAM block and warned
    // about the missing output register (SYNTH-6 ×2). The table read here is
    // ASYNCHRONOUS (desc_lookup below is a combinational index), which a BRAM
    // cannot legally serve anyway — so the only correct implementations are a
    // flop register file or LUTRAM. We pin it to "registers": behaviourally
    // identical (zero latency change), removes the illegal BRAM mapping, and
    // clears both SYNTH-6 rows. Area cost is bounded — 256 × the two wide
    // fields' flops, well inside the FF budget (CLAUDE.md §1).
    // -------------------------------------------------------------------------
    (* ram_style = "registers" *)
    csd_descriptor_t desc_table [DESC_DEPTH];

    csd_descriptor_t desc_lookup;
    assign desc_lookup = desc_table[issue.tile_id];

    always_ff @(posedge clk) begin
        if (desc_we) begin
            desc_table[desc_wr_addr] <= desc_wr_data;
        end
    end

    // -------------------------------------------------------------------------
    // Command FSM.
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        M_IDLE         = 4'd0,
        M_CSD_REQ      = 4'd1,  // present desc to csd_engine, wait for handshake
        M_CSD_WAIT     = 4'd2,  // wait for csd_engine.done_o
        M_PP_PULSE     = 4'd3,  // 1-cycle swap_req pulse
        M_PP_WAIT      = 4'd4,  // wait for swap_done from selected pingpong
        M_NOP          = 4'd5,  // 1-cycle ack for unsupported opcodes
        M_ST_OUT_REQ   = 4'd6,  // present desc to csd_drain_engine
        M_ST_OUT_WAIT  = 4'd7,  // wait for csd_drain_engine.done_o
        M_DONE         = 4'd8   // 1-cycle done pulse, return to IDLE
    } mstate_e;

    mstate_e         state_q, state_d;
    macro_opc_e      opc_q;
    logic [7:0]      tile_id_q;
    logic            is_sparse_q;
    csd_descriptor_t desc_q;       // latched at issue.start (frozen for csd handshake)

    // Submodule wires (declared up top so the FSM and the comb block can use them).
    // CSD engine handshake.
    logic                  csd_desc_valid;
    logic                  csd_desc_ready;
    logic                  csd_done;

    // CSD fill output (demuxed below).
    logic                       csd_fill_wr_en;
    logic [URAM_ADDR_W-1:0]     csd_fill_wr_addr;
    logic [URAM_WIDTH_BITS-1:0] csd_fill_wr_data;
    logic                       csd_fill_is_sparse;

    // Per-pingpong fill ports (driven from CSD via a sparse demux).
    logic                       dense_fill_wr_en;
    logic                       sparse_fill_wr_en;

    // Per-pingpong swap controls.
    logic dense_swap_req;
    logic dense_swap_done;
    logic sparse_swap_req;
    logic sparse_swap_done;

    // CSD drain engine handshake + URAM read port.
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

    // Selected swap_done for the currently-issued OP_PINGPONG.
    logic sel_swap_done;
    assign sel_swap_done = is_sparse_q ? sparse_swap_done : dense_swap_done;

    // FSM next-state logic.
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

            // Latch the op metadata at start. Per the mem_issue_if contract,
            // opc/tile_id/is_sparse stay stable across busy, so latching once
            // is enough; we latch anyway so downstream logic does not chase
            // the issue port through the whole op.
            if ((state_q == M_IDLE) && issue.start) begin
                opc_q       <= issue.opc;
                tile_id_q   <= issue.tile_id;
                is_sparse_q <= issue.is_sparse;
                desc_q      <= desc_lookup;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Outputs to the issue interface.
    //   done : 1-cycle pulse, equals state_q == M_DONE.
    // -------------------------------------------------------------------------
    assign issue.done = (state_q == M_DONE);

    // -------------------------------------------------------------------------
    // Drive the CSD engine.
    //   desc_valid is high in M_CSD_REQ until the engine accepts (its
    //   desc_ready_o is its IDLE state, so the handshake fires the first cycle
    //   we present the descriptor unless the engine is still wrapping up the
    //   previous fill - which the FSM disallows by serializing).
    //   desc_i is desc_q (latched), with the opcode already used to decide
    //   that we are in this branch.
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Fill demux: route the single CSD fill stream to whichever pool the
    // engine flagged via fill_is_sparse_o. The address and data are broadcast
    // to both pools - only the wr_en is gated, so the inactive pool's URAM
    // sees no commit.
    // -------------------------------------------------------------------------
    assign dense_fill_wr_en  = csd_fill_wr_en && !csd_fill_is_sparse;
    assign sparse_fill_wr_en = csd_fill_wr_en &&  csd_fill_is_sparse;

    // R6.8b: the dense pp is a WIDE bank (DENSE_PP_URAM_W = 288 b). Assemble the
    // narrow 72b csd fill stream into one wide write per DENSE_PP_URAM_WIDE (=4)
    // contiguous natives (leaf = addr[1:0], wide_addr = addr>>2). The sparse pool
    // stays narrow (72b direct). See design doc sec 14.8.
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

    // -------------------------------------------------------------------------
    // Ping-pong swap controls.
    //   On OP_PINGPONG, the FSM reaches M_PP_PULSE for exactly one cycle.
    //   We pulse swap_req on the selected pool that cycle and only that cycle.
    // -------------------------------------------------------------------------
    assign dense_swap_req  = (state_q == M_PP_PULSE) && !is_sparse_q;
    assign sparse_swap_req = (state_q == M_PP_PULSE) &&  is_sparse_q;

    // -------------------------------------------------------------------------
    // Ping-pong instantiations. Both default to BANK_A as the initial compute
    // side (so first fill lands on BANK_B, matching the dataflow doc in
    // CLAUDE.md).
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // OUTPUT URAM bank (fed by dense_out_collector through the external
    // out_wr_* port, drained by csd_drain_engine on OP_ST_OUT). Unlike the
    // ping-pong banks, this one is not double-buffered: the dispatcher is
    // expected to serialize the write-snap and the drain.
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // CSD drain engine (OP_ST_OUT). Same desc_q feeds both csd_engine and
    // csd_drain_engine -- the FSM only routes the descriptor handshake to one
    // of them at a time, so they cannot fire concurrently.
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // KV BRAM.
    // -------------------------------------------------------------------------
    kv_bram #(
        .DATA_W(KV_DATA_W),
        .DEPTH (KV_DEPTH),
        .ADDR_W(KV_ADDR_W)
    ) u_kv (
        .clk  (clk),
        .rst_n(rst_n),
        .kv   (kv)
    );

    // -------------------------------------------------------------------------
    // Simulation-only sanity checks.
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    // Descriptor table writes during a non-IDLE FSM state would race with the
    // table read used to populate desc_q. Forbid them.
    property p_desc_we_only_in_idle;
        @(posedge clk) disable iff (!rst_n)
        desc_we |-> (state_q == M_IDLE);
    endproperty
    a_desc_we_only_in_idle: assert property (p_desc_we_only_in_idle)
        else $error("memory_manager: desc_we asserted while FSM busy (state=%0d)", state_q);

    // start must only land in IDLE (the dispatcher should serialize ops).
    property p_start_only_in_idle;
        @(posedge clk) disable iff (!rst_n)
        issue.start |-> (state_q == M_IDLE);
    endproperty
    a_start_only_in_idle: assert property (p_start_only_in_idle)
        else $error("memory_manager: issue.start while FSM not IDLE (state=%0d)", state_q);

    // Soft warnings on unsupported opcodes. OP_ST_OUT is now fully supported
    // via the csd_drain_engine path (Phase 5).
    always_ff @(posedge clk) begin
        if (rst_n && (state_q == M_IDLE) && issue.start) begin
            unique case (issue.opc)
                OP_LD_W_URAM, OP_LD_A_URAM, OP_PINGPONG, OP_ST_OUT: ; // supported
                default:   $warning("memory_manager: unsupported opcode 0x%02h on mem_issue_if (acked as nop)",
                                    issue.opc);
            endcase
        end
    end
`endif

endmodule : memory_manager

`default_nettype wire
`endif // ARCHBETTER_MEMORY_MANAGER_SV
