// -----------------------------------------------------------------------------
// interfaces.sv
//
// SystemVerilog interfaces for the ArchBetter edge-LLM accelerator.
//
// Interfaces defined here:
//   strm_if          - generic circuit-switched streaming handshake
//                      (data / valid / ready / last [+ user])
//   noc_cfg_if       - dispatcher -> NoC router configuration bus
//                      (programs a path_id before any streaming begins)
//   pingpong_if      - memory manager <-> dense (or sparse) core control +
//                      read port, with drain handshake for safe bank swap
//   dense2sparse_if  - dedicated FIFO stream from Dense Core to Sparse Core
//                      (bypasses the main NoC fabric; used for FFN forwarding)
//   noc_router_if    - ingress / fan-out egress / path-select ports of a
//                      circuit-switched multicast router
//
// All interfaces carry `assert property` checks (under `ifndef SYNTHESIS) that
// express the handshake invariants we rely on in proofs and simulation.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_INTERFACES_SV
`define ARCHBETTER_INTERFACES_SV
`default_nettype none

// =============================================================================
// strm_if
//   Lean streaming contract (no AXI bloat). Multicast is handled by structural
//   fan-out in the NoC router, not by per-beat address.
// =============================================================================
interface strm_if #(
    parameter int unsigned DATA_W = 192, // default: one BFP12 block = 16 * 12b
    parameter int unsigned USER_W = 8
) (
    input  wire logic clk,
    input  wire logic rst_n
);

    logic [DATA_W-1:0] data;
    logic [USER_W-1:0] user;   // stream_id / meta; not used for routing (circuit-switched)
    logic              valid;
    logic              ready;
    logic              last;

    modport src  (output data, user, valid, last, input  ready);
    modport sink (input  data, user, valid, last, output ready);
    modport mon  (input  data, user, valid, ready, last);

`ifndef SYNTHESIS
    // Handshake invariant: while the source asserts valid and the sink is not
    // ready, data/user/last must remain stable (hold-on-backpressure).
    property p_hold_on_backpressure;
        @(posedge clk) disable iff (!rst_n)
        (valid && !ready) |=> (valid && $stable(data) && $stable(user) && $stable(last));
    endproperty
    a_hold_on_backpressure: assert property (p_hold_on_backpressure)
        else $error("strm_if: data/user/last changed while valid && !ready");
`endif

endinterface : strm_if


// =============================================================================
// noc_cfg_if
//   Dispatcher -> router configuration sideband. Called by OP_CFG_NOC; the
//   router latches (handle, cfg) into its path table. OP_COMMIT_NOC asserts
//   path_commit; after commit, the fabric is pure mux.
// =============================================================================
interface noc_cfg_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    logic [NOC_PATH_ID_W-1:0] handle;
    noc_path_cfg_t            cfg;
    logic                     cfg_valid;
    logic                     cfg_ready;
    logic                     path_commit;   // 1-cycle pulse: freeze table, enter streaming

    modport master (output handle, cfg, cfg_valid, path_commit,
                    input  cfg_ready);
    modport slave  (input  handle, cfg, cfg_valid, path_commit,
                    output cfg_ready);
    modport mon    (input  handle, cfg, cfg_valid, cfg_ready, path_commit);

`ifndef SYNTHESIS
    // Cannot commit while a config beat is still in flight unacked.
    property p_no_commit_mid_handshake;
        @(posedge clk) disable iff (!rst_n)
        path_commit |-> !(cfg_valid && !cfg_ready);
    endproperty
    a_no_commit_mid_handshake: assert property (p_no_commit_mid_handshake)
        else $error("noc_cfg_if: path_commit asserted while cfg handshake pending");
`endif

endinterface : noc_cfg_if


