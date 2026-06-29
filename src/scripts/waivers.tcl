# -----------------------------------------------------------------------------
# waivers.tcl
#
# Methodology / DRC waivers for ArchBetter. CLAUDE.md §5 mandates that any
# non-critical advisory we choose not to fix must be waived here with a
# written justification — that is what every block below provides.
#
# When to source:
#   * after synth_design has populated the netlist (cells exist), and
#   * before report_methodology / report_drc are written into reports/.
# Sourcing is idempotent: re-sourcing replaces any prior waivers with the
# same ID + object set.
#
# Usage from the Vivado Tcl console:
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/waivers.tcl
#
# Optional integration: register this script as a tcl.post hook on synth_1
# so re-running synth automatically applies waivers before reports are read.
# That hook lives in build.tcl, not here.
# -----------------------------------------------------------------------------

puts "waivers.tcl: applying ArchBetter methodology waivers"

# -----------------------------------------------------------------------------
# _ab_waive — guarded create_waiver, ONE waiver per rule ID.
#
# Two failure modes this guards against:
#   1. Empty -objects ([Vivado_Tcl 4-939] abort) — happens when a cell-name
#      filter goes stale after an RTL refactor (post-synth primitive names
#      drift: a LUTRAM `mem` becomes RAMD32/RAMD64, not `*mem_reg*`), or when
#      a sub-core is pruned in an OOC harness (the sparse tile disappears at
#      impl). A stale/pruned filter must NOT abort the run — warn and skip.
#   2. Duplicate rule ID ([Vivado_Tcl 4-935]) — Vivado dedupes waivers by rule
#      ID, so two separate create_waiver calls with the same -id (e.g. RRRS-1
#      for KV *and* for dispatcher imem) collapse, silently leaving the second
#      group's cells un-waived. Fix: accumulate the UNION of all cell groups
#      for a rule ID and emit exactly ONE create_waiver.
#
# `filters` is a Tcl list of per-group -filter expressions. They are OR-joined
# into a SINGLE get_cells call so the result is one live cell COLLECTION, not a
# Tcl list of name strings — create_waiver -objects requires real objects, and
# accumulating via `lappend` silently degrades them to strings (-> 4-939 "object
# list should not be empty" even when cells exist). The OR-join also makes a
# pruned/stale group harmless: it simply contributes nothing to the union.
# Per-group architectural justification lives in the comments above each call;
# `description` is the single consolidated waiver string.
# -----------------------------------------------------------------------------
proc _ab_waive {type id description filters} {
    set expr [join $filters " || "]
    set objs [get_cells -hier -quiet -filter $expr]
    if {[llength $objs] == 0} {
        puts "waivers.tcl: WARNING — $id: no cells matched {$expr}; skipping waiver (all groups stale or pruned)."
        return
    }
    create_waiver -type $type -id $id \
        -description $description \
        -objects $objs \
        -user "ArchBetter"
    puts "waivers.tcl: $id waiver applied to [llength $objs] cell(s)."
}

# -----------------------------------------------------------------------------
# RRRS-1 — Advisory: "Found user attribute ram_style"
#
# Every flagged instance has an architecturally mandated ram_style attribute.
# Removing the attributes is not an option: they are the contract that pins
# inference to the correct primitive class on XCKU5P. CLAUDE.md sections that
# justify each grouping are cited inline.
# -----------------------------------------------------------------------------

# Group 1 — TLMM ternary lookup tables (sparse_core).
# CLAUDE.md §2.2: "weights are stored in LUTRAM / SRL primitives". Forcing
# distributed inference is what makes the sparse core 0-DSP and BRAM-free.
# Cells: u_sparse_tile/gen_lane[*].gen_sub[*].mem (16 lanes x 4 sub = 64 mems).
# Post-synth these infer as RAM32M16 / RAM64M8 / RAM256X1D distributed-RAM
# primitives (verified 2026-06-13: Unisim summary shows 0 BRAM in u_sparse_tile,
# all 74 BRAMs live in u_memmgr/u_kv). The leaf name is therefore NOT `mem_reg`
# — match the per-(lane,sub) generate path + the `mem` array base instead.
# NOTE: in the current OOC harness the sparse core has no live datapath and is
# pruned at impl, so this filter matches at synth but not impl — _ab_waive
# warn-skips that group rather than aborting.

# Group 2 — KV cache (memory_manager/kv_bram).
# CLAUDE.md §2.3: "KV cache - Managed by Global BRAM (not URAM)". The
# ram_style="block" attribute pins the BRAM mapping and keeps URAMs reserved
# for weights/activations.

