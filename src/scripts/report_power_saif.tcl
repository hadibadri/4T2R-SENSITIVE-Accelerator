# -----------------------------------------------------------------------------
# report_power_saif.tcl   (C6 step 3 — SAIF-annotated power on the NON-OOC build)
#
# Applies the 8-layer sustained SAIF (from run_tb_archbetter_soc_top_sustained_
# saif.tcl) to the ALREADY-ROUTED archbetter_ku5p_top (impl_1) and writes the
# activity-based, publishable power number. NO re-synth / re-impl — it opens the
# existing routed design and annotates it.
#
# Usage (Vivado Tcl console, project already built by build_ku5p.tcl):
#     set ::ab_saif <sim_dir>/archbetter_soc.saif
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/report_power_saif.tcl
#
# Outputs (reports/):
#   power_saif.rpt        - whole-chip summary, SAIF-annotated
#   power_saif_hier.rpt   - per-instance breakdown; the u_soc row is the
#                           ACCELERATOR power (§11 boundary); the u_mem row is the
#                           DDR4-MIG stand-in = EXTERNAL, NOT part of the headline.
#
# Power boundary (CLAUDE.md §11): the publishable accelerator number is u_soc
# (archbetter_soc_top = core + loader + MMCM + AXI adapters). u_mem (BRAM DRAM
# stand-in) is declared external. Dynamic power is per-instance in the hier report;
# device static (leakage) is whole-chip.
# -----------------------------------------------------------------------------

set _scripts_dir [file dirname [file normalize [info script]]]
set _proj_root   [file dirname [file dirname $_scripts_dir]]
set _reports_dir [file join $_proj_root reports]
file mkdir $_reports_dir

# ---- preconditions ----------------------------------------------------------
if {![info exists ::ab_saif]} {
    error "report_power_saif: set ::ab_saif <path/to/archbetter_soc.saif> first (see run_tb_archbetter_soc_top_sustained_saif.tcl)."
}
if {![file exists $::ab_saif]} {
    error "report_power_saif: ::ab_saif file not found: $::ab_saif"
}
# Strip the TB top so SAIF paths (tb.../u_soc/u_core/...) land on the routed
# ku5p_top hierarchy (u_soc/u_core/...). Override only if the TB top renames.
if {![info exists ::ab_saif_strip]} { set ::ab_saif_strip {tb_archbetter_soc_top_sustained} }

# ---- make sure the ROUTED impl_1 is the current design -----------------------
# Drop any active simulation context (the SAIF sim was likely just run) so the
# power report runs on the routed netlist, not the sim snapshot.
catch { close_sim -quiet }
set _need_open 1
if {![catch {get_property TOP [current_design]} _t]} {
    if {$_t eq "archbetter_ku5p_top"} {
        set _need_open 0
        puts "report_power_saif: routed design '$_t' already open."
    }
}
if {$_need_open} {
    puts "report_power_saif: open_run impl_1 (routed ku5p top) ..."
    open_run impl_1
}

# ---- annotate with switching activity ---------------------------------------
puts "report_power_saif: reading SAIF $::ab_saif (strip_path=$::ab_saif_strip)"
read_saif -strip_path $::ab_saif_strip $::ab_saif

set _cov "n/a"
catch { set _cov [get_property NETS_MATCHED_PERCENT [get_power_results]] }

# ---- write the reports ------------------------------------------------------
set _sum  [file join $_reports_dir power_saif.rpt]
set _hier [file join $_reports_dir power_saif_hier.rpt]
report_power -file $_sum
# Per-instance breakdown: -hierarchical is NOT a valid report_power switch in
# 2025.2 ("[Common 17-165] Too many positional options"). The supported control
# is -hierarchical_depth <N>. Wrap in catch so a tool-version mismatch can never
# abort the run before the console summary prints; if it fails, _hier is absent
# and the per-instance grep below degrades to "n/a" (the whole-chip number in
# $_sum is the gating figure regardless).
set _have_hier 0
if {[catch {report_power -hierarchical_depth 6 -file $_hier} _herr]} {
    puts "report_power_saif: per-instance report skipped ($_herr)"
} else {
    set _have_hier 1
}

# ---- best-effort console extraction -----------------------------------------
proc _grep_float {file pat} {
    if {[catch {set fh [open $file r]} ]} { return "n/a" }
    set txt [read $fh]; close $fh
    if {[regexp $pat $txt -> v]} { return $v }
    return "n/a"
}
set _total   [_grep_float $_sum  {Total On-Chip Power \(W\)[^0-9]*([0-9]+\.[0-9]+)}]
set _dynamic [_grep_float $_sum  {Dynamic \(W\)[^0-9]*([0-9]+\.[0-9]+)}]
set _static  [_grep_float $_sum  {Device Static \(W\)[^0-9]*([0-9]+\.[0-9]+)}]

# u_soc (accelerator) + u_mem (DRAM stand-in, external) dynamic from hier report.
proc _grep_inst_pwr {file inst} {
    if {[catch {set fh [open $file r]}]} { return "n/a" }
    set out "n/a"
    foreach ln [split [read $fh] "\n"] {
        if {[regexp "\\|\\s*$inst\\s*\\(" $ln] || [regexp "\\|\\s*$inst\\s*\\|" $ln]} {
            # last floating-point token on the row is the instance total power
            set fs [regexp -all -inline {[0-9]+\.[0-9]+} $ln]
            if {[llength $fs] > 0} { set out [lindex $fs end] }
            break
        }
    }
    close $fh
    return $out
}
set _p_soc "n/a"
set _p_mem "n/a"
if {$_have_hier} {
    set _p_soc [_grep_inst_pwr $_hier u_soc]
    set _p_mem [_grep_inst_pwr $_hier u_mem]
}

puts ""
puts "==================== C6 SAIF-ANNOTATED POWER (non-OOC) ===================="
puts " SAIF coverage (nets matched)      : $_cov %   (low % => check strip_path)"
puts " Whole-chip Total On-Chip Power    : $_total W"
puts "   - Dynamic                       : $_dynamic W"
puts "   - Device Static (leakage)       : $_static W"
puts " Accelerator u_soc dynamic (HEADLINE, DRAM external) : $_p_soc W"
puts " DRAM stand-in u_mem dynamic (EXTERNAL, exclude)     : $_p_mem W"
puts " Reports: $_sum"
puts "          $_hier   (read the u_soc row for the accelerator-scoped number)"
puts "=========================================================================="
puts "NOTE: behavioral-sim SAIF name-mapped onto the routed netlist (coverage <100%,"
puts "disclosed). Gold standard = post-route timing-sim SAIF, consumed by this same"
puts "script unchanged. Throughput/efficiency: see C6 notes (reload-bound K=1 regime)."
