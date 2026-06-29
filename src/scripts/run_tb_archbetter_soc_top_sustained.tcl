# -----------------------------------------------------------------------------
# run_tb_archbetter_soc_top_sustained.tcl
#
# C6 step 1 of 3: run the SUSTAINED full-grid workload through the closed SoC
# wrapper and confirm it PASSES (self-checking, same golden as the proven
# tb_archbetter_soc_top). A green run here proves the stimulus is known-good
# BEFORE we layer SAIF capture (step 2) and SAIF-annotated report_power (step 3)
# on top of it.
#
# Workload: N_LAYERS=8 DISTINCT-data dense(+sparse) layers, back to back, captured
# into ONE SAIF. Each layer = 8x2 = 16-tile residency-safe dense layer (full 128
# rows) reused over 32 tokens (512 GEMM iterations) + real CSD DRAM fills, with
# layer-seeded distinct weights/activations and per-layer AXI-seam self-check. The
# dispatcher is single-shot per reset (OP_EOP -> S_DONE forever), so each layer
# re-arms by a reset pulse. NOT the full 8x4 grid: the dense weight working set must
# fit ONE ping-pong residency (uram_cascade_adapter consumer index bounded to
# [0,2047]); 8x4 overflows it (ACT_CASC_BASE=2048). All 512 PEs run every tile.
#
# Run it from the Vivado Tcl console:
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/run_tb_archbetter_soc_top_sustained.tcl
#
# Expect: "tb_archbetter_soc_top_sustained: PASS  (8 layers, 1080 checks, 0 errors)".
# ~8 x 25k = ~200k cycles total (~4 min real on a desktop); well inside the
# N_LAYERS-scaled watchdog. Each layer prints its own program_done + verify line.
# -----------------------------------------------------------------------------
source C:/Users/user/Desktop/ArchBetter/src/scripts/add_sources.tcl
set_property top tb_archbetter_soc_top_sustained [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
launch_simulation
