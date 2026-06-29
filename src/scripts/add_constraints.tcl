# -----------------------------------------------------------------------------
# add_constraints.tcl
#
# Register ArchBetter XDC files with the constrs_1 fileset. Idempotent in the
# style of add_sources.tcl: re-sourcing after editing the constraints is the
# normal workflow and will not produce duplicate entries.
#
# Usage from the Vivado Tcl console:
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/add_constraints.tcl
#
# File ordering:
#   1. timing.xdc - clocks, false paths, I/O delays. Must be evaluated FIRST
#                   so that downstream constraints can reference clk_compute /
#                   virt_host. USED_IN: synthesis + implementation.
#   2. pins.xdc   - PACKAGE_PIN / IOSTANDARD assignments (currently a template
#                   with all entries commented). USED_IN: implementation only;
#                   pin assignment is meaningless during synthesis.
# -----------------------------------------------------------------------------

set _script_abs [file normalize [info script]]
set _proj_root  [file dirname [file dirname [file dirname $_script_abs]]]
puts "add_constraints: project root = $_proj_root"

proc _ab_add_xdc {rel_path used_in_synth} {
    global _proj_root
    set abs_path [file normalize [file join $_proj_root $rel_path]]
    if {![file exists $abs_path]} {
        puts "add_constraints: skipped (missing) $rel_path"
        return
    }
    set existing [get_files -quiet -of_objects [get_filesets constrs_1] $abs_path]
    if {[llength $existing] == 0} {
        add_files -norecurse -fileset constrs_1 $abs_path
    }
    set f [get_files -of_objects [get_filesets constrs_1] $abs_path]
    set_property file_type XDC $f
    set_property used_in_synthesis      $used_in_synth $f
    set_property used_in_implementation true           $f
}

# Order matters - timing first so PINs can sit on top of a defined clock world.
_ab_add_xdc src/constraints/timing.xdc true
_ab_add_xdc src/constraints/pins.xdc   false

# Promote timing.xdc to TARGET (the file that read_xdc/write_xdc round-trip
# constraints into), so future GUI edits land in a known place.
set _timing_abs [file normalize [file join $_proj_root src/constraints/timing.xdc]]
set _timing_obj [get_files -quiet -of_objects [get_filesets constrs_1] $_timing_abs]
if {[llength $_timing_obj] != 0} {
    set_property target_constrs_file $_timing_abs [get_filesets constrs_1]
}

puts "add_constraints: [llength [get_files -of_objects [get_filesets constrs_1]]] constraint file(s) registered."
