# -----------------------------------------------------------------------------
# run_tb_dense_array_bank.tcl   (R6.6)
#
# Unit test for the BRAM accumulator bank (dense_array_bank, BATCH_T=64 -> BRAM
# path): drives the RMW + drain ports with a faithful continuous-GEMM model and
# checks per-token distinct outputs, first-touch reset, and unused-column zeroing.
# Elaborates in <1s (no PE fabric).
#
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/run_tb_dense_array_bank.tcl
#
# Expect: "tb_dense_array_bank: PASS (... checks, 0 errors)".
# -----------------------------------------------------------------------------
source C:/Users/user/Desktop/ArchBetter/src/scripts/add_sources.tcl
set_property top tb_dense_array_bank [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
launch_simulation
