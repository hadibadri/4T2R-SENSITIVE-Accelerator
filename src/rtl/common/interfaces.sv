
`timescale 1ns/1ps
`ifndef ARCHBETTER_INTERFACES_SV
`define ARCHBETTER_INTERFACES_SV
`default_nettype none
interface strm_if #(
    parameter int unsigned DATA_W = 192,
    parameter int unsigned USER_W = 8
) (
    input  wire logic clk,
    input  wire logic rst_n
);

    logic [DATA_W-1:0] data;
    logic [USER_W-1:0] user;
    logic              valid;
    logic              ready;
    logic              last;

    modport src  (output data, user, valid, last, input  ready);
    modport sink (input  data, user, valid, last, output ready);
    modport mon  (input  data, user, valid, ready, last);

`ifndef SYNTHESIS
    property p_hold_on_backpressure;
        @(posedge clk) disable iff (!rst_n)
        (valid && !ready) |=> (valid && $stable(data) && $stable(user) && $stable(last));
    endproperty
    a_hold_on_backpressure: assert property (p_hold_on_backpressure)
        else $error("strm_if: data/user/last changed while valid && !ready");
`endif

endinterface : strm_if
interface noc_cfg_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    logic [NOC_PATH_ID_W-1:0] handle;
    noc_path_cfg_t            cfg;
    logic                     cfg_valid;
    logic                     cfg_ready;
    logic                     path_commit;

    modport master (output handle, cfg, cfg_valid, path_commit,
                    input  cfg_ready);
    modport slave  (input  handle, cfg, cfg_valid, path_commit,
                    output cfg_ready);
    modport mon    (input  handle, cfg, cfg_valid, cfg_ready, path_commit);

`ifndef SYNTHESIS
    property p_no_commit_mid_handshake;
        @(posedge clk) disable iff (!rst_n)
        path_commit |-> !(cfg_valid && !cfg_ready);
    endproperty
    a_no_commit_mid_handshake: assert property (p_no_commit_mid_handshake)
        else $error("noc_cfg_if: path_commit asserted while cfg handshake pending");
`endif

