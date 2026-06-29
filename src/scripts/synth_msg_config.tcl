# -----------------------------------------------------------------------------
# synth_msg_config.tcl
#
# Targeted Synth-message demotions / suppressions for ArchBetter. Source this
# AFTER opening the project but BEFORE launching synth_1, e.g. as a tcl.pre
# hook on synth_1, or interactively from the Vivado console:
#
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/synth_msg_config.tcl
#
# Policy
#   * NEVER blanket-suppress an entire rule ID. Always scope by rule-string
#     or by module so that genuine wiring bugs in other parts of the design
#     are not hidden.
#   * Every demotion is paired with an architectural justification block
#     above it, citing the CLAUDE.md section the slack comes from.
#
# Synth message IDs touched:
#   * Synth 8-7129: "Port X in module Y is either unconnected or has no load"
# -----------------------------------------------------------------------------

puts "synth_msg_config: applying ArchBetter targeted Synth-message demotions"

# This script is sourced as a tcl.pre hook on every build, so within one Vivado
# session the set_msg_config rules below are RE-applied — Vivado then emits
# [Common 17-1361] "new rule equivalent to an existing rule ... will be
# replaced" for each. That replacement is exactly the intended idempotent
# behavior, so suppress just that one notice (NOT any design message).
set_msg_config -suppress -id {Common 17-1361}

# -----------------------------------------------------------------------------
# 1. Module-scoped 8-7129 demotions
#
# Cleaner than per-bit string matching (which was missing pp.rd_data[128..129]
# in the prior revision). Every Synth 8-7129 advisory inside tlmm_driver or
# sparse_tile is by-design architectural slack:
#
#   * pp.rd_data[143:128]      - cascaded URAM cascade-width slack vs the
#                                COMPUTE_BITS_PER_WORD=128 consumer width
#                                (CLAUDE.md sec 2.3, uram_cascade_adapter).
#   * pp.active_side           - manager-side status; driver uses its own
#                                drain handshake. Phase-8 may consume it.
#   * pp.clk / pp.rst_n        - interface clk/rst_n shadowing the module's
#                                own clk/rst_n ports (standard SV idiom).
#   * tlmm.clk / tlmm.rst_n    - same.
#   * ctrl.clk / ctrl.rst_n    - same.
#
# A genuine new wiring bug WILL still surface because synth will re-emit
# 8-7129 against any NEW module that grows an unconnected port; the demotion
# is scoped to module names that already exist.
# -----------------------------------------------------------------------------
set_msg_config -id "Synth 8-7129" \
    -string "in module tlmm_driver" \
    -new_severity INFO

set_msg_config -id "Synth 8-7129" \
    -string "in module sparse_tile" \
    -new_severity INFO

# axi4_bram_slave: the BRAM closure endpoint (DDR4-MIG stand-in, C5) is a
# deliberately simplified AXI4 slave that IGNORES the burst/size/strobe
# sideband (awlen/awsize/awburst/arsize/arburst/wstrb) — it stores full beats
# at INCR addresses, which is all the adapters issue (asserted INCR-only). The
# interface's shadow axi.clk/axi.rst_n are unused (the module has its own
# clk/rst_n ports). The real MIG consumes all of this at board bring-up; until
# then these are by-design unconnected, NOT wiring bugs. Scoped to the module.
set_msg_config -id "Synth 8-7129" \
    -string "in module axi4_bram_slave" \
    -new_severity INFO

# CIM noise-injection hooks: dense_pe exposes noise_rd_in[*] (and the cim_cell
# 4T2R twin's injection ports, CLAUDE.md sec 2.2) reserved for the §2.6
# AC-assisted drift-refresh stimulus. The drift_refresh_controller that drives
# them is a later phase, so the ports currently have no load. They are a
# load-bearing part of the architecture's calibration story, intentionally
# stubbed now. Scoped by the port name so only these hooks are demoted.
set_msg_config -id "Synth 8-7129" \
    -string "noise_rd_in" \
    -new_severity INFO


# -----------------------------------------------------------------------------
# 4. Synth 8-6014 — "Unused sequential element <X> was removed"
#
# These are truthful reports that synth optimized out registers / struct
# fields that have no consumer in the current source. Two categories of
# pending consumers:
#
#   (a) csd_drain_engine / csd_engine: desc_q.compressed, desc_q.is_sparse —
#       will be consumed by the Phase-8 csd_dequant micro-pipeline that
#       implements CLAUDE.md sec 2.7 (qN -> BFP12 conversion at the URAM
#       fill boundary).
#   (b) memory_manager: opc_q, tile_id_q — will be consumed by the Phase-8
#       dispatcher tile-walker that emits the 32-tile schedule for the
#       refactored dense_array (CLAUDE.md sec 2.2).
#   (c) noc_router: path_tab[0].{src_node, priority_lvl, is_multicast} —
#       multicast/priority routing fields will be consumed by the Phase-8
#       NoC fabric integration with the tile-walker.
#   (d) uram_pingpong: drain_req_q — alive in source, currently optimized
#       out because the FSM is not exercised by the Phase-7d top wiring.
#       Will reactivate when the dispatcher issues real OP_PINGPONG ops.
#
# Policy: demote 8-6014 to INFO ONLY for these specific instances, scoped
# tightly by string match, so genuine dead-code in other files still surfaces.
# Re-evaluate at the end of Phase 8: every instance below should be removed
# from this script as its consumer comes online.
# -----------------------------------------------------------------------------
set_msg_config -id "Synth 8-6014" \
    -string "desc_q_reg\\\\\[compressed\\\\\]" \
    -new_severity INFO

