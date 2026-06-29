# =============================================================================
# physical_vu9p.xdc  -  ArchBetter C4 BOARD/DEVICE physical constraints
#                       for HARDWARE VALIDATION ONLY: XCVU9P.
#
# VU9P is a datacenter-class 3-SLR SSI part used ONLY to prove the architecture
# runs on real silicon (CLAUDE.md §11). It is NEVER the headline number — all
# published efficiency/area/power figures are on KU5P. This file is the VU9P
# counterpart of physical_ku5p.xdc; it shares timing_portable.xdc UNCHANGED.
#
# The KU5P→VU9P move is exactly: change the part, regenerate the DDR4 MIG, swap
# physical_ku5p.xdc -> physical_vu9p.xdc, and ACTIVATE the single-SLR pblock
# below. The portable timing and all RTL at archbetter_core and below are
# untouched.
#
# Device facts:
#   * XCVU9P = 3 SLRs joined by SLLs (super-long-lines). A design that straddles
#     SLRs pays SLL-crossing delay and is hard to time. ArchBetter is ~3-4% of
#     VU9P, so it MUST be floorplanned into ONE SLR (SLR0 below) to avoid SLL
#     crossings entirely — that is the single-SLR pblock.
#   * Pins are board-specific (<TBD>) until a VU9P dev board is chosen.
# =============================================================================

# -----------------------------------------------------------------------------
# Board oscillator + reset (clk_in on a CC pin in/near the target SLR)
# -----------------------------------------------------------------------------
# set_property -dict { PACKAGE_PIN <TBD_CC> IOSTANDARD LVCMOS18 } [get_ports clk_in]
# set_property -dict { PACKAGE_PIN <TBD>    IOSTANDARD LVCMOS18 } [get_ports ext_rst_n]

# -----------------------------------------------------------------------------
# Narrow control/loader bus + status (same logical ports as KU5P)
# -----------------------------------------------------------------------------
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports cfg_we]
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports program_done]
# # cfg_addr[*] / cfg_wdata[*] / cfg_rdata[*] : assign per VU9P board bank plan.

# -----------------------------------------------------------------------------
# Floorplan  (single-SLR pblock — ACTIVE on VU9P)
#
# Confine the whole accelerator to SLR0 so no logic path crosses an SLL. Enable
# once the design is loaded (the cells must exist). The pblock targets the
# core; the MMCM/MIG/clock infrastructure should also be kept in-SLR or on the
# SLR boundary clocking resources per the board's MIG location.
#
# UNCOMMENT for the VU9P bring-up:
#   create_pblock pblock_soc_slr0
#   add_cells_to_pblock [get_pblocks pblock_soc_slr0] [get_cells u_core]
#   resize_pblock       [get_pblocks pblock_soc_slr0] -add SLR0
#   set_property CONTAIN_ROUTING true [get_pblocks pblock_soc_slr0]
#
# If the MIG lands in a different SLR on the chosen board, relax CONTAIN_ROUTING
# and pin only the compute fabric (u_core) to SLR0, letting the MIG AXI cross
# the boundary on a registered SLL path.
# -----------------------------------------------------------------------------
# (pblock disabled until VU9P bring-up)

# -----------------------------------------------------------------------------
# DDR4 PHY pins  ->  owned by the VU9P MIG-generated XDC. Not listed here.
# -----------------------------------------------------------------------------
