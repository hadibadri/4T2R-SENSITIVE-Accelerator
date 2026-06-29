# -----------------------------------------------------------------------------
# add_sources.tcl
#
# Register ArchBetter RTL and testbench files with the Vivado filesets and
# enforce compile order. Source from anywhere; the script locates the project
# root via its own on-disk path (info script), so Vivado's pwd does not matter:
#
#     vivado project_1.xpr
#     source C:/Users/user/Desktop/ArchBetter/src/scripts/add_sources.tcl
#
# This script is idempotent: re-sourcing after adding new files is the
# standard workflow. Files missing on disk are skipped silently so partial
# check-outs do not abort the script.
# -----------------------------------------------------------------------------

# Resolve the project root from this script's own location:
#   <root>/src/scripts/add_sources.tcl  ->  <root>
set _script_abs [file normalize [info script]]
set _proj_root  [file dirname [file dirname [file dirname $_script_abs]]]
puts "add_sources: project root = $_proj_root"

proc _ab_add_to_fileset {fileset rel_path} {
    global _proj_root
    set abs_path [file normalize [file join $_proj_root $rel_path]]
    if {![file exists $abs_path]} {
        puts "add_sources: skipped (missing) $rel_path"
        return
    }
    # Avoid double-adds.
    set existing [get_files -quiet -of_objects [get_filesets $fileset] $abs_path]
    if {[llength $existing] == 0} {
        add_files -norecurse -fileset $fileset $abs_path
    }
    set_property file_type SystemVerilog \
        [get_files -of_objects [get_filesets $fileset] $abs_path]
}

# -----------------------------------------------------------------------------
# Design sources (sources_1) — packages first, then interfaces, then modules.
# -----------------------------------------------------------------------------
set _rtl_packages {
    src/rtl/common/types_pkg.sv
}
set _rtl_interfaces {
    src/rtl/common/interfaces.sv
    src/rtl/common/axi4_if.sv
}
set _rtl_modules {
    src/rtl/dense_core/cim_cell/cim_cell_4t2r.sv
    src/rtl/dense_core/pe/dense_pe.sv
    src/rtl/dense_core/group/dense_group.sv
    src/rtl/dense_core/array/dense_array_bank.sv
    src/rtl/dense_core/array/dense_array.sv
    src/rtl/dense_core/streamer/dense_act_streamer.sv
    src/rtl/dense_core/streamer/dense_weight_streamer.sv
    src/rtl/dense_core/collector/dense_out_collector.sv
    src/rtl/sparse_core/tile/sparse_tile.sv
    src/rtl/sparse_core/driver/tlmm_driver.sv
    src/rtl/sparse_core/collector/sparse_out_collector.sv
    src/rtl/noc/d2s_fifo/dense2sparse_fifo.sv
    src/rtl/memory/csd_drain/csd_drain_engine.sv
    src/rtl/noc/noc_router.sv
    src/rtl/noc/noc_fabric.sv
    src/rtl/dispatcher/dispatcher.sv
    src/rtl/memory/uram_bank.sv
    src/rtl/memory/uram_pingpong.sv
    src/rtl/memory/uram_cascade_adapter.sv
    src/rtl/memory/csd_engine.sv
    src/rtl/memory/csd_wide_fill.sv
    src/rtl/memory/axi/axi4_read_adapter.sv
    src/rtl/memory/axi/axi4_write_adapter.sv
    src/rtl/memory/axi/axi4_bram_slave.sv
    src/rtl/memory/kv_bram.sv
    src/rtl/memory/memory_manager.sv
    src/rtl/top/soc_ctrl_loader.sv
    src/rtl/top/archbetter_top.sv
    src/rtl/top/archbetter_core.sv
    src/rtl/top/archbetter_soc_top.sv
    src/rtl/top/archbetter_ku5p_top.sv
}

foreach f [concat $_rtl_packages $_rtl_interfaces $_rtl_modules] {
    _ab_add_to_fileset sources_1 $f
}

