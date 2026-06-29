# -----------------------------------------------------------------------------
# run_tb_dispatcher_batch_cont.tcl   (R6.4)
#
# Control-plane test of the dispatcher's CONTINUOUS (v2) OP_GEMM_BATCH path
# (FLG_GEMM_CONTINUOUS). Scoreboards the emitted schedule: one load_req per tile,
# T beats/tile at II=1, acc_clr every beat, NO acc_snap, single tile_first/
# tile_last on the corner tiles, stream_mode=CONTINUOUS throughout.
#
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/run_tb_dispatcher_batch_cont.tcl
#
# Expect: "tb_dispatcher_batch_cont: PASS (... checks, 0 errors)".
# -----------------------------------------------------------------------------
source C:/Users/user/Desktop/ArchBetter/src/scripts/add_sources.tcl
set_property top tb_dispatcher_batch_cont [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
launch_simulation
