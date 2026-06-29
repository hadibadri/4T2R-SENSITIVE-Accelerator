# -----------------------------------------------------------------------------
# build_ku5p.tcl
#
# C5 NON-OOC closure flow for the headline XCKU5P prototype. Source from the
# Vivado Tcl console after opening the project:
#
#     vivado project_1.xpr
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/build_ku5p.tcl
#
# This is the closure that gets ArchBetter OFF the out-of-context stopgap
# (project memory). The synthesis root is archbetter_ku5p_top — a fully-pinned
# top with the real MMCM clock tree and a synthesizable BRAM AXI backend behind
# the memory seam — so synth+impl run NON-OOC, write a bitstream, and produce
# honest WNS / utilization / DRC / methodology numbers on the real device.
#
# Differences vs the legacy build.tcl (OOC, archbetter_core):
#   * NO set_ooc_mode.tcl — instead we EXPLICITLY CLEAR any leftover OOC mode.
#   * add_constraints_soc.tcl (device-split, ku5p) instead of add_constraints.tcl.
#   * impl runs to write_bitstream (now legal — the design is fully pinned).
#   * synth_msg_config (msg demotions) + waivers (opt_design post hook) kept.
#
# Optional overrides (set BEFORE sourcing):
#   set ::ab_jobs 8
#   set ::ab_skip_setup 1        ;# sources/constraints already registered
#   set ::ab_to_bitstream 0      ;# stop at route_design (skip write_bitstream)
#
# Power note (CLAUDE.md §2/§8): this script reports VECTORLESS power only — an
# estimate, NOT publishable. The SAIF-annotated (vectored) power is the C6
# deliverable, captured from a representative tb_archbetter_soc_top sim and
# hierarchy-scoped to the accelerator (u_soc/u_core); the BRAM backend is
# declared external to the accelerator power boundary (§11).
# -----------------------------------------------------------------------------

set _script_abs  [file normalize [info script]]
set _scripts_dir [file dirname $_script_abs]
set _proj_root   [file dirname [file dirname $_scripts_dir]]
puts "build_ku5p: project root = $_proj_root"

if {![info exists ::ab_jobs]}         { set ::ab_jobs 8 }
if {![info exists ::ab_skip_setup]}   { set ::ab_skip_setup 0 }
if {![info exists ::ab_to_bitstream]} { set ::ab_to_bitstream 1 }

set _reports_dir [file join $_proj_root reports]
file mkdir $_reports_dir

# -----------------------------------------------------------------------------
# 1-2. Setup: sources + device-split constraints (ku5p).
# -----------------------------------------------------------------------------
if {$::ab_skip_setup} {
    puts "build_ku5p: ab_skip_setup=1 — skipping add_sources / add_constraints_soc"
} else {
    source [file join $_scripts_dir add_sources.tcl]
    set ::ab_device ku5p
    source [file join $_scripts_dir add_constraints_soc.tcl]
}

# -----------------------------------------------------------------------------
# 3. Synthesis root + CLEAR out-of-context mode (the point of C5).
# -----------------------------------------------------------------------------
puts "build_ku5p: synthesis top = archbetter_ku5p_top (NON-OOC)"
set_property top archbetter_ku5p_top [get_filesets sources_1]
update_compile_order -fileset sources_1

# Explicitly clear any -mode out_of_context left by a prior set_ooc_mode.tcl run.
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {} -objects [get_runs synth_1]
set_property -name {STEPS.OPT_DESIGN.ARGS.MORE OPTIONS}   -value {} -objects [get_runs impl_1]

# Disable the legacy OOC-stopgap core XDCs for the non-OOC SoC flow. They target
# archbetter_core/top ports (clk, rst_n, imem_*, ...) that do NOT exist on
# archbetter_ku5p_top, so leaving them active produces spurious CRITICAL WARNINGs
# ("No ports matched" / create_clock on a missing port) and a duplicate
# 'virt_host'. Non-destructive: the files stay on disk and in the project, just
# inactive for this run. add_constraints_soc already registered the device-split
# XDCs (timing_portable + physical_ku5p) that this top actually uses.
foreach _legacy {src/constraints/timing.xdc src/constraints/pins.xdc} {
    set _labs [file normalize [file join $_proj_root $_legacy]]
    set _lf   [get_files -quiet -of_objects [get_filesets constrs_1] $_labs]
    if {[llength $_lf]} {
        set_property used_in_synthesis      false $_lf
        set_property used_in_implementation false $_lf
        puts "build_ku5p: disabled legacy XDC '$_legacy' for the non-OOC flow"
    }
}

# Clear any stale auto-incremental synthesis reference (left pointing at the OOC
# archbetter_top.dcp). It is not valid for this top, emits a CRITICAL WARNING,
# and disables result caching. Guarded — property names vary by Vivado version.
catch { set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1] }
catch { set_property INCREMENTAL_CHECKPOINT {}     [get_runs synth_1] }

# Keep the message-demotion pre-hook and the waiver post-hook.
set_property STEPS.SYNTH_DESIGN.TCL.PRE \
    [file normalize [file join $_scripts_dir synth_msg_config.tcl]] [get_runs synth_1]
set_property STEPS.OPT_DESIGN.TCL.POST \
    [file normalize [file join $_scripts_dir waivers.tcl]] [get_runs impl_1]

