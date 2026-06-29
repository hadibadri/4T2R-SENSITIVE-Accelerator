# -----------------------------------------------------------------------------
# run_tb_csd_wide_fill.tcl   (R6.8b.2)
#
# Unit test for csd_wide_fill: the narrow-72b -> wide-288b fill assembler that
# groups DENSE_PP_URAM_WIDE (=4) consecutive native fill beats into one wide
# write for the WIDE dense ping-pong. Checks leaf order, wide_addr, and the
# emit cadence (one wide write per WIDE beats). Elaborates in <1s (no fabric).
#
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/run_tb_csd_wide_fill.tcl
#
# Expect: "tb_csd_wide_fill: PASS (... checks, 18 wide writes, 0 errors)".
# -----------------------------------------------------------------------------
source C:/Users/user/Desktop/ArchBetter/src/scripts/add_sources.tcl
set_property top tb_csd_wide_fill [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
launch_simulation