# Group 3 — DELETED in Phase 7d.
# memory_manager/desc_table previously carried (* ram_style = "distributed" *)
# but Vivado was ignoring the attribute (Synth 8-7186) because the packed-struct
# access pattern is not LUTRAM-inferable. The attribute is now removed from the
# RTL; the table synthesizes as a register file, which is the right primitive
# class for 256 entries of control state. No waiver needed.

# Group 4 — DELETED in Phase 7d.
# noc_router/path_tab previously carried (* ram_style = "distributed" *) but
# Vivado was ignoring the attribute (Synth 8-7186) — same packed-struct access
# pattern as memory_manager/desc_table. Attribute removed; the table is a
# register file (right primitive class for 32-entry control state). No waiver.

# Group 5 — Dispatcher instruction memory (macro-ISA).
# Small program store; using a BRAM here would idle most of a 36k tile.

# Single consolidated RRRS-1 waiver (union of Groups 1, 2, 5). One create_waiver
# per rule ID — see _ab_waive header for why separate calls collapse (4-935).
_ab_waive METHODOLOGY {RRRS-1} \
    {Architecturally-mandated ram_style attributes (CLAUDE.md sec 2.2/2.3): TLMM sparse lookup tables pinned to LUTRAM (distributed, 0-DSP/0-BRAM sparse core); KV cache pinned to BRAM (block) keeping URAM reserved for the ping-pong weight/activation store; dispatcher imem distributed to avoid dedicating a 36k BRAM tile to a sub-BRAM-depth program store. Removing any of these attributes would mis-map the primitive class and invalidate the device resource budget.} \
    [list \
        {NAME =~ *u_sparse_tile*mem*} \
        {NAME =~ *u_kv/mem_reg*} \
        {NAME =~ *u_dispatcher/imem_reg*} \
    ]

# -----------------------------------------------------------------------------
# RFFH-1 — Advisory: "register driving a high fanout, consider replicating".
#
# Flagged objects (Phase-7d hierarchy):
#   * u_array/gen_pg[*].u_gp/g_row[*].g_col[*].u_pe/acc_out_valid_q_reg
#   * u_array/gen_pg[*].u_gp/y_valid_q_reg
#
# Why this is a structural false positive (not a missing fix):
#   The dense array is logical 128x128, physical 16x32 — two dense_group
#   instances (gen_pg[0..1], each 16x16 PEs) time-multiplexed over the 8x4
#   logical tile grid (CLAUDE.md sec 2.2). Each PE's acc_out_valid_q has
#   exactly one routed consumer (the enclosing group's snap latch); each
#   group's y_valid_q has exactly one routed consumer (the array snap
#   collector). Per-instance fanout is bounded O(1) by the generate geometry,
#   NOT by the replication count. Vivado's elab-time fanout estimate sums
#   across replicated generate instances and over-counts; the routed design
#   is fine.
#
# We previously tried a `(* max_fanout = "32" *)` decoration. That cleared
# RFFH-1 but immediately summoned RAMF-1 ("MAX_FANOUT might increase
# utilization") on every replicated instance — a contradictory advisory
# pair where the attribute fix has measurable area cost without solving a
# real fanout problem. The attribute has been removed; the structural
# argument above is the binding justification.
#
# Re-evaluate after Phase-8 place-and-route: if report_timing flags any
# acc_out_valid / y_valid net as a real fanout-driven setup violation,
# REMOVE this waiver and add a targeted MAX_FANOUT only on the offending
# net via XDC, not via an RTL-wide attribute.
# -----------------------------------------------------------------------------
# Single consolidated RFFH-1 waiver (union of PE acc_out_valid_q + group
# y_valid_q). One create_waiver per rule ID (see _ab_waive header re 4-935).
_ab_waive METHODOLOGY {RFFH-1} \
    {Per-instance fanout of acc_out_valid_q (PE, instance u_pe) and y_valid_q (dense_group, instance u_gp) is structurally bounded O(1) by the physical 16x32 (two 16x16 dense_group) generate geometry (CLAUDE.md sec 2.2): each PE acc_out_valid_q drives exactly one group snap latch, each group y_valid_q drives exactly one array snap collector. The elab-time advisory over-counts across replicated generate instances; the routed design has one consumer per source. Re-evaluate at Phase-8 P&R; if a real fanout-driven setup violation appears, replace this waiver with a targeted XDC MAX_FANOUT on the offending net.} \
    [list \
        {NAME =~ *u_pe/acc_out_valid_q_reg*} \
        {NAME =~ *u_gp/y_valid_q_reg*} \
    ]

