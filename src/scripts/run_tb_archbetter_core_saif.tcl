# -----------------------------------------------------------------------------
# run_tb_archbetter_core_saif.tcl
#
# Like run_tb_archbetter_core.tcl, but captures a SAIF (Switching Activity
# Interchange Format) file over the DUT hierarchy so report_power can produce a
# REAL, activity-based number instead of the default vectorless guess
# (CLAUDE.md §2/§8 power-honesty rule).
#
# Flow (you run this in the Vivado Tcl console; I never launch sim myself):
#
#   1. source this script  -> compiles, elaborates, runs tb_archbetter_core to
#      $finish, and writes archbetter_core.saif into the sim run directory.
#   2. note the printed SAIF path.
#   3. source build.tcl with ::ab_saif pointing at it:
#
#        set ::ab_saif <printed path>/archbetter_core.saif
#        source C:/Users/user/Desktop/ArchBetter/src/scripts/build.tcl
#
#      -> reports/power.rpt becomes activity-annotated (Confidence: High on
#         internal-node activity), and the SUMMARY line will say
#         "SAIF-annotated (activity-based)".
#
# HONESTY CAVEAT (state this in the paper): a SAIF captured from RTL/behavioral
# simulation is name-mapped onto the routed netlist by read_saif. Coverage is
# good but not 100% (some nets are renamed/optimized). It is a large step up
# from vectorless, but the gold standard for a TVLSI energy claim is a
# POST-ROUTE timing simulation (funcsim netlist + SDF) feeding the SAIF. When we
# get there, this same build.tcl ::ab_saif hook consumes that SAIF unchanged.
#
# SCOPE NOTE: saif_scope is the DUT instance inside tb_archbetter_core, which is
# `dut` (see tb_archbetter_core.sv:166). Logging the DUT subtree (not the whole
# TB) keeps the activity file focused on the synthesized hierarchy.
# -----------------------------------------------------------------------------

source C:/Users/user/Desktop/ArchBetter/src/scripts/add_sources.tcl

set_property top tb_archbetter_core [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Built-in XSim SAIF capture: log the DUT subtree, write archbetter_core.saif.
# These properties make launch_simulation emit the SAIF automatically when the
# sim reaches $finish — no manual open_saif/log_saif/run juggling.
set_property -name {xsim.simulate.saif_scope}       -value {dut}                  -objects [get_filesets sim_1]
set_property -name {xsim.simulate.saif}             -value {archbetter_core.saif} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.saif_all_signals} -value {true}                 -objects [get_filesets sim_1]

launch_simulation

# Print where the SAIF landed so you can wire ::ab_saif at it.
# NOTE: [current_sim] has no DIRECTORY property in Vivado 2025.2; derive the
# behavioral xsim run dir from the project location instead.
set _proj     [current_project]
set _proj_dir [get_property DIRECTORY $_proj]
set _sim_dir  [file join $_proj_dir ${_proj}.sim sim_1 behav xsim]
puts ""
puts "SAIF: capture complete."
puts "SAIF: file = [file join $_sim_dir archbetter_core.saif]"
puts "SAIF: next -> set ::ab_saif [file join $_sim_dir archbetter_core.saif]"
puts "SAIF:         source C:/Users/user/Desktop/ArchBetter/src/scripts/build.tcl"
