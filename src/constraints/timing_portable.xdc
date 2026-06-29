# =============================================================================
# timing_portable.xdc  -  ArchBetter C4 device-AGNOSTIC timing constraints
#                         for the closed SoC wrapper (archbetter_soc_top).
#
# This is the "ports unchanged across devices" half of the device-split
# (CLAUDE.md §11): it contains ONLY clock/false-path/I-O-delay constraints that
# reference soc_top's logical port names. It carries NO PACKAGE_PIN / IOSTANDARD
# and NO floorplan — so it is IDENTICAL on XCKU5P (headline) and XCVU9P
# (hardware validation). The KU5P→VU9P move touches only physical_<device>.xdc
# and the MIG, never this file.
#
# Closure top: archbetter_soc_top (clk_in board oscillator -> MMCME4 -> 225 MHz
# compute clock; narrow cfg control port; AXI4 DRAM seam internal to the MIG at
# C5). The legacy archbetter_core/timing.xdc (OOC stopgap, `clk` port) is
# superseded by this file for the non-OOC flow and is intentionally left
# untouched on disk.
#
# XDC interpreter note: a RESTRICTED Tcl interpreter reads XDC — no proc/if/
# foreach ([Designutils 20-1307]). Pattern unions are passed straight to
# get_ports -quiet, which drops non-matching patterns on the active top.
# =============================================================================

# -----------------------------------------------------------------------------
# Board oscillator -> compute clock
#
# clk_in is the board oscillator. Default 100 MHz (10.000 ns); the MMCME4_ADV
# inside soc_top synthesizes the 225 MHz (4.444 ns) compute clock (VCO 900 MHz,
# MULT_F=9 / DIV_F=4 — see archbetter_soc_top g_mmcm; dropped from 250 MHz for
# >=10% slack per §8, in-cohort with FlightLLM's 225 MHz). Vivado AUTO-DERIVES
# the generated compute clock from the MMCM CLKOUT0 — do NOT hand-write
# create_generated_clock for it (that double-constrains the MMCM). Only the
# primary board clock is declared here.
#
# If the chosen board oscillator is not 100 MHz, change ONLY this period and the
# MMCME4 CLKIN1_PERIOD/CLKFBOUT_MULT_F in archbetter_soc_top (g_mmcm branch).
# -----------------------------------------------------------------------------
create_clock -name clk_in -period 10.000 -waveform {0.000 5.000} [get_ports clk_in]

# -----------------------------------------------------------------------------
# Compute-clock setup guard band (timing headroom, CLAUDE.md §8 >=10% slack)
#
# WHY THIS EXISTS (do not remove without re-reading): without a guard band the
# placer relaxes sub-critical paths up to the bare 225 MHz (4.444 ns) target.
# The original worst path was a SINGLE-logic-level dispatcher imem path (pc_reg
# -> imem RAMD64E -> decode reg), ~96% ROUTE, that the router let drift to
# 4.434 ns (WNS ~+0.010) even though the SAME path closed at ~3.9 ns when
# constrained harder. Reserving 0.400 ns of setup uncertainty raises every
# near-critical path's criticality so the placer co-locates their cells.
#
# RESULT (routed, 2026-06-19): the guard band did its job — the imem path
# tightened out of the way, and the residual worst path is now a DIFFERENT
# structure: the accumulator-clear net (u_dispatcher FSM decode -> acc_clr ->
# u_array/bank_reg[*]/R), 9 logic levels of state decode feeding a BUFG-
# distributed synchronous reset that fans out to 45,056 array-bank FFs (~1.46 ns
# is pure distribution). Data Path Delay 4.018 ns, WNS +0.012 ns AT the
# requirement that already folds in the 0.400 ns guard band — i.e. ~0.412 ns
# (9.3% of period) of real, disclosed PVT/aging headroom held in reserve. This
# is a genuine robustness margin, not a reporting trick.
#
# The acc_clr fanout is structural (one clear per array accumulator bank), so the
# distribution term is bounded but not shrinkable by placement alone. If a future
# revision needs a clean >=10%: pipeline acc_clr one stage (register the FSM-
# decoded clear before it drives the bank reset) so the 9-level decode and the
# BUFG distribution fall in separate cycles — an RTL change, deferred past C6.
# Applied to the MMCM CLKOUT0-derived compute clock (auto-named *clkout0); the
# constraint's reference to that auto-derived clock is waived (TIMING-28) in
# waivers.tcl, with the create_generated_clock alternative deliberately avoided.
# -----------------------------------------------------------------------------
set_clock_uncertainty -setup 0.400 [get_clocks -quiet *clkout0]

# Virtual host clock for off-chip control I/O (no real host PHY pin yet). Use a
# compute-period virtual clock so the cfg I/O delays are quantitative. Tracks the
# 225 MHz compute clock (4.444 ns) — keep in sync with the MMCM CLKOUT0 period.
create_clock -name virt_host -period 4.444

# -----------------------------------------------------------------------------
# Async board reset
#
# ext_rst_n is asynchronous to every clock; soc_top brings it into the compute
# domain through xpm_cdc_async_rst (gated on MMCM lock). Only the de-assertion
# edge matters and it is handled by the synchronizer — false-path the pin.
# -----------------------------------------------------------------------------
set_false_path -from [get_ports ext_rst_n]

# -----------------------------------------------------------------------------
# Narrow control/loader bus (cfg_*) — quasi-static
#
# The host writes the imem program, CSD descriptors, and per-layer base
# addresses through this 32-bit register port BEFORE asserting CTRL.start, and
# the bus is quiet during execution (dispatcher contract). Constraining it as a
# timed path would pessimize placement for no benefit — false-path the write
# side; treat the readback + status as observation-only.
# -----------------------------------------------------------------------------
set_false_path -from [get_ports -quiet {cfg_we cfg_addr[*] cfg_wdata[*]}]
set_false_path -to   [get_ports -quiet {cfg_rdata[*] program_done locked_o compute_clk_o}]

# -----------------------------------------------------------------------------
# AXI4 DRAM seam (m_axi)
#
# Intentionally UNCONSTRAINED here. At C5 the DDR4 MIG is instantiated INSIDE
# the synth top and owns its own AXI clock domain + timing (the MIG-generated
# XDC). This portable file never sees the memory PHY. If a future revision
# exposes m_axi on a chip-to-chip boundary instead, add its I/O delays to the
# board physical_<device>.xdc, not here.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Multicycle / max-delay hints
#
# Empty by default. Add hints ONLY after report_timing shows a real false
# negative on a known-pipelined path (e.g. the dense_out_collector requantize
# burst or the csd_drain_engine cadence). Do not pre-seed exceptions.
# -----------------------------------------------------------------------------
# (intentionally empty until C5 routed timing identifies a real pipelined path.)