// =============================================================================
// pingpong_if
//   Memory manager <-> consuming compute core (Dense or Sparse).
//   The manager presents one of two URAM banks to the core; the other bank is
//   refilled in the background by the CSD engine. A swap only occurs after the
//   core asserts drain_ack in response to drain_req.
//
//   Signal direction from the manager's POV:
//     active_side  : which bank is currently on the read port
//     side_valid   : the muxed read-data path is coherent this cycle
//     rd_data      : data returned to the core (registered UltraRAM output)
//     rd_valid     : rd_data is the response for the matching prior rd_addr/rd_en
//     drain_req    : "finish your current tile and ack"
//     drain_ack    : (from core) "done, safe to swap now"
//     rd_addr/rd_en: read port driven by the core
// =============================================================================
interface pingpong_if #(
    parameter int unsigned ADDR_W = 12,   // override with types_pkg::URAM_ADDR_W
    parameter int unsigned DATA_W = 144   // 2 x URAM_WIDTH_BITS for cascaded pair
) (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    // Manager -> Core: side mux and read response
    bank_sel_e          active_side;
    logic               side_valid;
    logic [DATA_W-1:0]  rd_data;
    logic               rd_valid;
    logic               drain_req;

    // Core -> Manager: read command and drain ack
    logic [ADDR_W-1:0]  rd_addr;
    logic               rd_en;
    logic               drain_ack;

    modport mem_mgr (output active_side, side_valid, rd_data, rd_valid, drain_req,
                     input  rd_addr, rd_en, drain_ack);

    modport core    (input  active_side, side_valid, rd_data, rd_valid, drain_req,
                     output rd_addr, rd_en, drain_ack);

    modport mon     (input  active_side, side_valid, rd_data, rd_valid, drain_req,
                     input  rd_addr, rd_en, drain_ack);

`ifndef SYNTHESIS
    // The manager must not assert drain_req and simultaneously flip active_side
    // until drain_ack has come back - this is what makes the swap "safe".
    property p_no_flip_before_ack;
        logic prev_side;
        @(posedge clk) disable iff (!rst_n)
        (drain_req, prev_side = active_side) |->
            ##[1:$] (drain_ack && $stable(active_side))
                 ##1 (active_side !== prev_side || !drain_req);
    endproperty
    // Simpler liveness / safety asserts:
    a_no_read_before_sidevalid: assert property
        (@(posedge clk) disable iff (!rst_n) rd_en |-> side_valid)
        else $error("pingpong_if: rd_en asserted while side_valid=0");
    // Outstanding-read counter. The protocol invariant we actually want to
    // enforce is "every rd_valid pairs with an unmatched prior rd_en", with no
    // assumption about the read latency. The previous $past(rd_en, 1..2) form
    // baked in a 1-2 cycle latency contract that holds for the native
    // uram_pingpong but not for adapters (e.g. uram_cascade_adapter) whose
    // downstream port has a deeper latency.
    int unsigned outstanding_q;
    always_ff @(posedge clk) begin
        if (!rst_n) outstanding_q <= '0;
        else        outstanding_q <= outstanding_q
                                   + int'(rd_en && side_valid)
                                   - int'(rd_valid);
    end
    a_rdvalid_has_outstanding: assert property
        (@(posedge clk) disable iff (!rst_n)
         rd_valid |-> (outstanding_q > 0) || (rd_en && side_valid))
        else $error("pingpong_if: rd_valid with no outstanding rd_en");
    a_outstanding_no_underflow: assert property
        (@(posedge clk) disable iff (!rst_n) outstanding_q < 32'h8000_0000)
        else $error("pingpong_if: outstanding-read counter underflowed");
`endif

endinterface : pingpong_if


// =============================================================================
// dense2sparse_if
//   Dedicated NoC FIFO from the Dense Core to the Sparse Core.
//   This path carries FFN activations forwarded from attention output and is
//   physically separate from the main NoC multicast fabric so that the FFN
//   pipeline does not contend with activation broadcast traffic.
//
//   almost_full is an advisory hint back to the producer so it can throttle at
//   the group granularity without causing a full backpressure ripple.
// =============================================================================
interface dense2sparse_if #(
    parameter int unsigned DATA_W     = 192, // one BFP12 block per beat
    parameter int unsigned USER_W     = 8,
    parameter int unsigned FIFO_DEPTH = 64
) (
    input  wire logic clk,
    input  wire logic rst_n
);
    logic [DATA_W-1:0] data;
    logic [USER_W-1:0] user;
    logic              valid;
    logic              ready;
    logic              last;
    logic              almost_full; // advisory, not a handshake participant

    modport dense  (output data, user, valid, last, input  ready, almost_full);
    modport sparse (input  data, user, valid, last, output ready, output almost_full);
    modport mon    (input  data, user, valid, ready, last, almost_full);

`ifndef SYNTHESIS
    // No writes when backpressured AND almost_full.
    property p_respect_almost_full;
        @(posedge clk) disable iff (!rst_n)
        (almost_full && !ready) |-> !valid;
    endproperty
    a_respect_almost_full: assert property (p_respect_almost_full)
        else $error("dense2sparse_if: producer drove valid into a backpressured almost-full FIFO");
`endif

endinterface : dense2sparse_if