# -----------------------------------------------------------------------------
# LUTAR-1 — Advisory: "LUT drives the asynchronous Set/Reset of N registers;
#                       a glitch on the LUT could cause an unintended reset."
#
# Flagged objects (C5 non-OOC closure):
#   * u_soc/u_rst_sync   (xpm_cdc_async_rst — compute-domain reset)
#   * u_slave_rst        (xpm_cdc_async_rst — BRAM-slave reset)
#
# Why this is the methodology-SANCTIONED structure, not a defect:
#   Both nets are `arst = ~ext_rst_n | ~locked` — the canonical "assert reset
#   while the board reset is held OR the MMCM is unlocked" combine. It feeds the
#   async-assert input (src_arst) of an xpm_cdc_async_rst macro, which is EXACTLY
#   the Xilinx-recommended primitive for this job (CLAUDE.md sec 6: "CDC: XPM
#   only"). The macro asynchronously ASSERTS and synchronously DE-ASSERTS reset.
#   A glitch on the 2-input reset OR can only (re-)assert reset for an instant
#   while the system is already held in reset (board reset low and/or MMCM
#   unlocked) — it can never corrupt running state, because the de-assert edge
#   is what the XPM synchronizes. There is also NO stable clock to register the
#   combine on during the unlocked window, so a registered-reset rewrite is both
#   unsafe (loses async assertion) and impossible (no clock). The LUT on the
#   async path is intrinsic to every multi-source reset feeding an XPM async
#   reset; this is a textbook waivable LUTAR-1.
#
# Re-evaluate at board bring-up: when a real PоR / external reset controller and
# board pinout land, confirm the reset source remains a clean, low-toggle combine
# (it will) and keep this waiver, or replace with a dedicated reset primitive.
# -----------------------------------------------------------------------------
# NOTE on -objects: a methodology waiver must target the LEAF primitives that
# carry the violation (the synchronizer FDPE/FDCE flops whose async PRE/CLR the
# reset LUT drives), NOT the hierarchical xpm_cdc_async_rst instance — passing
# the hierarchical cell triggers [Vivado_Tcl 4-2057] "likely unusable
# hierarchical instance" and the waiver may not bind. `IS_PRIMITIVE` restricts
# the collection to leaf cells inside each macro.
_ab_waive METHODOLOGY {LUTAR-1} \
    {Reset-combine LUT (~ext_rst_n | ~locked) drives the async-assert input of an xpm_cdc_async_rst macro (u_soc/u_rst_sync, u_slave_rst) — the Xilinx-sanctioned CDC reset primitive (CLAUDE.md sec 6, XPM-only). The XPM asynchronously asserts and SYNCHRONOUSLY de-asserts; a glitch on the 2-input reset OR can only momentarily re-assert reset while the system is already held in reset (board reset low or MMCM unlocked), never corrupting running state. No stable clock exists during the unlocked window to register the combine on, so a registered-reset rewrite is both unsafe and impossible. Intrinsic, benign LUTAR-1 on a multi-source XPM reset.} \
    [list \
        {IS_PRIMITIVE && NAME =~ *u_rst_sync*} \
        {IS_PRIMITIVE && NAME =~ *u_slave_rst*} \
    ]

# -----------------------------------------------------------------------------
# SYNTH-6 — Advisory: "The timing for instance <mem_reg_bram_N>, implemented as
#                      a RAM block, might be sub-optimal as no output register
#                      was merged into the block."
#
# Flagged instances (C5 non-OOC closure): mem_reg_bram_{6,7,15,23,31,39,47,55,63}
# — the BRAM primitives of the KV cache (u_kv) and the BRAM AXI closure endpoint
# (u_mem).
#
# Why this is INTENTIONAL, not a missing fix:
#   kv_bram.sv AND axi4_bram_slave.sv BOTH already implement the 2-stage
#   latch+OREG read pattern (rd_data_q -> rd_data_q2) specifically so Vivado can
#   merge the OREG into the RAMB. It normally would. It CANNOT here because
#   `(* DONT_TOUCH = "yes" *)` is applied to u_core and u_mem (archbetter_*_top)
#   — the fix that prevents unobservability dead-code elimination from deleting
#   the whole accelerator (the "hollow shell" bug, project memory). dont_touch
#   forbids register absorption, so the OREG flop cannot fold into the RAMB and
#   SYNTH-6 fires. This is a DELIBERATE trade: structural retention of the real
#   datapath (512 DSP, real BRAMs, honest power/area) in exchange for an
#   un-merged BRAM->fabric hop. The hop cost is absorbed by the 225 MHz target
#   (dropped from 250 for >=10% slack; see archbetter_soc_top g_mmcm). When a
#   real DDR4 MIG drives observable pins at board bring-up, dont_touch is
#   removed, the OREG merges, and this waiver is deleted.
# -----------------------------------------------------------------------------
_ab_waive METHODOLOGY {SYNTH-6} \
    {KV-cache (u_kv) and BRAM closure-endpoint (u_mem) RAMB primitives report no merged output register. The OREG is present in RTL (kv_bram.sv / axi4_bram_slave.sv 2-stage latch+OREG read) but cannot fold into the RAMB because (* DONT_TOUCH *) on u_core/u_mem forbids register absorption — the deliberate fix preventing unobservability DCE from deleting the accelerator (hollow-shell bug). Intentional trade: structural retention of the real datapath vs an un-merged BRAM->fabric hop, absorbed by the 225 MHz target. Removed when a real MIG drives observable pins and dont_touch is lifted.} \
    [list \
        {NAME =~ *mem_reg_bram_*} \
    ]

