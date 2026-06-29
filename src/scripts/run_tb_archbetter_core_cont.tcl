# -----------------------------------------------------------------------------
# run_tb_archbetter_core_cont.tcl   (R6.5b)
#
# CONTINUOUS distinct-token end-to-end through archbetter_core: one continuous
# OP_GEMM_BATCH (FLG_GEMM_CONTINUOUS) streams T=8 DISTINCT token activations
# through resident weights and drains T DISTINCT outputs, each checked against its
# own golden (and proven distinct from its neighbour). This exercises the full v2
# path: dispatcher continuous walker + per-token act addressing + tok_out bank RMW.
#
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/run_tb_archbetter_core_cont.tcl
#
# Expect: "tb_archbetter_core_cont: PASS (... checks, 0 errors)".
# -----------------------------------------------------------------------------
source C:/Users/user/Desktop/ArchBetter/src/scripts/add_sources.tcl
set_property top tb_archbetter_core_cont [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
launch_simulation