# place_design PRE hook: assign legal placeholder pin LOCs from the device DB so
# the board-less closure is fully pinned (clears DRC UCIO-1 honestly, with real
# LOCs that survive to write_bitstream). clk_in -> clock-capable site; control
# pins -> general-purpose I/O. Skips any port a real board plan already LOC'd in
# physical_ku5p.xdc. See assign_ku5p_pins.tcl.
set_property STEPS.PLACE_DESIGN.TCL.PRE \
    [file normalize [file join $_scripts_dir assign_ku5p_pins.tcl]] [get_runs impl_1]

# write_bitstream PRE hook: downgrade UCIO-1 to a warning. With assign_ku5p_pins
# now setting real LOCs, UCIO-1 should not fire at all — this stays only as a
# harmless safety net (no-op when there are no unconstrained ports). NSTD-1 is
# fixed properly via IOSTANDARDs in physical_ku5p.xdc and stays an ERROR. Remove
# both hooks once a real board pinout is committed. (Only meaningful when
# ab_to_bitstream=1; harmless otherwise.)
set_property STEPS.WRITE_BITSTREAM.TCL.PRE \
    [file normalize [file join $_scripts_dir relax_io_drc.tcl]] [get_runs impl_1]

# -----------------------------------------------------------------------------
# 4. Synthesis.
# -----------------------------------------------------------------------------
puts "build_ku5p: ---- synth_1 ----"
reset_run synth_1
launch_runs synth_1 -jobs $::ab_jobs
wait_on_run synth_1
set _sp [get_property PROGRESS [get_runs synth_1]]
puts "build_ku5p: synth_1 status='[get_property STATUS [get_runs synth_1]]' progress=$_sp"
if {$_sp ne "100%"} { error "build_ku5p: synth_1 did not complete (progress=$_sp)." }

# -----------------------------------------------------------------------------
# 5. Implementation (to write_bitstream by default — fully pinned, non-OOC).
# -----------------------------------------------------------------------------
set _impl_step [expr {$::ab_to_bitstream ? "write_bitstream" : "route_design"}]
puts "build_ku5p: ---- impl_1 (to $_impl_step) ----"
launch_runs impl_1 -to_step $_impl_step -jobs $::ab_jobs
wait_on_run impl_1
set _ip [get_property PROGRESS [get_runs impl_1]]
puts "build_ku5p: impl_1 status='[get_property STATUS [get_runs impl_1]]' progress=$_ip"
if {$_ip ne "100%"} { error "build_ku5p: impl_1 did not complete (progress=$_ip)." }

# -----------------------------------------------------------------------------
# 6. Gating reports (CLAUDE.md §5).
# -----------------------------------------------------------------------------
puts "build_ku5p: ---- reports ----"
open_run impl_1

# Safety net only: assign_ku5p_pins.tcl now sets real placeholder LOCs at place
# PRE, so UCIO-1 should report ZERO violations. This downgrade stays harmless
# (no-op when nothing is unconstrained); NSTD-1 stays ERROR.
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

# report_methodology runs ALL methodology checks by default. NOTE: the
# `-checks {all}` form shown in CLAUDE.md sec 5 is INVALID in Vivado 2025.2
# ("Invalid Methodology rule name 'all'") — `-checks` expects specific rule
# IDs, not the literal 'all'. Omit it to run the full set.
report_methodology               -file [file join $_reports_dir methodology.rpt]
report_drc                       -file [file join $_reports_dir drc.rpt]
report_timing_summary -warn_on_violation -file [file join $_reports_dir timing.rpt]
report_utilization               -file [file join $_reports_dir util.rpt]
report_cdc                       -file [file join $_reports_dir cdc.rpt]
report_clock_utilization         -file [file join $_reports_dir clock_util.rpt]
report_power                     -file [file join $_reports_dir power_vectorless.rpt]

set _drc_n  [llength [get_drc_violations]]
set _wns    [get_property STATS.WNS [get_runs impl_1]]
set _whs    [get_property STATS.WHS [get_runs impl_1]]
set _dsp    [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
set _ram36  [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
set _ram18  [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]
set _uram   [llength [get_cells -hier -filter {REF_NAME =~ URAM288*}]]
set _mmcm   [llength [get_cells -hier -filter {REF_NAME =~ MMCM*}]]

puts ""
puts "build_ku5p: =============== SUMMARY (archbetter_ku5p_top, NON-OOC) ==============="
puts "build_ku5p:  Timing : WNS=$_wns ns  WHS=$_whs ns"
puts "build_ku5p:  Cells  : DSP48E2=$_dsp  RAMB36=$_ram36  RAMB18=$_ram18  URAM288=$_uram  MMCM=$_mmcm"
puts "build_ku5p:  DRC violations = $_drc_n  (UCIO-1 expected 0: placeholder pin LOCs assigned from device DB)"
puts "build_ku5p:  I/O    : IOSTANDARD LVCMOS18 (NSTD-1 clean); PACKAGE_PIN placeholder LOCs via assign_ku5p_pins.tcl (board-TBD)"
puts "build_ku5p:  Power  : VECTORLESS (estimate, NOT publishable) -> reports/power_vectorless.rpt"
puts "build_ku5p:  ---- C6 next: SAIF-annotated power from a representative sim ----"
puts "build_ku5p:  reports written to $_reports_dir"
puts "build_ku5p: ====================================================================="
