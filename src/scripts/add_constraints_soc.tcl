# -----------------------------------------------------------------------------
# add_constraints_soc.tcl
#
# Register the C4 DEVICE-SPLIT constraint set for the closed SoC wrapper
# (archbetter_soc_top) with the constrs_1 fileset. The split is:
#
#   timing_portable.xdc      device-AGNOSTIC clocks / false paths / I-O delays.
#                            Shared UNCHANGED across XCKU5P and XCVU9P.
#                            USED_IN: synthesis + implementation.
#   physical_<device>.xdc    device-SPECIFIC PACKAGE_PIN / IOSTANDARD + floorplan
#                            (single-SLR pblock hook). USED_IN: implementation.
#
# Device select (default ku5p = headline). Override before sourcing, e.g.:
#     set ::ab_device vu9p
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/add_constraints_soc.tcl
#
# This is SEPARATE from the legacy add_constraints.tcl (which registers the
# archbetter_core OOC-stopgap timing.xdc/pins.xdc). The two are not sourced
# together — pick the flow that matches the active synth top.
# -----------------------------------------------------------------------------

if {![info exists ::ab_device]} { set ::ab_device ku5p }

set _script_abs [file normalize [info script]]
set _proj_root  [file dirname [file dirname [file dirname $_script_abs]]]
puts "add_constraints_soc: project root = $_proj_root ; device = $::ab_device"

proc _ab_add_xdc {rel_path used_in_synth} {
    global _proj_root
    set abs_path [file normalize [file join $_proj_root $rel_path]]
    if {![file exists $abs_path]} {
        puts "add_constraints_soc: skipped (missing) $rel_path"
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

# Portable timing first (so the physical file sits atop a defined clock world),
# then the per-device physical file.
_ab_add_xdc src/constraints/timing_portable.xdc      true
_ab_add_xdc src/constraints/physical_$::ab_device.xdc false

# Target = the portable timing file (where read_xdc/write_xdc round-trip lands).
set _t_abs [file normalize [file join $_proj_root src/constraints/timing_portable.xdc]]
set _t_obj [get_files -quiet -of_objects [get_filesets constrs_1] $_t_abs]
if {[llength $_t_obj] != 0} {
    set_property target_constrs_file $_t_abs [get_filesets constrs_1]
}

puts "add_constraints_soc: [llength [get_files -of_objects [get_filesets constrs_1]]] constraint file(s) registered for soc_top ($::ab_device)."
