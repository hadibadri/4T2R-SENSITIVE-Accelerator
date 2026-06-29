# -----------------------------------------------------------------------------
# build.tcl
#
# One-shot batch build orchestrator for ArchBetter (CLAUDE.md §5). Source this
# from the Vivado Tcl console AFTER opening the project:
#
#     vivado project_1.xpr
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/build.tcl
#
# This runs in Vivado's FULL Tcl interpreter (NOT the restricted .xdc parser),
# so proc / if / foreach / error are all legal here. The only place that
# restriction bites is inside read_xdc-parsed constraint files; keep control
# flow OUT of *.xdc, never out of this script.
#
# What it does, in order:
#   1. Register/refresh RTL + TB sources       (add_sources.tcl)
#   2. Register/refresh XDC constraints         (add_constraints.tcl)
#   3. Configure OOC mode + wire msg/waiver hooks (set_ooc_mode.tcl)
#   4. reset + launch synth_1, wait, gate on completion
#   5. launch impl_1 to route_design, wait, gate on completion
#   6. open the routed design, write the §5 gating reports, and — if a SAIF is
#      provided — produce an activity-annotated (non-vectorless) power report
#   7. print a SUMMARY with the numbers that gate the journal artifact, plus an
#      explicit PASS/FAIL line for the methodology + DRC zero-warning bar
#
# Optional overrides (set BEFORE sourcing):
#   set ::ab_jobs 8              ;# parallel jobs (default 8)
#   set ::ab_skip_setup 1        ;# skip steps 1-3 (sources already registered)
#   set ::ab_synth_only 1        ;# stop after synth_1 (skip impl + post-route)
#   set ::ab_synth_top <name>    ;# synthesis root (default archbetter_core)
#   set ::ab_saif <path/to.saif> ;# activity file from a tb_archbetter_core sim;
#                                   when set + present, power.rpt becomes a real
#                                   activity-based estimate (High confidence),
#                                   not the default vectorless guess.
#
# IMPORTANT (power honesty, CLAUDE.md §2 / §8): with NO SAIF, report_power runs
# VECTORLESS — Vivado assumes a default toggle rate on >75% of internal nodes.
# That number is an estimate, not a measurement, and must never be reported as a
# result. Always pass ::ab_saif for any number that enters a paper. See the
# SAIF capture recipe in run_tb_archbetter_core_saif.tcl.
# -----------------------------------------------------------------------------

set _script_abs  [file normalize [info script]]
set _scripts_dir [file dirname $_script_abs]
set _proj_root   [file dirname [file dirname $_scripts_dir]]
puts "build: project root = $_proj_root"

if {![info exists ::ab_jobs]}       { set ::ab_jobs 8 }
if {![info exists ::ab_skip_setup]} { set ::ab_skip_setup 0 }
if {![info exists ::ab_synth_only]} { set ::ab_synth_only 0 }
# Phase-8: the closed SoC top archbetter_core is the synthesis target (the
# dispatcher orchestrates a full layer; nothing critical dead-ends, so the
# sparse core + URAMs no longer prune — unlike the open archbetter_top harness).
# Override with `set ::ab_synth_top archbetter_top` to synth the open harness.
if {![info exists ::ab_synth_top]}  { set ::ab_synth_top archbetter_core }

set _reports_dir [file join $_proj_root reports]
file mkdir $_reports_dir

# -----------------------------------------------------------------------------
# Small helpers (legal here — full Tcl interpreter).
# -----------------------------------------------------------------------------

# Count CRITICAL WARNING + ERROR messages emitted so far this session.
proc _ab_crit_count {} {
    set n 0
    catch { set n [get_msg_config -count -severity {CRITICAL WARNING}] }
    return $n
}

# Run a methodology check on the open design and return the violation count by
# parsing the returned string (report_methodology has no get_*_violations peer).
proc _ab_methodology_count {rpt_file} {
    set s ""
    catch { set s [report_methodology -checks {all} -return_string] }
    # Mirror to file for triage.
    catch {
        set fh [open $rpt_file w]
        puts $fh $s
        close $fh
    }
    # Each violation row carries a rule id in brackets; count the summary line
    # if present, else fall back to counting "VIOLATION" tokens.
    set m 0
    if {[regexp {([0-9]+)\s+violation} $s -> m]} {
        return $m
    }
    return [regexp -all {(?i)warning} $s]
}

# -----------------------------------------------------------------------------
# 1-3. Setup: sources, constraints, OOC + message/waiver hooks.
# -----------------------------------------------------------------------------
if {$::ab_skip_setup} {
    puts "build: ab_skip_setup=1 — skipping add_sources / add_constraints / set_ooc_mode"
} else {
    source [file join $_scripts_dir add_sources.tcl]
    source [file join $_scripts_dir add_constraints.tcl]
    source [file join $_scripts_dir set_ooc_mode.tcl]
}

puts "build: synthesis top = $::ab_synth_top"
set_property top $::ab_synth_top [get_filesets sources_1]
update_compile_order -fileset sources_1

# -----------------------------------------------------------------------------
# 4. Synthesis.
# -----------------------------------------------------------------------------
puts "build: ---- synth_1 ----"
reset_run synth_1
launch_runs synth_1 -jobs $::ab_jobs
wait_on_run synth_1

