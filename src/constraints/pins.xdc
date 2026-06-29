# =============================================================================
# pins.xdc  -  ArchBetter Phase-7c pin / IOSTANDARD assignments  (TEMPLATE)
#
# Target package : xcku5p-ffvd900 (FFVD900, 900-ball flip-chip BGA)
# Bank plan      : TBD - the team owns FPGA bank selection (CLAUDE.md sec 10).
#
# How to use this file
# --------------------
# Every assignment below is COMMENTED. As you decide which pin lands on which
# bank, uncomment the line and replace <TBD> with the real PACKAGE_PIN literal.
# IOSTANDARD recommendations are conservative defaults for an LVCMOS18 host
# interface; swap to LVDS / DDR-style standards once the off-chip PHYs are
# specified.
#
# A few rules that should not be relaxed without justification:
#   * Clock pins go on a CC (clock-capable) pair in a clock-region-adjacent
#     bank. UltraScale+ GTH / GTY banks are NOT general-purpose I/O.
#   * Bank voltage (VCCO) must match the IOSTANDARD on every pin in the bank.
#   * High-fanout, high-toggle outputs (DRAM masters) want BANKS placed near
#     the URAM/BRAM column, not on the opposite die edge.
#
# Quality contract: while this file is template-only, leave it COMMITTED with
# all entries commented. Phase-8 implementation will fail with cryptic errors
# if the constraint set is missing entirely.
# =============================================================================

# -----------------------------------------------------------------------------
# Clock and reset
# -----------------------------------------------------------------------------
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports clk]
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports rst_n]

# -----------------------------------------------------------------------------
# Host control
# -----------------------------------------------------------------------------
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports start]
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports program_done]

# -----------------------------------------------------------------------------
# Instruction memory write port (static config; loaded once before start)
# -----------------------------------------------------------------------------
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports imem_we]
# foreach _i {0 1 2 3 4 5} {
#     set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports imem_wr_addr[$_i]]
# }
# foreach _i {0 1 2 3 ...} {
#     set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports imem_wr_data[$_i]]
# }

# -----------------------------------------------------------------------------
# CSD descriptor table write port (static config)
# -----------------------------------------------------------------------------
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports desc_we]
# foreach _i {0 1 2 3 4 5 6 7} {
#     set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports desc_wr_addr[$_i]]
# }
# # desc_wr_data is a struct (csd_descriptor_t) - flatten via [get_ports desc_wr_data*]

# -----------------------------------------------------------------------------
# Dense weight scan port (static config)
# -----------------------------------------------------------------------------
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports w_we]
# # w_gr / w_gc / w_pe_addr / w_in are buses sized from types_pkg

# -----------------------------------------------------------------------------
# Per-bridge base addresses (semi-static; loaded per layer)
# -----------------------------------------------------------------------------
# # dense_act_base_addr / tlmm_base_addr / out_collector_base_addr buses

# -----------------------------------------------------------------------------
# KV cache sideband
# -----------------------------------------------------------------------------
# # kv_wr_data_i / kv_rd_data_o / kv_rd_valid_o
# # KV_DATA_W is wide; consider routing to a low-skew bank if it becomes critical.

# -----------------------------------------------------------------------------
# Dense-array snap observability
# -----------------------------------------------------------------------------
# # y_out is wide (DENSE_ARRAY_COLS x ARRAY_ACC_W); pin it to a logic-analyzer
# # header bank if exported off-chip, or leave SoC-internal in production.
# # set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS18 } [get_ports y_valid]

# -----------------------------------------------------------------------------
# Dense->Sparse FIFO consumer-side stream (boundary exposure)
# -----------------------------------------------------------------------------
# # d2s_data_o / d2s_user_o / d2s_valid_o / d2s_last_o
# # d2s_ready_i / d2s_almost_full_i

# -----------------------------------------------------------------------------
# DRAM read master  (csd_dram_if)
# -----------------------------------------------------------------------------
# # dram_req_addr / dram_req_len / dram_req_valid / dram_req_ready
# # dram_rsp_data / dram_rsp_valid / dram_rsp_ready / dram_rsp_last
# # NOTE: when the real DDR4 / HBM PHY lands, this group moves to a dedicated
# # XDC owned by the memory IP and these placeholders should be deleted.

# -----------------------------------------------------------------------------
# DRAM write master (csd_dram_wr_if)
# -----------------------------------------------------------------------------
# # dram_wr_req_addr / dram_wr_req_len / dram_wr_req_valid / dram_wr_req_ready
# # dram_wr_wd_data / dram_wr_wd_valid / dram_wr_wd_ready / dram_wr_wd_last