// =============================================================================
// noc_router_if
//   A single circuit-switched multicast router: one ingress port and FANOUT
//   egress ports. The hardwired destination mask is selected by path_id from
//   an internal path table loaded through noc_cfg_if.
//
//   Backpressure policy: the ingress accepts a beat only when ALL selected
//   egresses are ready (hold-on-backpressure). Per-destination skid is a local
//   option, not a default.
// =============================================================================
interface noc_router_if #(
    parameter int unsigned DATA_W = 192,
    parameter int unsigned USER_W = 8,
    parameter int unsigned FANOUT = 8
) (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    // Ingress
    logic [DATA_W-1:0] in_data;
    logic [USER_W-1:0] in_user;
    logic              in_valid;
    logic              in_ready;
    logic              in_last;

    // Fan-out egress (packed arrays so we can iterate in generate blocks)
    logic [FANOUT-1:0] [DATA_W-1:0] out_data;
    logic [FANOUT-1:0] [USER_W-1:0] out_user;
    logic [FANOUT-1:0]              out_valid;
    logic [FANOUT-1:0]              out_ready;
    logic [FANOUT-1:0]              out_last;

    // Path selection (driven by the dispatcher via the router's path table)
    logic [NOC_PATH_ID_W-1:0] path_id;
    logic                     path_commit; // 1-cycle pulse when the table freezes

    modport ingress (output in_data, in_user, in_valid, in_last,
                     input  in_ready);

    modport egress  (input  out_data, out_user, out_valid, out_last,
                     output out_ready);

    modport router  (input  in_data, in_user, in_valid, in_last,
                     output in_ready,
                     output out_data, out_user, out_valid, out_last,
                     input  out_ready,
                     input  path_id, path_commit);

    modport mon     (input  in_data, in_user, in_valid, in_ready, in_last,
                     input  out_data, out_user, out_valid, out_ready, out_last,
                     input  path_id, path_commit);

`ifndef SYNTHESIS
    // Ingress may only fire when EVERY currently-active egress is ready. We
    // model "currently-active egress" as out_valid, which the router raises on
    // exactly the multicast set for this beat.
    property p_all_active_ready_on_fire;
        @(posedge clk) disable iff (!rst_n)
        (in_valid && in_ready) |-> ((out_valid & ~out_ready) == '0);
    endproperty
    a_all_active_ready_on_fire: assert property (p_all_active_ready_on_fire)
        else $error("noc_router_if: ingress fired while a selected egress was backpressured");

    // path_commit is a single-cycle pulse by contract.
    property p_commit_is_pulse;
        @(posedge clk) disable iff (!rst_n)
        path_commit |=> !path_commit;
    endproperty
    a_commit_is_pulse: assert property (p_commit_is_pulse)
        else $error("noc_router_if: path_commit held high for more than one cycle");
`endif

endinterface : noc_router_if

// =============================================================================
// tlmm_ctrl_if
//   Driver <-> sparse TLMM tile. Three orthogonal channels, all valid/ready:
//
//     PROG    : a one-beat handshake that delivers TLMM_TILE stationary
//               activation mantissas. After prog_valid && prog_ready the tile
//               spends a fixed number of cycles filling its subset-sum LUTRAM
//               tables; during fill, w_ready stays low. Once tables are
//               coherent, w_ready rises and the COMPUTE phase may proceed.
//
//     COMPUTE : a streaming handshake carrying one tern_lane_tiles_t per
//               beat - ternary weights for TLMM_LANES parallel output
//               neurons evaluated against the currently-loaded activations.
//
//     OUT     : a streaming handshake carrying one tlmm_part_vec_t per
//               compute beat - the TLMM_LANES tile-partials produced by the
//               lanes, paired 1:1 with accepted weight beats (after pipeline
//               latency). The tile does NOT do K-accumulation; that is the
//               job of a separate neuron-accumulator module, which consumes
//               tile_partials and builds up tlmm_acc_t per output neuron.
//
//   Phase discipline: prog and w cannot handshake on the same cycle. The tile
//   keeps w_ready=0 during fill, so a well-behaved driver never needs to poll.
// =============================================================================
interface tlmm_ctrl_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    // -- PROG channel (activation load) ---------------------------------------
    tlmm_tile_act_t prog_acts;
    logic           prog_valid;
    logic           prog_ready;

    // -- COMPUTE channel (ternary weight beat) --------------------------------
    tern_lane_tiles_t w_tiles;
    logic             w_valid;
    logic             w_ready;

    // -- OUT channel (tile partials, one vector per accepted compute beat) ----
    tlmm_part_vec_t o_parts;
    logic           o_valid;
    logic           o_ready;

    modport driver (
        output prog_acts, prog_valid,
        input  prog_ready,
        output w_tiles, w_valid,
        input  w_ready,
        input  o_parts, o_valid,
        output o_ready
    );

    modport tile (
        input  prog_acts, prog_valid,
        output prog_ready,
        input  w_tiles, w_valid,
        output w_ready,
        output o_parts, o_valid,
        input  o_ready
    );

    modport mon (
        input  prog_acts, prog_valid, prog_ready,
        input  w_tiles, w_valid, w_ready,
        input  o_parts, o_valid, o_ready
    );

`ifndef SYNTHESIS
    // Hold-on-backpressure on each channel.
    property p_prog_stable;
        @(posedge clk) disable iff (!rst_n)
        (prog_valid && !prog_ready) |=> (prog_valid && $stable(prog_acts));
    endproperty
    a_prog_stable: assert property (p_prog_stable)
        else $error("tlmm_ctrl_if: prog_acts changed while prog_valid && !prog_ready");

    property p_w_stable;
        @(posedge clk) disable iff (!rst_n)
        (w_valid && !w_ready) |=> (w_valid && $stable(w_tiles));
    endproperty
    a_w_stable: assert property (p_w_stable)
        else $error("tlmm_ctrl_if: w_tiles changed while w_valid && !w_ready");

    property p_o_stable;
        @(posedge clk) disable iff (!rst_n)
        (o_valid && !o_ready) |=> (o_valid && $stable(o_parts));
    endproperty
    a_o_stable: assert property (p_o_stable)
        else $error("tlmm_ctrl_if: o_parts changed while o_valid && !o_ready");

    // Phase mutex: PROG and COMPUTE cannot fire on the same cycle.
    property p_phase_mutex;
        @(posedge clk) disable iff (!rst_n)
        !((prog_valid && prog_ready) && (w_valid && w_ready));
    endproperty
    a_phase_mutex: assert property (p_phase_mutex)
        else $error("tlmm_ctrl_if: PROG and COMPUTE fired on the same cycle");
`endif

endinterface : tlmm_ctrl_if


// =============================================================================
// gemm_issue_if
//   Dispatcher -> dense-core driver (TB in Layer 2, memory-manager wrapper in
//   Layer 3). Pure CONTROL-plane: no activation payload - data still streams
//   through the NoC fabric from its own producer. The dispatcher owns the
//   committed path_id and the accumulator control pulses; the driver reports
//   beat_fire (one tick per accepted activation beat on the committed source).
//
//   Timing contract (from dense_group):
//     * acc_clr must co-fire with the first beat_fire of a GEMM op
//     * acc_snap must fire >= 1 cycle after the last beat_fire (no co-fire)
//     * both pulses are exactly 1 cycle
//     * busy is level-high for the whole op; drops the cycle after acc_snap
//     * path_id is stable while busy (fabric requires stability during stalls)
//
//   beat_fire is typically wired to (src.valid && src.ready) on the committed
//   NoC source in integration.
// =============================================================================
interface gemm_issue_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    logic [NOC_PATH_ID_W-1:0] path_id;
    logic [MACRO_CNT_W-1:0]   k_cnt;
    logic                     acc_clr;    // PER_TOKEN: 1-cycle pulse co-firing first
                                          // beat. CONTINUOUS (R6.4): high on EVERY
                                          // beat (each beat is a fresh K=1 LOAD).
    logic                     acc_snap;   // 1-cycle pulse, >=1 cycle after last beat_fire
    logic                     busy;       // level high during op
    logic                     beat_fire;  // from driver: 1 when a beat fired this cycle
    gemm_stream_mode_e        stream_mode; // R6.4: v1 single-snap vs v2 continuous
    logic [BATCH_TOK_W-1:0]   batch_n;    // R6.5: token count T (CONTINUOUS beat count)

    modport disp (output path_id, k_cnt, acc_clr, acc_snap, busy, stream_mode, batch_n,
                  input  beat_fire);
    modport drv  (input  path_id, k_cnt, acc_clr, acc_snap, busy, stream_mode, batch_n,
                  output beat_fire);
    modport mon  (input  path_id, k_cnt, acc_clr, acc_snap, busy, stream_mode, batch_n,
                  beat_fire);

`ifndef SYNTHESIS
    // Pulse shape — PER_TOKEN only. In CONTINUOUS mode acc_clr is high on every
    // beat (per-beat LOAD), so the one-shot pulse contract does not apply; the
    // a_acc_clr_with_fire invariant below (acc_clr |-> beat_fire) still holds in
    // both modes and is the live continuous-mode contract.
    property p_acc_clr_pulse;
        @(posedge clk) disable iff (!rst_n || (stream_mode == GEMM_SNAP_CONTINUOUS))
        acc_clr |=> !acc_clr;
    endproperty
    a_acc_clr_pulse: assert property (p_acc_clr_pulse)
        else $error("gemm_issue_if: acc_clr held high for more than one cycle (PER_TOKEN)");

    property p_acc_snap_pulse;
        @(posedge clk) disable iff (!rst_n)
        acc_snap |=> !acc_snap;
    endproperty
    a_acc_snap_pulse: assert property (p_acc_snap_pulse)
        else $error("gemm_issue_if: acc_snap held high for more than one cycle");

    // Control pulses require busy.
    a_acc_clr_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) acc_clr |-> busy
    ) else $error("gemm_issue_if: acc_clr asserted while busy=0");

    a_acc_snap_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) acc_snap |-> busy
    ) else $error("gemm_issue_if: acc_snap asserted while busy=0");

    // Cross-contract with dense_group: acc_clr must co-fire with beat_fire,
    // acc_snap must NOT co-fire with beat_fire.
    a_acc_clr_with_fire: assert property (
        @(posedge clk) disable iff (!rst_n) acc_clr |-> beat_fire
    ) else $error("gemm_issue_if: acc_clr asserted without beat_fire (dense_group contract)");

    a_acc_snap_not_with_fire: assert property (
        @(posedge clk) disable iff (!rst_n) !(acc_snap && beat_fire)
    ) else $error("gemm_issue_if: acc_snap co-fired with beat_fire (dense_group contract)");

    // beat_fire only flows during an op. A rogue fire outside busy means the
    // driver is streaming when the dispatcher did not authorize it.
    a_beat_fire_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) beat_fire |-> busy
    ) else $error("gemm_issue_if: beat_fire asserted while busy=0");

    // path_id must stay stable across a busy epoch.
    property p_path_id_stable_while_busy;
        @(posedge clk) disable iff (!rst_n)
        (busy && $past(busy)) |-> $stable(path_id);
    endproperty
    a_path_id_stable_while_busy: assert property (p_path_id_stable_while_busy)
        else $error("gemm_issue_if: path_id changed mid-op");
`endif

endinterface : gemm_issue_if


// =============================================================================
// dense_sched_if
//   Phase-8 dispatcher tile-walker -> dense array + dense weight streamer.
//
//   Internalizes what the Phase-7 harness top drove as host ports
//   (tile_gr / tile_gc / tile_first / tile_last and the per-tile weight scan
//   bus w_we / w_phys_gc / w_pe_addr / w_in). Those undriven top ports are a
//   primary cause of the OOC pruning; moving them onto this dispatcher-driven
//   bus is what closes the dense loop.
//
//   For OP_GEMM_LAYER the walker iterates the DENSE_LOGICAL_TILE_ROWS x
//   DENSE_LOGICAL_TILE_COLS grid; per tile it:
//     1. drives tile_gr / tile_gc (the logical tile coordinate),
//     2. pulses load_req and holds load_busy until load_done — the weight
//        streamer fills the 512 PE weight registers for this tile from the
//        dense URAM ping-pong over the w_* scan bus,
//     3. pulses tile_first on the FIRST tile of the layer (clears the bank),
//     4. runs the inner single-tile GEMM (acc_clr / acc_snap on gemm_issue_if),
//     5. pulses tile_last concurrent with the FINAL tile's acc_snap (drains
//        y_out + y_valid).
//
//   acc_clr / acc_snap stay on gemm_issue_if (unchanged). The array consumes
//   BOTH interfaces — exactly as the Phase-7 array consumed gemm_bus pulses
//   plus the (then host-driven) tile_* ports.
//
//   Handshake shape mirrors mem_issue_if: the WALKER drives both load_req and
//   load_busy (req pulse co-rises with busy, busy holds until done); the
//   STREAMER drives load_done (1-cycle pulse, co-falls with busy) and the scan
//   bus. tile_gr / tile_gc are shared (walker -> {streamer, array}).
// =============================================================================
interface dense_sched_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    // -- Tile schedule (walker -> array; coords also -> streamer) --------------
    logic [$clog2(DENSE_LOGICAL_TILE_ROWS)-1:0] tile_gr;
    logic [$clog2(DENSE_LOGICAL_TILE_COLS)-1:0] tile_gc;
    logic                                       tile_first; // 1-cycle, layer start
    logic                                       tile_last;  // 1-cycle, co-fires final acc_snap

    // -- Batched-GEMM sideband (C1.5; walker -> array) ------------------------
    // tile_tok : index of the token whose partial is accumulated at this snap.
    //            Held stable across a token's compute window (acc_clr..snap).
    // batch_n  : runtime token count T for the current batch (1 = decode). Stable
    //            for the whole batch; tells the array how many outputs to drain.
    logic [BATCH_TOK_W-1:0]                     tile_tok;
    logic [BATCH_TOK_W-1:0]                     batch_n;

    // -- Snap mode (R6.4; walker -> array) ------------------------------------
    // PER_TOKEN = v1 single-snap-per-token; CONTINUOUS = v2 II=1 stream with
    // tok_out-aligned per-cycle bank RMW. Stable across one OP_GEMM_BATCH op.
    gemm_stream_mode_e                          stream_mode;

    // -- Weight-load handshake (walker drives req+busy, streamer drives done) --
    logic load_req;   // 1-cycle pulse, co-rises with load_busy
    logic load_busy;  // level high from load_req through load_done
    logic load_done;  // 1-cycle pulse: the 512 PE weight registers are loaded

    // -- Weight scan bus (streamer -> array) ----------------------------------
    // C1.5 parallel scan: one beat writes a whole URAM weight word = 8 PEs at
    // once (w_in carries 8 mantissas). w_pe_addr is the BASE PE index of the 8
    // (always a multiple of 8); the group selects PEs whose addr[7:3] matches and
    // routes w_in[addr[2:0]]. Cuts the per-tile scan ~8x on the scan dimension.
    logic                                  w_we;
    logic                                  w_phys_gc;  // selects 1 of 2 physical groups
    logic [$clog2(DENSE_PE_PER_GROUP)-1:0] w_pe_addr;  // base PE addr (mult. of 8)
    bfp12_mant_t [(BFP12_BLK/2)-1:0]       w_in;       // 8 mantissas (one weight word)

    modport walker (
        output tile_gr, tile_gc, tile_first, tile_last, tile_tok, batch_n,
        output stream_mode,
        output load_req, load_busy,
        input  load_done
    );
    modport streamer (
        input  tile_gr, tile_gc, load_req, load_busy,
        output load_done, w_we, w_phys_gc, w_pe_addr, w_in
    );
    modport array (
        input  tile_gr, tile_gc, tile_first, tile_last, tile_tok, batch_n,
        input  stream_mode,
        input  w_we, w_phys_gc, w_pe_addr, w_in
    );
    modport mon (
        input  tile_gr, tile_gc, tile_first, tile_last, tile_tok, batch_n,
        input  stream_mode,
        input  load_req, load_busy, load_done,
        input  w_we, w_phys_gc, w_pe_addr, w_in
    );

`ifndef SYNTHESIS
    // Load handshake mirrors mem_issue_if: req/done are 1-cycle pulses, both
    // require busy, coords are stable across the busy epoch.
    property p_load_req_pulse;
        @(posedge clk) disable iff (!rst_n) load_req |=> !load_req;
    endproperty
    a_load_req_pulse: assert property (p_load_req_pulse)
        else $error("dense_sched_if: load_req held high for more than one cycle");

    property p_load_done_pulse;
        @(posedge clk) disable iff (!rst_n) load_done |=> !load_done;
    endproperty
    a_load_done_pulse: assert property (p_load_done_pulse)
        else $error("dense_sched_if: load_done held high for more than one cycle");

    a_load_req_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) load_req |-> load_busy
    ) else $error("dense_sched_if: load_req asserted while load_busy=0");

    a_load_done_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) load_done |-> load_busy
    ) else $error("dense_sched_if: load_done asserted while load_busy=0");

    property p_tile_coords_stable_while_load;
        @(posedge clk) disable iff (!rst_n)
        (load_busy && $past(load_busy)) |-> ($stable(tile_gr) && $stable(tile_gc));
    endproperty
    a_tile_coords_stable_while_load: assert property (p_tile_coords_stable_while_load)
        else $error("dense_sched_if: tile_gr/tile_gc changed mid weight-load");

    // tile_first / tile_last are 1-cycle pulses.
    property p_tile_first_pulse;
        @(posedge clk) disable iff (!rst_n) tile_first |=> !tile_first;
    endproperty
    a_tile_first_pulse: assert property (p_tile_first_pulse)
        else $error("dense_sched_if: tile_first held high for more than one cycle");

    property p_tile_last_pulse;
        @(posedge clk) disable iff (!rst_n) tile_last |=> !tile_last;
    endproperty
    a_tile_last_pulse: assert property (p_tile_last_pulse)
        else $error("dense_sched_if: tile_last held high for more than one cycle");

    // A scan write only happens while the streamer owns an active load.
    a_scan_within_load: assert property (
        @(posedge clk) disable iff (!rst_n) w_we |-> load_busy
    ) else $error("dense_sched_if: w_we asserted outside a weight-load (load_busy=0)");
`endif

endinterface : dense_sched_if


// =============================================================================
// tlmm_issue_if
//   Dispatcher -> TLMM driver (TB in Layer 2, memory-manager+sparse-tile
//   wrapper in Layer 3). Again pure CONTROL-plane: the activation and ternary
//   weight payloads travel on tlmm_ctrl_if from the driver side; the
//   dispatcher only kicks the op off and waits for completion.
//
//   Timing contract:
//     * start is a 1-cycle pulse that co-rises with busy
//     * busy holds high from start through done
//     * done is a 1-cycle pulse that co-falls with busy
//     * k_cnt is stable across a busy epoch
// =============================================================================
interface tlmm_issue_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    logic                   start;   // 1-cycle pulse
    logic [MACRO_CNT_W-1:0] k_cnt;   // compute beats expected this op
    logic                   busy;    // level high during op
    logic                   done;    // 1-cycle pulse from driver on completion

    modport disp (output start, k_cnt, busy, input done);
    modport drv  (input  start, k_cnt, busy, output done);
    modport mon  (input  start, k_cnt, busy, done);

`ifndef SYNTHESIS
    property p_start_pulse;
        @(posedge clk) disable iff (!rst_n)
        start |=> !start;
    endproperty
    a_start_pulse: assert property (p_start_pulse)
        else $error("tlmm_issue_if: start held high for more than one cycle");

    property p_done_pulse;
        @(posedge clk) disable iff (!rst_n)
        done |=> !done;
    endproperty
    a_done_pulse: assert property (p_done_pulse)
        else $error("tlmm_issue_if: done held high for more than one cycle");

    a_start_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) start |-> busy
    ) else $error("tlmm_issue_if: start asserted while busy=0");

    a_done_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) done |-> busy
    ) else $error("tlmm_issue_if: done asserted while busy=0");

    property p_k_cnt_stable_while_busy;
        @(posedge clk) disable iff (!rst_n)
        (busy && $past(busy)) |-> $stable(k_cnt);
    endproperty
    a_k_cnt_stable_while_busy: assert property (p_k_cnt_stable_while_busy)
        else $error("tlmm_issue_if: k_cnt changed mid-op");
`endif

endinterface : tlmm_issue_if


// =============================================================================
// mem_issue_if
//   Dispatcher -> Memory Manager control sideband for Layer-3 memory ops:
//   OP_LD_W_URAM / OP_LD_A_URAM / OP_ST_OUT / OP_PINGPONG. Pure control; the
//   CSD/URAM payload never touches this bus. is_sparse selects between the
//   dense (bank {0,1}) and sparse (bank {2,3}) ping-pong pools; the Memory
//   Manager owns which side of the selected pool is "fill" vs "compute", so
//   the dispatcher does not carry a bank index here.
//
//   Timing contract (mirrors tlmm_issue_if):
//     * start is a 1-cycle pulse that co-rises with busy
//     * busy holds high from start through done
//     * done is a 1-cycle pulse that co-falls with busy
//     * opc / tile_id / is_sparse are stable across a busy epoch
// =============================================================================
interface mem_issue_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    logic       start;
    macro_opc_e opc;
    logic [7:0] tile_id;
    logic       is_sparse;
    logic       busy;
    logic       done;

    modport disp (output start, opc, tile_id, is_sparse, busy,
                  input  done);
    modport mgr  (input  start, opc, tile_id, is_sparse, busy,
                  output done);
    modport mon  (input  start, opc, tile_id, is_sparse, busy, done);

`ifndef SYNTHESIS
    property p_start_pulse;
        @(posedge clk) disable iff (!rst_n)
        start |=> !start;
    endproperty
    a_start_pulse: assert property (p_start_pulse)
        else $error("mem_issue_if: start held high for more than one cycle");

    property p_done_pulse;
        @(posedge clk) disable iff (!rst_n)
        done |=> !done;
    endproperty
    a_done_pulse: assert property (p_done_pulse)
        else $error("mem_issue_if: done held high for more than one cycle");

    a_start_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) start |-> busy
    ) else $error("mem_issue_if: start asserted while busy=0");

    a_done_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) done |-> busy
    ) else $error("mem_issue_if: done asserted while busy=0");

    property p_opc_stable_while_busy;
        @(posedge clk) disable iff (!rst_n)
        (busy && $past(busy)) |-> ($stable(opc) && $stable(tile_id) && $stable(is_sparse));
    endproperty
    a_opc_stable_while_busy: assert property (p_opc_stable_while_busy)
        else $error("mem_issue_if: opc/tile_id/is_sparse changed mid-op");
`endif

endinterface : mem_issue_if


// =============================================================================
// csd_dram_if
//   Memory Manager (CSD engine) -> off-chip DRAM. Phase 2 uses a TB stub on the
//   slave side; a real MIG wrapper will replace the stub in the top/ SoC shell.
//
//   Two orthogonal sub-channels:
//     REQUEST : fire-and-forget (addr, len). The slave may delay req_ready to
//               model arbitration; once accepted, it begins streaming beats.
//     RESPONSE: beat stream of DRAM_BEAT_W bits, terminated by rsp_last. The
//               slave must present beats in address order and assert rsp_last
//               on the (req_len-1)^th beat of each accepted request.
//
//   Multiple outstanding requests are NOT supported in Phase 2 - the engine
//   serializes one descriptor at a time. A later revision can pipeline.
// =============================================================================
interface csd_dram_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    // Request channel.
    logic [DRAM_ADDR_W-1:0] req_addr;
    logic [DRAM_LEN_W-1:0]  req_len;
    logic                   req_valid;
    logic                   req_ready;

    // Response channel.
    logic [DRAM_BEAT_W-1:0] rsp_data;
    logic                   rsp_valid;
    logic                   rsp_ready;
    logic                   rsp_last;

    modport mgr  (output req_addr, req_len, req_valid,
                  input  req_ready,
                  input  rsp_data, rsp_valid, rsp_last,
                  output rsp_ready);

    modport dram (input  req_addr, req_len, req_valid,
                  output req_ready,
                  output rsp_data, rsp_valid, rsp_last,
                  input  rsp_ready);

    modport mon  (input  req_addr, req_len, req_valid, req_ready,
                  input  rsp_data, rsp_valid, rsp_last, rsp_ready);

`ifndef SYNTHESIS
    property p_req_stable;
        @(posedge clk) disable iff (!rst_n)
        (req_valid && !req_ready) |=> (req_valid && $stable(req_addr) && $stable(req_len));
    endproperty
    a_req_stable: assert property (p_req_stable)
        else $error("csd_dram_if: req_addr/len changed while req_valid && !req_ready");

    property p_rsp_stable;
        @(posedge clk) disable iff (!rst_n)
        (rsp_valid && !rsp_ready) |=> (rsp_valid && $stable(rsp_data) && $stable(rsp_last));
    endproperty
    a_rsp_stable: assert property (p_rsp_stable)
        else $error("csd_dram_if: rsp_data/last changed while rsp_valid && !rsp_ready");

    // Zero-length requests make no sense and would break rsp_last counting.
    a_req_nonzero_len: assert property (
        @(posedge clk) disable iff (!rst_n) (req_valid && req_ready) |-> (req_len != '0)
    ) else $error("csd_dram_if: accepted request with req_len=0");
`endif

endinterface : csd_dram_if


// =============================================================================
// csd_dram_wr_if
//   Memory Manager (csd_drain_engine) -> off-chip DRAM, OUTPUT direction.
//   Phase 5 introduces this for OP_ST_OUT, which streams a region of the
//   on-chip output URAM back to DRAM. A future MIG/DDR4 wrapper will drive
//   the slave side; until then, testbenches use a stub.
//
//   Two orthogonal sub-channels (no B-channel — wd_last is the completion
//   signal to the engine; the slave is expected to commit beats in order):
//     REQUEST : (addr, len). req_ready may stall to model arbitration.
//     WRITE   : beat stream of DRAM_BEAT_W bits, terminated by wd_last on
//               the (req_len-1)^th beat of each accepted request.
//
//   Multiple outstanding requests are NOT supported in Phase 5 (parity with
//   csd_dram_if). A later revision can pipeline.
// =============================================================================
interface csd_dram_wr_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    // Request channel.
    logic [DRAM_ADDR_W-1:0] req_addr;
    logic [DRAM_LEN_W-1:0]  req_len;
    logic                   req_valid;
    logic                   req_ready;

    // Write-data channel.
    logic [DRAM_BEAT_W-1:0] wd_data;
    logic                   wd_valid;
    logic                   wd_ready;
    logic                   wd_last;

    modport mgr  (output req_addr, req_len, req_valid,
                  input  req_ready,
                  output wd_data, wd_valid, wd_last,
                  input  wd_ready);

    modport dram (input  req_addr, req_len, req_valid,
                  output req_ready,
                  input  wd_data, wd_valid, wd_last,
                  output wd_ready);

    modport mon  (input  req_addr, req_len, req_valid, req_ready,
                  input  wd_data, wd_valid, wd_last, wd_ready);

`ifndef SYNTHESIS
    property p_req_stable;
        @(posedge clk) disable iff (!rst_n)
        (req_valid && !req_ready) |=> (req_valid && $stable(req_addr) && $stable(req_len));
    endproperty
    a_req_stable: assert property (p_req_stable)
        else $error("csd_dram_wr_if: req_addr/len changed while req_valid && !req_ready");

    property p_wd_stable;
        @(posedge clk) disable iff (!rst_n)
        (wd_valid && !wd_ready) |=> (wd_valid && $stable(wd_data) && $stable(wd_last));
    endproperty
    a_wd_stable: assert property (p_wd_stable)
        else $error("csd_dram_wr_if: wd_data/last changed while wd_valid && !wd_ready");

    a_req_nonzero_len: assert property (
        @(posedge clk) disable iff (!rst_n) (req_valid && req_ready) |-> (req_len != '0)
    ) else $error("csd_dram_wr_if: accepted request with req_len=0");
`endif

endinterface : csd_dram_wr_if


// =============================================================================
// kv_access_if
//   Dispatcher -> Memory Manager KV BRAM port. Simple-dual-port (write port A,
//   read port B). Port A accepts a write any cycle wr_en is high; port B
//   returns data two cycles after rd_en (BRAM output latch + OREG), signalled
//   by rd_valid. The read consumer is the attention block (TBD); until that
//   lands, testbenches observe rd_data/rd_valid directly.
//
//   No backpressure on either port: BRAM cannot stall. The master is
//   responsible for pacing (at most one outstanding read, and no write-then-
//   read-same-address hazards since the dispatcher serializes KV ops).
// =============================================================================
interface kv_access_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    // Port A: write.
    logic [KV_ADDR_W-1:0] wr_addr;
    logic [KV_DATA_W-1:0] wr_data;
    logic                 wr_en;

    // Port B: read (registered output).
    logic [KV_ADDR_W-1:0] rd_addr;
    logic                 rd_en;
    logic [KV_DATA_W-1:0] rd_data;
    logic                 rd_valid;  // 2 cycles after rd_en (latch + OREG)

    modport master (output wr_addr, wr_data, wr_en, rd_addr, rd_en,
                    input  rd_data, rd_valid);
    modport slave  (input  wr_addr, wr_data, wr_en, rd_addr, rd_en,
                    output rd_data, rd_valid);
    modport mon    (input  wr_addr, wr_data, wr_en, rd_addr, rd_en, rd_data, rd_valid);

`ifndef SYNTHESIS
    // rd_valid must follow rd_en by exactly two cycles (BRAM latch + OREG).
    property p_rd_valid_follows_en;
        @(posedge clk) disable iff (!rst_n)
        rd_valid |-> $past(rd_en, 2);
    endproperty
    a_rd_valid_follows_en: assert property (p_rd_valid_follows_en)
        else $error("kv_access_if: rd_valid without rd_en two cycles prior");

    property p_rd_en_produces_valid;
        @(posedge clk) disable iff (!rst_n)
        rd_en |-> ##2 rd_valid;
    endproperty
    a_rd_en_produces_valid: assert property (p_rd_en_produces_valid)
        else $error("kv_access_if: rd_en not followed by rd_valid two cycles later");
`endif

endinterface : kv_access_if


`default_nettype wire
`endif // ARCHBETTER_INTERFACES_SV
