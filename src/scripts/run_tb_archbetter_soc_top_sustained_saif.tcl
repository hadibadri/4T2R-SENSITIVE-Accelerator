# -----------------------------------------------------------------------------
# run_tb_archbetter_soc_top_sustained_saif.tcl   (C6 step 2 — SAIF capture)
#
# Runs the 8-layer DISTINCT-data sustained workload and writes a SAIF (Switching
# Activity Interchange Format) over the ACCELERATOR subtree (the u_soc instance =
# archbetter_soc_top), so report_power on the routed archbetter_ku5p_top can
# produce a REAL, activity-based power number instead of the vectorless guess
# (CLAUDE.md §2/§8/§11 power-honesty rule).
#
# Flow (run in the Vivado Tcl console; the USER runs sim, never me):
#   1. source THIS script  -> compiles + runs tb_archbetter_soc_top_sustained to
#      $finish (8 layers, ~4 min) and writes archbetter_soc.saif into the sim run
#      directory. Confirm it still ends "PASS (8 layers, 1080 checks, 0 errors)".
#   2. note the printed SAIF path.
#   3. apply it to the already-routed impl_1 (NO rebuild) for the power number:
#        set ::ab_saif <printed path>/archbetter_soc.saif
#        source C:/Users/user/Desktop/ArchBetter/src/scripts/report_power_saif.tcl
#
# SCOPE NOTE: saif_scope = `u_soc`, the archbetter_soc_top instance inside the TB
# (renamed from `dut` precisely so the SAIF hierarchy is u_soc/u_core/... — a 1:1
# match to the routed ku5p_top after read_saif strips the TB top). u_mem (the
# DDR4-MIG stand-in) is a TB/ku5p sibling OUTSIDE u_soc, so it is naturally
# excluded — the §11 accelerator-core power boundary (DRAM declared external).
#
# HONESTY CAVEAT (state in the paper): a SAIF captured from BEHAVIORAL simulation
# is name-mapped onto the routed netlist by read_saif — coverage is good but not
# 100% (some nets are renamed/optimized at synth). It is a large step up from
# vectorless; the gold standard is a POST-ROUTE timing simulation (funcsim netlist
# + SDF) feeding the SAIF. The same report_power_saif.tcl consumes that unchanged
# when we get there.
# -----------------------------------------------------------------------------

source C:/Users/user/Desktop/ArchBetter/src/scripts/add_sources.tcl

set_property top tb_archbetter_soc_top_sustained [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Built-in XSim SAIF capture: log the u_soc (accelerator) subtree, write the file.
# launch_simulation emits the SAIF automatically when the sim reaches $finish.
set_property -name {xsim.simulate.saif_scope}       -value {u_soc}              -objects [get_filesets sim_1]
set_property -name {xsim.simulate.saif}             -value {archbetter_soc.saif} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.saif_all_signals} -value {true}               -objects [get_filesets sim_1]

launch_simulation

# Print where the SAIF landed so you can wire ::ab_saif at it.
set _proj     [current_project]
set _proj_dir [get_property DIRECTORY $_proj]
set _sim_dir  [file join $_proj_dir ${_proj}.sim sim_1 behav xsim]
puts ""
puts "SAIF: capture complete (8-layer sustained run)."
puts "SAIF: file = [file join $_sim_dir archbetter_soc.saif]"
puts "SAIF: next -> set ::ab_saif [file join $_sim_dir archbetter_soc.saif]"
puts "SAIF:         source C:/Users/user/Desktop/ArchBetter/src/scripts/report_power_saif.tcl"