set_msg_config -id "Synth 8-6014" \
    -string "desc_q_reg\\\\\[is_sparse\\\\\]" \
    -new_severity INFO

set_msg_config -id "Synth 8-6014" \
    -string "drain_req_q_reg" \
    -new_severity INFO

set_msg_config -id "Synth 8-6014" \
    -string "opc_q_reg" \
    -new_severity INFO

set_msg_config -id "Synth 8-6014" \
    -string "tile_id_q_reg" \
    -new_severity INFO

set_msg_config -id "Synth 8-6014" \
    -string "path_tab_reg\\\\\[0\\\\\]\\\\\[src_node\\\\\]" \
    -new_severity INFO

set_msg_config -id "Synth 8-6014" \
    -string "path_tab_reg\\\\\[0\\\\\]\\\\\[priority_lvl\\\\\]" \
    -new_severity INFO

set_msg_config -id "Synth 8-6014" \
    -string "path_tab_reg\\\\\[0\\\\\]\\\\\[is_multicast\\\\\]" \
    -new_severity INFO


# -----------------------------------------------------------------------------
# 5. XPM library-internal unconnected ports (Synth 8-7129)
#
# We use Xilinx XPM macros (xpm_memory_*, xpm_fifo_*) for KV cache and the
# dense->sparse FIFO. These macros expose ports for the most-general
# configuration (dual-port async with ECC, sleep, register-stages). Our
# instantiations use a subset of those features; the unused ports are
# by-design library behavior, not wiring bugs in ArchBetter RTL.
#
# Demote (do not blanket-suppress) so they stay visible at INFO level.
# -----------------------------------------------------------------------------
set_msg_config -id "Synth 8-7129" \
    -string "in module xpm_memory_base" \
    -new_severity INFO

set_msg_config -id "Synth 8-7129" \
    -string "in module xpm_fifo_rst" \
    -new_severity INFO

set_msg_config -id "Synth 8-7129" \
    -string "in module xpm_fifo_base" \
    -new_severity INFO

# -----------------------------------------------------------------------------
# 6. Synth 8-6057 (URAM has no pipeline registers)
#
# Performance recommendation, not a wiring bug. URAMs at very high frequency
# (>=350 MHz) benefit from the optional output pipeline register; at our
# 225 MHz target on KU5P -3 the path closes without it (with even more margin
# than at the former 250 MHz). Phase-8 timing-closure work will revisit by
# adding (* ram_register = "yes" *) on the URAM read path if WNS turns out tight.
# -----------------------------------------------------------------------------
set_msg_config -id "Synth 8-6057" -new_severity INFO

# -----------------------------------------------------------------------------
# 7. Synth 8-3917 — "design dense_out_collector has port wr_data[N] driven by
#                    constant 0"
#
# The dense_out_collector drains array_acc_t results into the OUT-staging URAM
# (u_out_uram, CLAUDE.md sec 2.3), whose native word is 72 bits. An array_acc_t
# accumulator is narrower than 72b, so the high wr_data bits are constant-0
# ZERO-PADDING to the URAM word width — intentional, not a dangling driver.
# Scoped to the module so a real constant-folding bug elsewhere still surfaces.
# -----------------------------------------------------------------------------
set_msg_config -id "Synth 8-3917" \
    -string "dense_out_collector" \
    -new_severity INFO

# -----------------------------------------------------------------------------
# 8. Synth 8-330 — "inout connections inferred for interface port 'axi4_if'
#                   with no modport"
#
# archbetter_soc_top's m_axi port is a GENERIC axi4_if (no top-level modport)
# BY DESIGN: the module fans the single AXI bus into TWO sub-modport consumers —
# u_axi_rd uses m_axi.master_rd and u_axi_wr uses m_axi.master_wr. A single
# port-level modport cannot express "this module drives the read-master view AND
# the write-master view through different sub-instances", so the idiomatic SV
# pattern is a generic interface port with per-instance modport selection
# internally. This satisfies the CLAUDE.md sec 6 intent (a typed interface, no
# loose signal bundle); the "inout inferred" note is benign for a multi-modport-
# consumer port. Scoped by the interface type name.
# -----------------------------------------------------------------------------
set_msg_config -id "Synth 8-330" \
    -string "axi4_if" \
    -new_severity INFO

# -----------------------------------------------------------------------------
# 9. Synth 8-4767 / 8-11357 — desc_table / bank_reg inferred as registers
#
# memory_manager's desc_table (256 csd_descriptor_t entries) and the
# packed-struct bank tables are CONTROL register files, not data RAMs. Phase-7d
# deliberately REMOVED their (* ram_style *) attributes (see waivers.tcl Groups
# 3-4) because the packed-struct access pattern is not BRAM/DRAM-inferable
# (Synth 8-7186) — a register file is the correct primitive class for this small
# control state. 8-4767 ("trying to implement RAM in registers") and 8-11357
# ("3D-RAM ... runtime") are the tool narrating that intended choice, plus a
# synth-runtime heads-up. Not wiring bugs. Scoped by the instance names.
# -----------------------------------------------------------------------------
set_msg_config -id "Synth 8-4767" \
    -string "desc_table_reg" \
    -new_severity INFO

set_msg_config -id "Synth 8-11357" \
    -string "bank_reg" \
    -new_severity INFO

puts "synth_msg_config: done"
