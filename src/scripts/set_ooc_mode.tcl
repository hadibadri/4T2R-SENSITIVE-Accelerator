# -----------------------------------------------------------------------------
# set_ooc_mode.tcl
#
# Configure synth_1 and impl_1 to run in out-of-context (OOC) mode.
#
# Why this exists
# ---------------
# archbetter_top exposes 6564 internal signals as external ports for
# simulation. The XCKU5P-FFVD900 package has 386 user I/O pins. Trying to
# place 6564 ports onto 386 pins fails with [Place 30-415], which is what
# blocked the last impl run.
#
# For the journal artifact we need:
#   * Synthesis utilization (LUT / FF / DSP / BRAM / URAM)         <- have
#   * Post-route timing slack (WNS / TNS, report_timing_summary)   <- need
#   * Post-route power (report_power)                              <- need
#
# We do NOT need a deployable bitstream; we are publishing the architecture
# and silicon-credible timing/power numbers. OOC mode places and routes the
# design using the device fabric (CLBs, DSPs, BRAMs, URAMs) but treats the
# top-level ports as virtual nets — no IBUF/OBUF/pin placement attempted.
#
# When (Phase 9+) we want a real board demo, we'll add a thin
# "archbetter_board_top" wrapper that bundles the wide ports onto a host
# interface (e.g. PCIe-AXI bridge) and re-runs synth+impl WITHOUT OOC.
#
# How to source
# -------------
# After opening project_1.xpr, in the Vivado Tcl console:
#
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/set_ooc_mode.tcl
#
# Then re-run the runs (this script does NOT auto-launch them):
#
#     reset_run synth_1
#     launch_runs synth_1 -jobs 8
#     wait_on_run synth_1
#     launch_runs impl_1  -to_step write_bitstream -jobs 8
#     wait_on_run  impl_1
#
# Note: skip `write_bitstream` if you don't want the bitstream step (it will
# fail anyway in OOC mode). For numbers-only:
#
#     launch_runs impl_1 -to_step route_design -jobs 8
#     wait_on_run  impl_1
#     open_run     impl_1
#     report_timing_summary -file reports/timing.rpt
#     report_power           -file reports/power.rpt
#     report_utilization     -file reports/util.rpt
# -----------------------------------------------------------------------------

puts "set_ooc_mode: configuring synth_1 / impl_1 for out-of-context mode"

# ---- Synthesis: emit OOC-compatible netlist (no IBUF/OBUF inferred) --------
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
             -value {-mode out_of_context} \
             -objects [get_runs synth_1]

# ---- Implementation: skip IO buffer insertion + bitstream step -------------
# The opt_design step would otherwise try to insert IBUF/OBUF based on the
# top-level port directions. -no_iobuf prevents that under OOC.
set_property -name {STEPS.OPT_DESIGN.ARGS.MORE OPTIONS} \
             -value {} \
             -objects [get_runs impl_1]

# Make sure the synth_msg_config demotions are sourced before each run, so
# that re-launching does not regress on the architectural-slack warnings.
set_property STEPS.SYNTH_DESIGN.TCL.PRE \
    [file normalize [file dirname [info script]]/synth_msg_config.tcl] \
    [get_runs synth_1]

# Apply waivers AFTER opt_design so methodology checks see the post-opt
# netlist. Source the waivers script as a tcl.post hook on opt_design.
set_property STEPS.OPT_DESIGN.TCL.POST \
    [file normalize [file dirname [info script]]/waivers.tcl] \
    [get_runs impl_1]

puts "set_ooc_mode: done."
puts "  synth_1: out-of-context mode enabled, synth_msg_config.tcl is tcl.pre hook"
puts "  impl_1:  waivers.tcl wired as opt_design tcl.post hook"
puts ""
puts "  Now run:  reset_run synth_1 ;  launch_runs synth_1 -jobs 8"
puts "            launch_runs impl_1 -to_step route_design -jobs 8"
