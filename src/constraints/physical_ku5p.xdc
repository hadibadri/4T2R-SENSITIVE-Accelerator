# =============================================================================
# physical_ku5p.xdc  -  ArchBetter C4 BOARD/DEVICE physical constraints
#                       for the HEADLINE prototype: XCKU5P (xcku5p-ffvd900-3-e).
#
# This is the device-SPECIFIC half of the device-split (CLAUDE.md §11): only
# PACKAGE_PIN / IOSTANDARD and the floorplan live here. The portable timing
# (clocks, false paths, I/O delays) is in timing_portable.xdc and is shared
# unchanged with physical_vu9p.xdc.
#
# Device facts that shape this file:
#   * XCKU5P is a MONOLITHIC single-die part (NOT SSI). There is exactly one
#     SLR, so a single-SLR floorplan pblock is a NO-OP here — the hook below is
#     present for symmetry with physical_vu9p.xdc but stays disabled. Do NOT add
#     a pblock on KU5P without a measured congestion reason.
#   * Package FFVD900 (900-ball). Bank/pin selection is owned by the team
#     (CLAUDE.md §10); all PACKAGE_PIN literals below are <TBD> until a board is
#     chosen. Leave entries COMMITTED-but-COMMENTED so the file is never empty.
#   * The DDR4 MIG (C5) owns its OWN generated XDC for the DDR PHY pins. Those
#     pins are NOT listed here — only the board CONTROL pins of soc_top are.
#
# Closure top: archbetter_soc_top. Pinnable boundary = { clk_in, ext_rst_n,
# narrow cfg bus, program_done, (debug) locked_o/compute_clk_o }. The AXI seam
# is internal to the MIG and never reaches a package pin.
# =============================================================================

# -----------------------------------------------------------------------------
# Board oscillator + reset  (clk_in MUST land on a clock-capable (CC) pin)
# -----------------------------------------------------------------------------
# set_property -dict { PACKAGE_PIN <TBD_CC> IOSTANDARD LVCMOS18 } [get_ports clk_in]
# set_property -dict { PACKAGE_PIN <TBD>    IOSTANDARD LVCMOS18 } [get_ports ext_rst_n]

# -----------------------------------------------------------------------------
# Narrow control/loader bus (32-bit cfg port + status)
#   cfg_we (1), cfg_addr[7:0], cfg_wdata[31:0], cfg_rdata[31:0], program_done (1)
# Low-toggle, quasi-static — any general-purpose bank with matching VCCO works.
# -----------------------------------------------------------------------------
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports cfg_we]
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports program_done]
# # cfg_addr[*] / cfg_wdata[*] / cfg_rdata[*] : assign per board bank plan, e.g.
# # set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports {cfg_addr[0]}]
# #   ... through cfg_addr[7], cfg_wdata[0..31], cfg_rdata[0..31].

# -----------------------------------------------------------------------------
# Debug observability (optional; route to header/LED bank or leave SoC-internal)
# -----------------------------------------------------------------------------
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports locked_o]
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports compute_clk_o]

# -----------------------------------------------------------------------------
# Floorplan  (single-SLR pblock hook)
#
# DISABLED on XCKU5P: monolithic single-die, no SLR crossing exists, so a
# pblock cannot help and may hurt. The hook is documented here only so the
# device-split stays symmetric with physical_vu9p.xdc, where it is ACTIVE.
# -----------------------------------------------------------------------------
# (no pblock on KU5P)

# -----------------------------------------------------------------------------
# I/O standards  (board-less closure — ACTIVE)
#
# Every top-level port gets a defined IOSTANDARD so the design is electrically
# complete and write_bitstream's NSTD-1 check passes. LVCMOS18 is a safe,
# bank-agnostic default for these low-toggle control pins; the value is NOT
# board-committed and is overridden when a real board bank plan lands above
# (the PACKAGE_PIN -dict lines, currently <TBD>).
#
# PACKAGE_PIN (LOC): pin LOCATIONS are board-specific (CLAUDE.md §10/§11) and
# stay TBD here until a board is chosen. For the board-less closure they are
# assigned PROGRAMMATICALLY from the device DB by src/scripts/assign_ku5p_pins.tcl
# (a place_design PRE hook): clk_in -> a clock-capable site, the control pins ->
# general-purpose HP I/O — guaranteed-legal ffvd900 sites that clear DRC UCIO-1
# honestly (real LOCs surviving to write_bitstream). To commit a real board
# pinout, add PACKAGE_PIN -dict lines in the bank-plan section above (the script
# never overrides an already-LOC'd port) and drop the hook.
# -----------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS18 [get_ports clk_in]
set_property IOSTANDARD LVCMOS18 [get_ports ext_rst_n]
set_property IOSTANDARD LVCMOS18 [get_ports cfg_we]
set_property IOSTANDARD LVCMOS18 [get_ports {cfg_addr[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports {cfg_wdata[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports {cfg_rdata[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports program_done]
set_property IOSTANDARD LVCMOS18 [get_ports locked_o]

# -----------------------------------------------------------------------------
# DDR4 PHY pins  ->  owned by the MIG-generated XDC (C5). Not listed here.
# -----------------------------------------------------------------------------