set _synth_prog [get_property PROGRESS [get_runs synth_1]]
puts "build: synth_1 status='[get_property STATUS [get_runs synth_1]]' progress=$_synth_prog"
if {$_synth_prog ne "100%"} {
    error "build: synth_1 did not complete (progress=$_synth_prog). Aborting before impl."
}

if {$::ab_synth_only} {
    puts "build: ab_synth_only=1 — stopping after synth_1."
    open_run synth_1 -name synth_1
    report_utilization -file [file join $_reports_dir util_synth.rpt]
    set _ms [_ab_methodology_count [file join $_reports_dir methodology_synth.rpt]]
    puts "build: synth-only reports written; methodology rows ~= $_ms"
    return
}

# -----------------------------------------------------------------------------
# 5. Implementation to route_design (no write_bitstream — OOC, see header).
# -----------------------------------------------------------------------------
puts "build: ---- impl_1 (to route_design) ----"
launch_runs impl_1 -to_step route_design -jobs $::ab_jobs
wait_on_run impl_1

set _impl_prog [get_property PROGRESS [get_runs impl_1]]
puts "build: impl_1 status='[get_property STATUS [get_runs impl_1]]' progress=$_impl_prog"
if {$_impl_prog ne "100%"} {
    error "build: impl_1 did not complete (progress=$_impl_prog). Check the run log."
}

# -----------------------------------------------------------------------------
# 6. Post-route gating reports (CLAUDE.md §5).
# -----------------------------------------------------------------------------
puts "build: ---- reports ----"
open_run impl_1

set _meth_n [_ab_methodology_count [file join $_reports_dir methodology.rpt]]
report_drc                                 -file [file join $_reports_dir drc.rpt]
report_timing_summary -warn_on_violation   -file [file join $_reports_dir timing.rpt]
report_utilization                         -file [file join $_reports_dir util.rpt]
report_cdc                                 -file [file join $_reports_dir cdc.rpt]

set _drc_viol [get_drc_violations]
set _drc_n    [llength $_drc_viol]

# ---- Power: vectorless baseline ALWAYS, activity-annotated IF a SAIF exists --
report_power -file [file join $_reports_dir power_vectorless.rpt]
set _pwr_mode "VECTORLESS (estimate, do NOT publish)"
set _pwr_file [file join $_reports_dir power_vectorless.rpt]
# The SAIF is captured over the testbench's DUT subtree (saif_scope=dut), so its
# hierarchy root is "tb_archbetter_core/dut". The routed/synthesized design root
# is the archbetter_core cells directly. read_saif MUST strip that TB prefix or
# the instance paths won't align and only the boundary nets match (~5%). Override
# with `set ::ab_saif_strip <path>` if the sim top / DUT instance name changes.
if {![info exists ::ab_saif_strip]} { set ::ab_saif_strip {tb_archbetter_core/dut} }
if {[info exists ::ab_saif] && [file exists $::ab_saif]} {
    puts "build: reading SAIF activity from $::ab_saif (strip_path=$::ab_saif_strip)"
    if {[catch {read_saif -strip_path $::ab_saif_strip $::ab_saif} _serr]} {
        puts "build: WARNING — read_saif failed ($_serr); power stays vectorless."
    } else {
        report_power -file [file join $_reports_dir power.rpt]
        set _pwr_mode "SAIF-annotated (activity-based)"
        set _pwr_file [file join $_reports_dir power.rpt]
        # Surface the match rate so a low-coverage SAIF can't masquerade as real.
        set _pm "n/a"
        catch { set _pm [get_property NETS_MATCHED_PERCENT [get_power_results]] }
        puts "build: SAIF nets matched ~= $_pm (low % => check strip_path / renaming)"
    }
} else {
    # Keep a power.rpt present, but make it the vectorless one with a clear name.
    file copy -force [file join $_reports_dir power_vectorless.rpt] \
                     [file join $_reports_dir power.rpt]
    puts "build: NOTE — no ::ab_saif set; power.rpt is VECTORLESS. Set ::ab_saif for a publishable number."
}

# -----------------------------------------------------------------------------
# Console summary — the numbers that gate the journal artifact.
# -----------------------------------------------------------------------------
set _wns [get_property STATS.WNS [get_runs impl_1]]
set _tns [get_property STATS.TNS [get_runs impl_1]]
set _whs [get_property STATS.WHS [get_runs impl_1]]
set _ths [get_property STATS.THS [get_runs impl_1]]

set _dsp  [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
set _ram36 [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
set _ram18 [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]
set _uram [llength [get_cells -hier -filter {REF_NAME =~ URAM288*}]]

puts ""
puts "build: ================ SUMMARY ($::ab_synth_top) ================"
puts "build:  Timing : WNS=$_wns ns  TNS=$_tns ns  WHS=$_whs ns  THS=$_ths ns"
puts "build:  DSP48E2=$_dsp   RAMB36=$_ram36  RAMB18=$_ram18  URAM288=$_uram"
puts "build:  Power  : $_pwr_mode -> $_pwr_file"
puts "build:  ----------------------------------------------------------"
puts "build:  GATE (CLAUDE.md §8): methodology rows ~= $_meth_n , DRC viol = $_drc_n"
if {$_meth_n == 0 && $_drc_n == 0} {
    puts "build:  GATE: PASS — zero methodology + zero DRC."
} else {
    puts "build:  GATE: NOT CLEAN — triage reports/methodology.rpt + reports/drc.rpt."
}
puts "build:  reports written to $_reports_dir"
puts "build: =========================================================="
