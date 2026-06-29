# -----------------------------------------------------------------------------
# assign_ku5p_pins.tcl  -  board-less, deterministic pin LOC assignment for the
#                          XCKU5P (xcku5p-ffvd900-3-e) headline closure.
#
# Hooked as STEPS.PLACE_DESIGN.TCL.PRE on impl_1 by build_ku5p.tcl. At this point
# the implemented design is open (post-synth/opt), every top-level port exists,
# and the package/device database is loaded, so PACKAGE_PIN literals can be read
# straight from the DEVICE — they are guaranteed legal for ffvd900 without hard-
# coding BGA ball names. This clears DRC UCIO-1 (unconstrained logical port)
# HONESTLY (real LOCs that survive to write_bitstream), superseding the
# severity-downgrade in relax_io_drc.tcl (kept as a harmless safety net).
#
# Policy (CLAUDE.md sec 10/11): pin LOCATIONS are board-specific and owned by the
# team. These are placeholder-but-legal sites for the board-less part-level
# closure ONLY: clk_in -> a clock-capable (GC) site so it can legally drive the
# MMCM; all other (quasi-static, low-toggle) control pins -> general-purpose HP
# I/O. The IOSTANDARD (LVCMOS18) is already set in physical_ku5p.xdc. When a real
# board bank plan lands (PACKAGE_PIN lines in physical_ku5p.xdc), those ports are
# skipped here automatically (this script never overrides an existing LOC), and
# the hook can be removed.
# -----------------------------------------------------------------------------

puts "assign_ku5p_pins: assigning board-less placeholder pin LOCs from the device DB"

# --- Build the package-pin pools straight from the loaded device --------------
# General-purpose user I/O only (excludes power/ground/config/MGT/dedicated).
set gp_all [get_package_pins -quiet -filter {IS_GENERAL_PURPOSE}]
if {![llength $gp_all]} {
    error "assign_ku5p_pins: no general-purpose package pins found — is the design open with a part set?"
}

# Clock-capable site for clk_in — must satisfy BOTH placer rules that an MMCM
# source pin imposes. A naive IS_GLOBAL_CLOCK filter does NOT (it flags HDIO
# "HDGC" pins and both diff sides), and it picked the HDIO N-side pin A5 ->
# DRC PLHDIO-4 + PLIO-9. Required instead:
#   * NOT an HDIO bank: HDIO global-clock pins (PIN_FUNC token "HDGC") cannot
#     drive a PLL/MMCM/BUFGCE_DIV — there are no such sites in HDIO banks
#     (PLHDIO-4). HP/HR global-clock pins use the token "GC" without the "HD".
#     Note "HDGC" *contains* the substring "GC", so we must exclude HDGC first.
#   * P-side of the CCIO differential pair: for a single-ended clock only the
#     P-side may drive a clock buffer (PLIO-9). P-side pins read "IO_L<n>P..".
# Self-contained PIN_FUNC filter (no bank-type queries): keep pins whose
# function contains GC but not HDGC, and that are the L<n>P (P) side.
set cc_pins {}
foreach p $gp_all {
    set fn [get_property -quiet PIN_FUNC $p]
    if {[string match {*HDGC*} $fn]}  { continue }   ;# HDIO clock pin: can't drive MMCM (PLHDIO-4)
    if {![string match {*GC*}  $fn]}  { continue }   ;# not global-clock-capable
    if {![regexp  {IO_L[0-9]+P} $fn]} { continue }   ;# N-side: only P drives a clk buffer (PLIO-9)
    lappend cc_pins $p
}

set cc_pins [lsort $cc_pins]
set gp_pins [lsort $gp_all]

# --- Helper: pop the first pin from a pool that is not already taken -----------
set ::_taken {}
proc _pop_pin {pool_name} {
    upvar 1 $pool_name pool
    while {[llength $pool]} {
        set pin  [lindex $pool 0]
        set pool [lrange $pool 1 end]
        if {[lsearch -exact $::_taken $pin] < 0} {
            lappend ::_taken $pin
            return $pin
        }
    }
    return ""
}

# --- clk_in: clock-capable site (only if still unconstrained) ------------------
set n_assigned 0
if {[llength [get_ports -quiet clk_in]]} {
    if {[get_property PACKAGE_PIN [get_ports clk_in]] eq ""} {
        set pin [_pop_pin cc_pins]
        if {$pin eq ""} {
            puts "assign_ku5p_pins: WARNING no GC pin found; clk_in falls back to a general-purpose site"
            set pin [_pop_pin gp_pins]
        }
        set_property PACKAGE_PIN $pin [get_ports clk_in]
        incr n_assigned
        puts "assign_ku5p_pins:   clk_in -> $pin (clock-capable)"
    }
}

# --- Every other unconstrained top-level port: general-purpose I/O -------------
foreach port [lsort [get_ports *]] {
    if {$port eq "clk_in"} continue
    if {[get_property PACKAGE_PIN [get_ports $port]] ne ""} continue   ;# board plan owns it
    set pin [_pop_pin gp_pins]
    if {$pin eq ""} {
        error "assign_ku5p_pins: ran out of general-purpose package pins before '$port'"
    }
    set_property PACKAGE_PIN $pin [get_ports $port]
    incr n_assigned
}

puts "assign_ku5p_pins: assigned $n_assigned port(s); UCIO-1 should now be clean"
