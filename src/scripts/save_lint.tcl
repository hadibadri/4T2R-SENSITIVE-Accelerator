# -----------------------------------------------------------------------------
# save_lint.tcl
#
# Export the current RTL Linter / methodology violations to reports/lint.rpt.
# Run from the Vivado Tcl console with:
#
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/save_lint.tcl
#
# If an elaborated design (or synth/impl run) is already open, the script
# uses it directly. Otherwise it opens the elaborated design first.
# -----------------------------------------------------------------------------

set _script_abs [file normalize [info script]]
set _proj_root  [file dirname [file dirname [file dirname $_script_abs]]]
set _rpt_dir    [file join $_proj_root reports]
set _rpt_path   [file join $_rpt_dir lint.rpt]

if {![file isdirectory $_rpt_dir]} {
    file mkdir $_rpt_dir
}

# If nothing is open, elaborate the top-level design.
set _have_design 0
if {[catch {current_design} _cur] == 0} {
    if {$_cur ne ""} { set _have_design 1 }
}

if {!$_have_design} {
    puts "save_lint: no design open, elaborating sources_1 top..."
    # IMPORTANT: -rtl forces RTL-elaboration-only (~minutes). Dropping -rtl
    # turns this into a full synth pass that takes hours on the PE array.
    synth_design -rtl -rtl_skip_mlo -name rtl_lint
}

# Plain report_methodology runs every enabled rule deck — that's the same
# set the GUI's "All Violations" tab shows on the elaborated design.
# (Do NOT pass -checks {all}; "all" is not a valid rule name in Vivado.)
puts "save_lint: writing $_rpt_path"
report_methodology -file $_rpt_path

puts "save_lint: done. Open reports/lint.rpt"
