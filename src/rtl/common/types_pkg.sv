
`timescale 1ns/1ps
`ifndef ARCHBETTER_TYPES_PKG_SV
`define ARCHBETTER_TYPES_PKG_SV
`default_nettype none

package types_pkg;
    localparam int unsigned DENSE_ARRAY_ROWS   = 128;
    localparam int unsigned DENSE_ARRAY_COLS   = 128;
    localparam int unsigned DENSE_GROUP_ROWS   = 16;
    localparam int unsigned DENSE_GROUP_COLS   = 16;
    localparam int unsigned DENSE_GROUPS_ROW   = DENSE_ARRAY_ROWS / DENSE_GROUP_ROWS;
    localparam int unsigned DENSE_GROUPS_COL   = DENSE_ARRAY_COLS / DENSE_GROUP_COLS;
    localparam int unsigned DENSE_GROUPS_TOTAL = DENSE_GROUPS_ROW * DENSE_GROUPS_COL;
    localparam int unsigned DENSE_PE_PER_GROUP = DENSE_GROUP_ROWS * DENSE_GROUP_COLS;
    localparam int unsigned DENSE_PHYS_GROUPS_ROW   = 1;
    localparam int unsigned DENSE_PHYS_GROUPS_COL   = 2;
    localparam int unsigned DENSE_PHYS_ROWS         = DENSE_GROUP_ROWS * DENSE_PHYS_GROUPS_ROW;
    localparam int unsigned DENSE_PHYS_COLS         = DENSE_GROUP_COLS * DENSE_PHYS_GROUPS_COL;
    localparam int unsigned DENSE_LOGICAL_TILE_ROWS = DENSE_ARRAY_ROWS / DENSE_PHYS_ROWS;
    localparam int unsigned DENSE_LOGICAL_TILE_COLS = DENSE_ARRAY_COLS / DENSE_PHYS_COLS;
    localparam int unsigned DENSE_LOGICAL_TILES_TOTAL = DENSE_LOGICAL_TILE_ROWS * DENSE_LOGICAL_TILE_COLS;
    localparam int unsigned URAM_BANKS       = 4;
    localparam int unsigned URAM_WIDTH_BITS  = 72;
    localparam int unsigned URAM_DEPTH       = 4096;
    localparam int unsigned URAM_ADDR_W      = $clog2(URAM_DEPTH);
    localparam int unsigned BFP12_MANT_W  = 12;
    localparam int unsigned BFP12_EXP_W   =  8;
    localparam int unsigned BFP12_BLK     = 16;
    localparam int unsigned DENSE_ACC_W   = 32;

    typedef logic signed [BFP12_MANT_W-1:0] bfp12_mant_t;
    typedef logic signed [BFP12_EXP_W-1:0]  bfp12_exp_t;
    typedef logic signed [DENSE_ACC_W-1:0]  dense_acc_t;
    localparam int unsigned BFP12_PROD_W = 2 * BFP12_MANT_W;
    typedef logic signed [BFP12_PROD_W-1:0] bfp12_prod_t;
    localparam int unsigned GROUP_ACC_W = 40;
    typedef logic signed [GROUP_ACC_W-1:0] group_acc_t;
    localparam int unsigned ARRAY_ACC_W = 44;
    typedef logic signed [ARRAY_ACC_W-1:0] array_acc_t;
    typedef enum logic {
        GEMM_SNAP_PER_TOKEN = 1'b0,
        GEMM_SNAP_CONTINUOUS = 1'b1
    } gemm_stream_mode_e;
    localparam int unsigned DENSE_MACC_LAT      = 4;
    localparam int unsigned DENSE_PE_SNAP_REGS  = 1;
    localparam int unsigned DENSE_GROUP_OUT_REGS = 1;
    localparam int unsigned DENSE_CONT_RESULT_LAT =
        DENSE_MACC_LAT + DENSE_PE_SNAP_REGS + DENSE_GROUP_OUT_REGS;
    typedef struct packed {
        bfp12_exp_t                  shared_exp;
        bfp12_mant_t [BFP12_BLK-1:0] mant;
    } bfp12_block_t;
    localparam int unsigned BFP12_BLOCK_W = BFP12_EXP_W + BFP12_BLK * BFP12_MANT_W;
    localparam int unsigned DENSE_PP_URAM_WIDE = 4;
    localparam int unsigned DENSE_PP_URAM_W    = DENSE_PP_URAM_WIDE * URAM_WIDTH_BITS;
    localparam int unsigned DENSE_PP_LEAF_SEL_W = $clog2(DENSE_PP_URAM_WIDE);
    localparam int unsigned TLMM_TILE              = 16;
    localparam int unsigned TLMM_SUBTILE           = 4;
    localparam int unsigned TLMM_SUBTABLES_PER_TILE = TLMM_TILE / TLMM_SUBTILE;
    localparam int unsigned TLMM_SUBTABLE_ADDR_W   = TLMM_SUBTILE;
    localparam int unsigned TLMM_SUBTABLE_DEPTH    = (1 << TLMM_SUBTABLE_ADDR_W);
    localparam int unsigned TLMM_SUB_ENTRY_W = BFP12_MANT_W + $clog2(TLMM_SUBTILE);
    localparam int unsigned TLMM_SUB_PART_W  = TLMM_SUB_ENTRY_W + 1;
    localparam int unsigned TLMM_TILE_PART_W = TLMM_SUB_PART_W + $clog2(TLMM_SUBTABLES_PER_TILE);
    localparam int unsigned TLMM_ACC_W = 32;
    localparam int unsigned TLMM_LANES = 16;

    typedef enum logic [1:0] {
        TERN_ZERO = 2'b00,
        TERN_POS  = 2'b01,
        TERN_NEG  = 2'b11,
        TERN_RSVD = 2'b10
    } tern_weight_e;
    typedef tern_weight_e [TLMM_TILE-1:0]    tern_tile_t;
    typedef tern_weight_e [TLMM_SUBTILE-1:0] tern_subtile_t;
    typedef logic signed [TLMM_SUB_ENTRY_W-1:0] tlmm_sub_entry_t;
    typedef logic signed [TLMM_SUB_PART_W-1:0]  tlmm_sub_part_t;
    typedef logic signed [TLMM_TILE_PART_W-1:0] tlmm_tile_part_t;
    typedef logic signed [TLMM_ACC_W-1:0]       tlmm_acc_t;
    typedef bfp12_mant_t [TLMM_SUBTILE-1:0] tlmm_subtile_act_t;
    typedef bfp12_mant_t [TLMM_TILE-1:0]    tlmm_tile_act_t;
    typedef tern_tile_t [TLMM_LANES-1:0] tern_lane_tiles_t;
    typedef tlmm_tile_part_t [TLMM_LANES-1:0] tlmm_part_vec_t;
    typedef tlmm_acc_t [TLMM_LANES-1:0] tlmm_acc_vec_t;
    localparam int unsigned MACRO_OPC_W  =  6;
    localparam int unsigned MACRO_WORD_W = 64;
    localparam int unsigned MACRO_CNT_W  = 10;
    localparam int unsigned BATCH_TOK_W = 8;
    typedef logic [BATCH_TOK_W-1:0] tok_idx_t;

    typedef enum logic [MACRO_OPC_W-1:0] {
        OP_NOP         = 6'h00,
        OP_BARRIER     = 6'h01,
        OP_EOP         = 6'h02,
        OP_CFG_NOC     = 6'h08,
        OP_COMMIT_NOC  = 6'h09,
        OP_LD_W_URAM   = 6'h10,
        OP_LD_A_URAM   = 6'h11,
        OP_ST_OUT      = 6'h12,
        OP_PINGPONG    = 6'h13,
        OP_GEMM_DENSE  = 6'h20,
        OP_GEMM_ALL    = 6'h21,
        OP_GEMM_LAYER  = 6'h22,
        OP_GEMM_BATCH  = 6'h23,
        OP_FFN_TLMM    = 6'h28,
        OP_ACT_NL      = 6'h30,
        OP_LAYERNORM   = 6'h31,
        OP_SOFTMAX     = 6'h32,
        OP_KV_WRITE    = 6'h38,
        OP_KV_READ     = 6'h39
    } macro_opc_e;
    typedef struct packed {
        macro_opc_e  opc;
        logic [7:0]  tile_id;
        logic [7:0]  path_id;
        logic [9:0]  row_cnt;
        logic [9:0]  col_cnt;
        logic [9:0]  k_cnt;
        logic [11:0] flags;
    } macro_instr_t;
    `define ARCHBETTER_STATIC_ASSERT(cond) \
        generate if (!(cond)) begin : static_assert_fail \
            $error("static assertion failed: ", `"cond`"); \
        end endgenerate
    localparam int unsigned FLG_BANK_SEL_LSB = 0;
    localparam int unsigned FLG_BARRIER      = 1;
    localparam int unsigned FLG_PRIORITY_LSB = 2;
    localparam int unsigned FLG_QUANT_LSB    = 5;
    localparam int unsigned FLG_IS_SPARSE    = 8;
    localparam int unsigned FLG_GEMM_CONTINUOUS = 9;
    localparam int unsigned FLG_RSVD_LSB     = 10;
    localparam int unsigned NOC_NODES        = 64;
    localparam int unsigned NOC_NODE_ID_W    = $clog2(NOC_NODES);
    localparam int unsigned NOC_PATH_HANDLES = 32;
    localparam int unsigned NOC_PATH_ID_W    = $clog2(NOC_PATH_HANDLES);
    localparam int unsigned NOC_DATA_W = BFP12_BLK * BFP12_MANT_W;
    localparam int unsigned NOC_USER_W = 8;
    typedef logic [NOC_NODES-1:0] noc_mask_t;

    typedef struct packed {
        logic [NOC_NODE_ID_W-1:0] src_node;
        noc_mask_t                dst_mask;
        logic [2:0]               priority_lvl;
        logic                     is_multicast;
    } noc_path_cfg_t;
    typedef enum logic [1:0] {
        CFG_NOC_MASK_LO = 2'b00,
        CFG_NOC_MASK_HI = 2'b01,
        CFG_NOC_META    = 2'b10,
        CFG_NOC_RSVD    = 2'b11
    } cfg_noc_chunk_e;
    typedef enum logic {
        BANK_A = 1'b0,
        BANK_B = 1'b1
    } bank_sel_e;

    typedef struct packed {
        bank_sel_e compute_side;
        bank_sel_e fill_side;
        logic      fill_done;
        logic      swap_pending;
    } pingpong_state_t;
    localparam int unsigned DRAM_ADDR_W = 32;
    localparam int unsigned DRAM_BEAT_W = URAM_WIDTH_BITS;
    localparam int unsigned DRAM_LEN_W  = 16;

    typedef struct packed {
        logic                    compressed;
        logic                    is_sparse;
        logic [URAM_ADDR_W-1:0]  uram_base;
        logic [DRAM_ADDR_W-1:0]  dram_base;
        logic [DRAM_LEN_W-1:0]   n_beats;
    } csd_descriptor_t;
    typedef struct packed {
        logic [URAM_ADDR_W-1:0] dense_act_base;
        logic [URAM_ADDR_W-1:0] tlmm_base;
        logic [URAM_ADDR_W-1:0] out_base;
    } layer_desc_t;
    localparam int unsigned KV_DATA_W = 144;
    localparam int unsigned KV_DEPTH  = 16384;
    localparam int unsigned KV_ADDR_W = $clog2(KV_DEPTH);

endpackage : types_pkg

`default_nettype wire
`endif