# -----------------------------------------------------------------------------
# Simulation sources (sim_1) — testbenches.
# -----------------------------------------------------------------------------
set _tb_files {
    src/tb/dense_core/tb_cim_cell_4t2r.sv
    src/tb/dense_core/tb_dense_pe.sv
    src/tb/dense_core/tb_dense_group.sv
    src/tb/dense_core/tb_dense_array.sv
    src/tb/dense_core/tb_dense_array_bank.sv
    src/tb/dense_core/tb_dense_act_streamer.sv
    src/tb/dense_core/tb_dense_weight_streamer.sv
    src/tb/dense_core/tb_dense_out_collector.sv
    src/tb/sparse_core/tb_sparse_tile.sv
    src/tb/sparse_core/tb_tlmm_driver.sv
    src/tb/sparse_core/tb_sparse_out_collector.sv
    src/tb/noc/tb_dense2sparse_fifo.sv
    src/tb/memory/tb_csd_drain_engine.sv
    src/tb/noc/tb_noc_router.sv
    src/tb/noc/tb_noc_fabric.sv
    src/tb/dispatcher/tb_dispatcher_noc.sv
    src/tb/dispatcher/tb_dispatcher_compute.sv
    src/tb/dispatcher/tb_dispatcher_mem.sv
    src/tb/dispatcher/tb_dispatcher_full.sv
    src/tb/dispatcher/tb_dispatcher_layer.sv
    src/tb/dispatcher/tb_dispatcher_batch_cont.sv
    src/tb/memory/tb_uram_bank.sv
    src/tb/memory/tb_uram_pingpong.sv
    src/tb/memory/tb_uram_cascade_adapter.sv
    src/tb/memory/tb_csd_wide_fill.sv
    src/tb/memory/tb_csd_engine.sv
    src/tb/memory/axi4_dram_model.sv
    src/tb/memory/tb_axi4_dram_adapter.sv
    src/tb/memory/tb_axi4_bram_slave.sv
    src/tb/memory/tb_kv_bram.sv
    src/tb/memory/tb_memory_manager.sv
    src/tb/top/tb_soc_ctrl_loader.sv
    src/tb/top/tb_archbetter_top.sv
    src/tb/top/tb_archbetter_core.sv
    src/tb/top/tb_archbetter_core_cont.sv
    src/tb/top/tb_archbetter_soc_top.sv
    src/tb/top/tb_archbetter_soc_top_sustained.sv
    src/tb/top/tb_archbetter_ku5p_top.sv
}

foreach f $_tb_files {
    _ab_add_to_fileset sim_1 $f
}

# -----------------------------------------------------------------------------
# XPM libraries (xpm_fifo_sync etc.). auto_detect_xpm scans the filesets and
# enables only the families actually instantiated.
# -----------------------------------------------------------------------------
auto_detect_xpm

# -----------------------------------------------------------------------------
# Enforce compile order. Packages must elaborate before consumers.
# -----------------------------------------------------------------------------
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# -----------------------------------------------------------------------------
# Default simulation top.
# -----------------------------------------------------------------------------
set_property top tb_dense_group [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Run until the TB calls $finish (or its watchdog $fatal fires). The default
# 1000ns runtime is far too short for the random phase.
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]

# -----------------------------------------------------------------------------
# Clear any SAIF-capture properties on sim_1.
#
# These are PERSISTENT fileset properties. run_tb_archbetter_core_saif.tcl sets
# them to dump activity over the DUT subtree, but once set they leak into EVERY
# subsequent launch_simulation — injecting `open_saif / current_scope /dut /
# log_saif` into the auto-generated tb tcl batch. For any TB whose top-level
# DUT instance is NOT named `dut` (e.g. tb_dispatcher_* use u_disp/u_memmgr),
# `current_scope /dut` throws [Simtcl 6-9] and aborts the batch BEFORE `run all`
# — the test silently never executes. Resetting here makes every normal run
# clean; the SAIF script sources THIS file first, then re-enables capture, so
# its own flow is unaffected.
set_property -name {xsim.simulate.saif}             -value {} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.saif_scope}       -value {} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.saif_all_signals} -value {false} -objects [get_filesets sim_1]

puts "add_sources: [llength [get_files -of_objects [get_filesets sources_1]]] design files, [llength [get_files -of_objects [get_filesets sim_1]]] sim files registered."
puts "add_sources: sim_1 top = [get_property top [get_filesets sim_1]]"