# -----------------------------------------------------------------------------
# TIMING-28 (METHODOLOGY) — "Auto-derived clock referenced by a timing
#                            constraint."
#
# Flagged object (C5 non-OOC closure): the MMCM-generated compute clock
# g_mmcm.clkout0, referenced by the set_clock_uncertainty -setup guard band in
# timing_portable.xdc.
#
# Why this is the ACCEPTED structure, not a fixable defect here:
#   The 0.400 ns setup guard band MUST attach to the compute clock (it is the
#   only domain the dense fabric runs in) and that clock is AUTO-DERIVED by
#   Vivado from MMCME4_ADV/CLKOUT0 — by design (CLAUDE.md sec 11 timing note: do
#   NOT hand-write create_generated_clock for the MMCM output; that risks
#   double-constraining the macro and mis-stating the M/D/O divide). AMD's
#   recommended TIMING-28 resolution (promote the clock to a user clock via
#   create_generated_clock) is exactly the move that directive forbids. The
#   alternative — dropping the guard band — loses the proven timing fix (the
#   acc_clr / imem paths need it for >=10%-class headroom; see timing_portable
#   .xdc rationale). So the constraint legitimately references the auto-derived
#   clock and TIMING-28 is waived rather than fixed. The reference is robust: the
#   MMCM config is fixed, CLKOUT0 always auto-names *clkout0, and a missed match
#   would surface immediately as a WNS regression, not silently.
#
# Re-evaluate at board bring-up: if a board clocking wizard / explicit named
# generated clock is introduced for the MIG, point the guard band at that named
# clock and DELETE this waiver.
# -----------------------------------------------------------------------------
set _t28_clk [get_clocks -quiet -filter {NAME =~ *clkout0}]
if {[llength $_t28_clk] > 0} {
    create_waiver -type METHODOLOGY -id {TIMING-28} \
        -description {set_clock_uncertainty -setup guard band (timing_portable.xdc) intentionally references the MMCM auto-derived compute clock g_mmcm.clkout0. The clock is auto-derived by design (CLAUDE.md sec 11: no hand-written create_generated_clock for the MMCM output, to avoid double-constraining the macro); AMD's recommended TIMING-28 fix (promote to a user clock) is precisely that forbidden move, and dropping the guard band loses the proven setup-timing fix. Robust reference (fixed MMCM config; a missed match would show as a WNS regression). Removed when a board clocking wizard introduces a named generated clock.} \
        -objects $_t28_clk -user "ArchBetter"
    puts "waivers.tcl: TIMING-28 waiver applied to [llength $_t28_clk] clock(s)."
} else {
    puts "waivers.tcl: WARNING — TIMING-28: no *clkout0 clock matched; skipping (MMCM clock name drifted?)."
}

# -----------------------------------------------------------------------------
# RTSTAT-10 (DRC) — "No routable loads": N net(s) have no routable loads.
#
# Two by-design categories in the C5 non-OOC closure, both waived here:
#
#   (a) Unused AXI4 sideband on the memory seam — u_mem/axi.bid[*],
#       u_mem/axi.rdata[high bits beyond the consumer width],
#       u_axi_wr/axi.awlen/awsize/awburst/wstrb, u_axi_rd sideband. The BRAM
#       closure endpoint (axi4_bram_slave, DDR4-MIG stand-in) is a deliberately
#       simplified INCR-only AXI4 slave: it ignores burst/size/strobe and drives
#       only the response bits it needs, so master-driven sideband and unused
#       response bits terminate with no load. The real DDR4 MIG consumes the full
#       sideband at board bring-up.
#
#   (b) DARK-FEATURE outputs the single-dense-layer closure harness does not
#       exercise (project memory: "integration TBs are single-tile; full
#       KV-attention + sparse-FFN orchestration is Phase-8-pending"):
#         * u_memmgr/u_kv/kv_rd_data_o[*], kv_rd_valid_o — KV read-back path,
#           live only when attention reads the cache (not in a dense-GEMM layer).
#         * u_dispatcher/kv_wr_addr_r[high bits] — KV write-address headroom bits
#           above the exercised depth.
#         * u_d2s_fifo/d2s_valid_o, .../doutb[*] — dense->sparse FIFO output,
#           live only when the sparse FFN core consumes it.
#         * u_memmgr/u_drain/dram_wr_wd_last — drain last-beat flag unused on the
#           closure write path.
#         * u_loader/base_{da,dw,tl}_q_reg[high], desc_wr_data[*], imem_wr_data
#           [spare] — loader descriptor / imem field-width headroom bits.
#         * u_sparse_collector/sparse_out_wr_addr[*], sparse_out_wr_data[*] — the
#           sparse-FFN result collector write port, live only when the TLMM sparse
#           core runs (never in a dense-GEMM-only closure layer).
#       Every one of these becomes a real load in the full multi-layer workload;
#       they are dark ONLY because the closure harness runs one dense layer.
#
# Both categories are harmless for closure (did not block the bitstream). The
# filter is enumerated per-hierarchy (NOT a blanket no-load waiver) so a genuine
# no-load net anywhere else in the design still surfaces as RTSTAT-10.
#
# DRC waivers target NETS (not cells), so this is a direct create_waiver, not the
# cell-oriented _ab_waive helper. ONE waiver per rule ID (union of both groups).
# -----------------------------------------------------------------------------
set _rtstat_nets [get_nets -quiet -hier -filter \
    {NAME =~ *u_mem/axi* || NAME =~ *u_axi_wr/axi* || NAME =~ *u_axi_rd/axi* || \
     NAME =~ *u_memmgr/u_kv/kv_rd_data* || NAME =~ *u_memmgr/u_kv/kv_rd_valid* || \
     NAME =~ *u_dispatcher/kv_wr_addr* || \
     NAME =~ *u_d2s_fifo/d2s_valid_o* || NAME =~ *u_d2s_fifo*doutb* || \
     NAME =~ *u_memmgr/u_drain/dram_wr_wd_last* || \
     NAME =~ *u_loader/base_da_q_reg* || NAME =~ *u_loader/base_dw_q_reg* || \
     NAME =~ *u_loader/base_tl_q_reg* || NAME =~ *u_loader/desc_wr_data* || \
     NAME =~ *u_loader/imem_wr_data* || \
     NAME =~ *u_sparse_collector/sparse_out_wr_addr* || \
     NAME =~ *u_sparse_collector/sparse_out_wr_data*}]
if {[llength $_rtstat_nets] > 0} {
    create_waiver -type DRC -id {RTSTAT-10} \
        -description {No-routable-load nets in the C5 non-OOC closure, two by-design categories: (a) unused AXI4 sideband on the memory seam (u_mem/axi.bid, rdata high bits, u_axi_wr/u_axi_rd awlen/awsize/awburst/wstrb) — the axi4_bram_slave DDR4-MIG stand-in is a simplified INCR-only endpoint that ignores burst/size/strobe; (b) dark-feature outputs the single-dense-layer closure harness does not drive (u_kv kv_rd_data/kv_rd_valid KV read-back, u_dispatcher kv_wr_addr headroom bits, u_d2s_fifo d2s_valid_o/doutb dense->sparse FIFO output, u_drain dram_wr_wd_last, u_loader descriptor/imem field-width spares, u_sparse_collector sparse_out_wr_addr/data sparse-FFN result write port). All become real loads in the full multi-layer / KV-attention / sparse-FFN workload (project: integration TBs are single-tile, full orchestration Phase-8-pending). Enumerated per-hierarchy, not a blanket no-load waiver. Did not block bitstream.} \
        -objects $_rtstat_nets -user "ArchBetter"
    puts "waivers.tcl: RTSTAT-10 waiver applied to [llength $_rtstat_nets] net(s)."
} else {
    puts "waivers.tcl: WARNING — RTSTAT-10: no seam/dark-feature nets matched; skipping (names drifted?)."
}

puts "waivers.tcl: done. [llength [get_waivers]] waiver(s) currently active."