endinterface : noc_cfg_if
interface pingpong_if #(
    parameter int unsigned ADDR_W = 12,
    parameter int unsigned DATA_W = 144
) (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;
    bank_sel_e          active_side;
    logic               side_valid;
    logic [DATA_W-1:0]  rd_data;
    logic               rd_valid;
    logic               drain_req;
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
    property p_no_flip_before_ack;
        logic prev_side;
        @(posedge clk) disable iff (!rst_n)
        (drain_req, prev_side = active_side) |->
            ##[1:$] (drain_ack && $stable(active_side))
                 ##1 (active_side !== prev_side || !drain_req);
    endproperty
    a_no_read_before_sidevalid: assert property
        (@(posedge clk) disable iff (!rst_n) rd_en |-> side_valid)
        else $error("pingpong_if: rd_en asserted while side_valid=0");
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
interface dense2sparse_if #(
    parameter int unsigned DATA_W     = 192,
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
    logic              almost_full;

    modport dense  (output data, user, valid, last, input  ready, almost_full);
    modport sparse (input  data, user, valid, last, output ready, output almost_full);
    modport mon    (input  data, user, valid, ready, last, almost_full);

`ifndef SYNTHESIS
    property p_respect_almost_full;
        @(posedge clk) disable iff (!rst_n)
        (almost_full && !ready) |-> !valid;
    endproperty
    a_respect_almost_full: assert property (p_respect_almost_full)
        else $error("dense2sparse_if: producer drove valid into a backpressured almost-full FIFO");
`endif

endinterface : dense2sparse_if
interface noc_router_if #(
    parameter int unsigned DATA_W = 192,
    parameter int unsigned USER_W = 8,
    parameter int unsigned FANOUT = 8
) (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;
    logic [DATA_W-1:0] in_data;
    logic [USER_W-1:0] in_user;
    logic              in_valid;
    logic              in_ready;
    logic              in_last;
    logic [FANOUT-1:0] [DATA_W-1:0] out_data;
    logic [FANOUT-1:0] [USER_W-1:0] out_user;
    logic [FANOUT-1:0]              out_valid;
    logic [FANOUT-1:0]              out_ready;
    logic [FANOUT-1:0]              out_last;
    logic [NOC_PATH_ID_W-1:0] path_id;
    logic                     path_commit;

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
    property p_all_active_ready_on_fire;
        @(posedge clk) disable iff (!rst_n)
        (in_valid && in_ready) |-> ((out_valid & ~out_ready) == '0);
    endproperty
    a_all_active_ready_on_fire: assert property (p_all_active_ready_on_fire)
        else $error("noc_router_if: ingress fired while a selected egress was backpressured");
    property p_commit_is_pulse;
        @(posedge clk) disable iff (!rst_n)
        path_commit |=> !path_commit;
    endproperty
    a_commit_is_pulse: assert property (p_commit_is_pulse)
        else $error("noc_router_if: path_commit held high for more than one cycle");
`endif

endinterface : noc_router_if
interface tlmm_ctrl_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;
    tlmm_tile_act_t prog_acts;
    logic           prog_valid;
    logic           prog_ready;
    tern_lane_tiles_t w_tiles;
    logic             w_valid;
    logic             w_ready;
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
    property p_phase_mutex;
        @(posedge clk) disable iff (!rst_n)
        !((prog_valid && prog_ready) && (w_valid && w_ready));
    endproperty
    a_phase_mutex: assert property (p_phase_mutex)
        else $error("tlmm_ctrl_if: PROG and COMPUTE fired on the same cycle");
`endif

endinterface : tlmm_ctrl_if
interface gemm_issue_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    logic [NOC_PATH_ID_W-1:0] path_id;
    logic [MACRO_CNT_W-1:0]   k_cnt;
    logic                     acc_clr;
    logic                     acc_snap;
    logic                     busy;
    logic                     beat_fire;
    gemm_stream_mode_e        stream_mode;
    logic [BATCH_TOK_W-1:0]   batch_n;

    modport disp (output path_id, k_cnt, acc_clr, acc_snap, busy, stream_mode, batch_n,
                  input  beat_fire);
    modport drv  (input  path_id, k_cnt, acc_clr, acc_snap, busy, stream_mode, batch_n,
                  output beat_fire);
    modport mon  (input  path_id, k_cnt, acc_clr, acc_snap, busy, stream_mode, batch_n,
                  beat_fire);

`ifndef SYNTHESIS
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
    a_acc_clr_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) acc_clr |-> busy
    ) else $error("gemm_issue_if: acc_clr asserted while busy=0");

    a_acc_snap_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) acc_snap |-> busy
    ) else $error("gemm_issue_if: acc_snap asserted while busy=0");
    a_acc_clr_with_fire: assert property (
        @(posedge clk) disable iff (!rst_n) acc_clr |-> beat_fire
    ) else $error("gemm_issue_if: acc_clr asserted without beat_fire (dense_group contract)");

    a_acc_snap_not_with_fire: assert property (
        @(posedge clk) disable iff (!rst_n) !(acc_snap && beat_fire)
    ) else $error("gemm_issue_if: acc_snap co-fired with beat_fire (dense_group contract)");
    a_beat_fire_requires_busy: assert property (
        @(posedge clk) disable iff (!rst_n) beat_fire |-> busy
    ) else $error("gemm_issue_if: beat_fire asserted while busy=0");
    property p_path_id_stable_while_busy;
        @(posedge clk) disable iff (!rst_n)
        (busy && $past(busy)) |-> $stable(path_id);
    endproperty
    a_path_id_stable_while_busy: assert property (p_path_id_stable_while_busy)
        else $error("gemm_issue_if: path_id changed mid-op");
`endif

endinterface : gemm_issue_if
interface dense_sched_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;
    logic [$clog2(DENSE_LOGICAL_TILE_ROWS)-1:0] tile_gr;
    logic [$clog2(DENSE_LOGICAL_TILE_COLS)-1:0] tile_gc;
    logic                                       tile_first;
    logic                                       tile_last;
    logic [BATCH_TOK_W-1:0]                     tile_tok;
    logic [BATCH_TOK_W-1:0]                     batch_n;
    gemm_stream_mode_e                          stream_mode;
    logic load_req;
    logic load_busy;
    logic load_done;
    logic                                  w_we;
    logic                                  w_phys_gc;
    logic [$clog2(DENSE_PE_PER_GROUP)-1:0] w_pe_addr;
    bfp12_mant_t [(BFP12_BLK/2)-1:0]       w_in;

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
    a_scan_within_load: assert property (
        @(posedge clk) disable iff (!rst_n) w_we |-> load_busy
    ) else $error("dense_sched_if: w_we asserted outside a weight-load (load_busy=0)");
`endif

endinterface : dense_sched_if
interface tlmm_issue_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;

    logic                   start;
    logic [MACRO_CNT_W-1:0] k_cnt;
    logic                   busy;
    logic                   done;

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
interface csd_dram_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;
    logic [DRAM_ADDR_W-1:0] req_addr;
    logic [DRAM_LEN_W-1:0]  req_len;
    logic                   req_valid;
    logic                   req_ready;
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
    a_req_nonzero_len: assert property (
        @(posedge clk) disable iff (!rst_n) (req_valid && req_ready) |-> (req_len != '0)
    ) else $error("csd_dram_if: accepted request with req_len=0");
`endif

endinterface : csd_dram_if
interface csd_dram_wr_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;
    logic [DRAM_ADDR_W-1:0] req_addr;
    logic [DRAM_LEN_W-1:0]  req_len;
    logic                   req_valid;
    logic                   req_ready;
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
interface kv_access_if (
    input  wire logic clk,
    input  wire logic rst_n
);
    import types_pkg::*;
    logic [KV_ADDR_W-1:0] wr_addr;
    logic [KV_DATA_W-1:0] wr_data;
    logic                 wr_en;
    logic [KV_ADDR_W-1:0] rd_addr;
    logic                 rd_en;
    logic [KV_DATA_W-1:0] rd_data;
    logic                 rd_valid;

    modport master (output wr_addr, wr_data, wr_en, rd_addr, rd_en,
                    input  rd_data, rd_valid);
    modport slave  (input  wr_addr, wr_data, wr_en, rd_addr, rd_en,
                    output rd_data, rd_valid);
    modport mon    (input  wr_addr, wr_data, wr_en, rd_addr, rd_en, rd_data, rd_valid);

`ifndef SYNTHESIS
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
`endif
