# =============================================================================
# timing.xdc  -  ArchBetter Phase-7c timing constraints
#
# Scope:
#   * primary clock(s)
#   * host-side I/O delays against a virtual host clock
#   * false paths on static-config ports (host loads these once before start)
#   * async reset isolation
#
# Out of scope (split into pins.xdc):
#   * PACKAGE_PIN / IOSTANDARD / SLEW / DRIVE
#
# Quality contract (CLAUDE.md sec 8): the synth+impl flow must close timing
# with at least 10% WNS slack at the chosen target frequency. Pick conservative
# numbers here so closure is not blocked by an unrealistic constraint, then
# tighten once the design is routed.
# =============================================================================

# -----------------------------------------------------------------------------
# Target frequency
#
# 250 MHz (4.000 ns) is the Phase-7 starting point for the compute domain on
# xcku5p-ffvd900-3-e. Rationale:
#   * KU5P -3 grade easily clears 300 MHz on logic-only paths; we leave margin
#     for the deep BFP12 mantissa MAC cascades and the 16-input column tree.
#   * 250 MHz keeps DSP48E2 inference inside the natively-supported
#     register-A/B + P-register pattern with no extra cascade pipelining.
#   * Phase-8 retiming may relax this upward; do not chase MHz before WNS
#     slack and methodology cleanliness are both green.
#
# The design currently has a single clock port (top.clk). The future memory
# clock is sketched below for when the URAM/DRAM split lands; do not enable
# it until the RTL exposes a second clock pin.
# -----------------------------------------------------------------------------

create_clock -name clk_compute -period 4.000 -waveform {0.000 2.000} \
    [get_ports clk]

# Future memory clock (do not uncomment until top exposes mem_clk):
#   create_clock -name clk_mem -period 5.000 -waveform {0.000 2.500} \
#       [get_ports mem_clk]
#   set_clock_groups -asynchronous \
#       -group [get_clocks clk_compute] \
#       -group [get_clocks clk_mem]

# -----------------------------------------------------------------------------
# Virtual host clock for off-chip I/O
#
# We do not yet have a real host-side launch clock pin. Use a same-period
# virtual clock so input/output delays are quantitative rather than handwaved;
# Phase-8 can relate this to a real PHY clock when the host integration lands.
# -----------------------------------------------------------------------------

create_clock -name virt_host -period 4.000

# -----------------------------------------------------------------------------
# Top-robust port references
#
# This file is shared by two synthesis tops: archbetter_core (the closed Phase-8
# SoC, the default synth target) and archbetter_top (the open Phase-7 sim
# harness). They have DIFFERENT port sets — core drops the host weight-scan /
# tile-schedule ports and adds dense_weight_base_addr + sparse_out_*.
#
# IMPORTANT: an XDC is read by a RESTRICTED Tcl interpreter — `proc`, `if`,
# `foreach`, and user-defined commands are NOT allowed ([Designutils 20-1307]).
# To make one constraint set work for both tops we therefore pass the UNION of
# candidate port patterns directly to `get_ports -quiet`, which silently drops
# any pattern that does not match a port on the ACTIVE top (no critical warning)
# and returns only the ports that exist. No control flow, no helper procs.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Static-config ports (host writes once, then asserts start)
#
# By dispatcher contract these ports are quiet during execution:
#   * imem_we, imem_wr_addr, imem_wr_data : program load
#   * desc_we, desc_wr_addr, desc_wr_data : descriptor table
#   * w_we, w_gr, w_gc, w_pe_addr, w_in   : dense weight scan (archbetter_top
#                                           ONLY; archbetter_core internalizes
#                                           this via dense_weight_streamer)
#
# Constraining these as timed paths would force pessimistic placement of the
# weight-scan distribution for no benefit (no setup/hold concern when the path
# is idle). False-path them; the dispatcher's `start` rising edge is the real
# launch event and is constrained below. -quiet drops the top-only w_* patterns
# on archbetter_core.
# -----------------------------------------------------------------------------

set_false_path -from [get_ports -quiet {imem_we imem_wr_addr[*] imem_wr_data[*] \
                                         desc_we desc_wr_addr[*] desc_wr_data[*] \
                                         w_we w_gr[*] w_gc[*] w_pe_addr[*] w_in[*]}]

# -----------------------------------------------------------------------------
# Async reset
#
# rst_n is the SoC reset pin. The RTL applies it synchronously inside every
# always_ff (CLAUDE.md sec 6), but the pin itself is asynchronous to clk; the
# de-assertion edge is what matters and that is timed via a downstream
# synchronizer (XPM) or by ensuring rst_n is held long enough by the host.
# -----------------------------------------------------------------------------

set_false_path -from [get_ports rst_n]

# -----------------------------------------------------------------------------
# Runtime input delays  (host -> FPGA, captured in clk_compute)
#
# Conservative values for a notional 250 MHz host launch:
#   max = 2.0 ns  -> ~ 50% of period available for setup
#   min = 0.5 ns  -> guards against fast-corner hold
# Tighten once a real host PHY is chosen.
# -----------------------------------------------------------------------------

# dense_weight_base_addr / sparse_out_base_addr are archbetter_core-only; the
# remaining base-addr ports exist on both tops. -quiet filters per active top.
set _runtime_in_ports [get_ports -quiet {start \
                            kv_wr_data_i[*] \
                            dense_weight_base_addr[*] \
                            dense_act_base_addr[*] \
                            tlmm_base_addr[*] \
                            out_collector_base_addr[*] \
                            sparse_out_base_addr[*] \
                            d2s_ready_i \
                            d2s_almost_full_i \
                            dram_req_ready \
                            dram_rsp_data[*] \
                            dram_rsp_valid \
                            dram_rsp_last \
                            dram_wr_req_ready \
                            dram_wr_wd_ready}]

set_input_delay -clock virt_host -max 2.0 $_runtime_in_ports
set_input_delay -clock virt_host -min 0.5 $_runtime_in_ports

# -----------------------------------------------------------------------------
# Runtime output delays  (FPGA -> host, launched on clk_compute)
# -----------------------------------------------------------------------------

# sparse_out_wr_* are archbetter_core-only; -quiet filters per active top.
set _runtime_out_ports [get_ports -quiet {program_done \
                             kv_rd_data_o[*] \
                             kv_rd_valid_o \
                             y_out[*] \
                             y_valid \
                             sparse_out_wr_en \
                             sparse_out_wr_addr[*] \
                             sparse_out_wr_data[*] \
                             d2s_data_o[*] \
                             d2s_user_o[*] \
                             d2s_valid_o \
                             d2s_last_o \
                             dram_req_addr[*] \
                             dram_req_len[*] \
                             dram_req_valid \
                             dram_rsp_ready \
                             dram_wr_req_addr[*] \
                             dram_wr_req_len[*] \
                             dram_wr_req_valid \
                             dram_wr_wd_data[*] \
                             dram_wr_wd_valid \
                             dram_wr_wd_last}]

set_output_delay -clock virt_host -max 2.0 $_runtime_out_ports
set_output_delay -clock virt_host -min 0.5 $_runtime_out_ports

# -----------------------------------------------------------------------------
# Multicycle / max-delay hints
#
# Reserve this section for paths that violate by exactly the latency the
# RTL expects (e.g. the dense_out_collector requantize-to-d2s burst, or the
# csd_drain_engine fill cadence). Add hints here only after report_timing
# shows a real false negative on a pipelined path.
# -----------------------------------------------------------------------------

# (intentionally empty for Phase-7c; revisit during Phase-8 closure.)
