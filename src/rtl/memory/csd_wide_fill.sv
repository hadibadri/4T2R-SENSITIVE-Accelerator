// -----------------------------------------------------------------------------
// csd_wide_fill.sv  (R6.8b.2)
//
// Fill-width adapter for the WIDE dense ping-pong. The csd_engine produces a
// narrow 72b fill stream (1 DRAM beat = 1 native word, contiguous addresses).
// The dense ping-pong bank is now DENSE_PP_URAM_WIDE (=4) URAM288 leaves wide
// (DENSE_PP_URAM_W = 288 b) so it can return a whole 4-native block in ONE read
// (the R6.8b II=1 mechanism). This adapter bridges the two: it groups WIDE
// consecutive native beats into one full-width wide write.
//
// Transparent container (design doc §14.8): leaf l of a wide word holds the
// native at wide-word offset l, i.e. wide_word[l*72 +: 72] = native[wide*WIDE+l].
// The stored content (weight OR activation block) is preserved bit-exactly with
// no knowledge of the block structure, so NO DRAM-image / golden re-layout is
// needed - the existing 4-native-per-block image maps 1:1 onto the 4 leaves.
//
//   leaf      = native_addr[SEL_W-1:0]        (power-of-2: WIDE=4 -> addr[1:0])
//   wide_addr = native_addr >> SEL_W
//   emit a wide write on the last leaf (leaf == WIDE-1), merging the WIDE-1
//   accumulated lower leaves with the live last leaf.
//
// Alignment contract (asserted, fail-loud like the csd Phase-2 compressed==0
// rule): the dense fill stream is contiguous within a descriptor and every
// descriptor base / length is WIDE-aligned, so each wide word is assembled from
// WIDE consecutive natives with no mid-group gap. This holds for the weight
// (224 natives/tile) and activation (32 natives/token) images.
//
// Latency: out_wr_* is combinational on the last-leaf beat - the wide write
// fires the same cycle the WIDE-th native arrives (the lower WIDE-1 leaves were
// registered on the preceding beats). No added fill latency vs the narrow path.
//
// Resource class: WIDE-1 leaves of 72b accumulator flops + a little logic. Zero
// DSP / URAM / BRAM / LUTRAM.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef ARCHBETTER_CSD_WIDE_FILL_SV
`define ARCHBETTER_CSD_WIDE_FILL_SV
`default_nettype none

module csd_wide_fill
    import types_pkg::*;
#(
    parameter int unsigned WIDE   = DENSE_PP_URAM_WIDE,  // 4
    parameter int unsigned LEAF_W = URAM_WIDTH_BITS,     // 72
    parameter int unsigned ADDR_W = URAM_ADDR_W          // 12 (native addr in)
) (
    input  wire logic                    clk,
    input  wire logic                    rst_n,

    // Narrow 72b fill in (from csd_engine, gated to the dense branch by the
    // memory_manager). in_wr_addr is the NATIVE word address (uram_base+offset).
    input  wire logic                    in_wr_en,
    input  wire logic [ADDR_W-1:0]       in_wr_addr,
    input  wire logic [LEAF_W-1:0]       in_wr_data,

    // Wide write out (to the dense ping-pong fill port). out_wr_addr is the
    // WIDE-word address (native >> SEL_W).
    output logic                         out_wr_en,
    output logic [ADDR_W-1:0]            out_wr_addr,
    output logic [WIDE*LEAF_W-1:0]       out_wr_data
);

    localparam int unsigned SEL_W  = (WIDE > 1) ? $clog2(WIDE) : 1;
    localparam int unsigned WIDE_W = WIDE * LEAF_W;

    initial begin : elab_checks
        if (WIDE < 2) begin
            $fatal(1, "csd_wide_fill: WIDE=%0d must be >= 2 (use the native fill path directly for WIDE=1)", WIDE);
        end
        if (2**SEL_W != WIDE) begin
            $fatal(1, "csd_wide_fill: WIDE=%0d must be a power of two (leaf = addr[SEL_W-1:0])", WIDE);
        end
    end

    // Leaf index + wide-word address derived from the native address.
    logic [SEL_W-1:0] leaf;
    assign leaf = in_wr_addr[SEL_W-1:0];

    // Accumulate every leaf as it arrives; the last leaf is overlaid live below,
    // so its registered copy is don't-care. Sized WIDE_W to keep the variable
    // part-select range in-bounds for all leaf values.
    logic [WIDE_W-1:0] acc_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_q <= '0;
        end else if (in_wr_en) begin
            acc_q[leaf*LEAF_W +: LEAF_W] <= in_wr_data;
        end
    end

    // Emit on the last leaf: the WIDE-1 lower leaves are in acc_q (registered on
    // the preceding beats); overlay the live last leaf.
    assign out_wr_en   = in_wr_en && (leaf == SEL_W'(WIDE-1));
    assign out_wr_addr = ADDR_W'(in_wr_addr >> SEL_W);

    always_comb begin
        out_wr_data = acc_q;
        out_wr_data[leaf*LEAF_W +: LEAF_W] = in_wr_data;
    end

`ifndef SYNTHESIS
    // -------------------------------------------------------------------------
    // Alignment / contiguity contract. Each wide word must be assembled from
    // WIDE consecutive natives: a beat at leaf != 0 must continue contiguously
    // from the previous beat (no jump into the middle of a group). Restarts at
    // leaf 0 (a new WIDE-aligned descriptor) are allowed.
    // -------------------------------------------------------------------------
    logic [ADDR_W-1:0] prev_addr_q;
    logic              seen_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            prev_addr_q <= '0;
            seen_q      <= 1'b0;
        end else if (in_wr_en) begin
            prev_addr_q <= in_wr_addr;
            seen_q      <= 1'b1;
        end
    end

    a_no_midgroup_jump: assert property (
        @(posedge clk) disable iff (!rst_n)
        (in_wr_en && (leaf != '0) && seen_q) |-> (in_wr_addr == ADDR_W'(prev_addr_q + 1'b1))
    ) else $error("csd_wide_fill: non-contiguous fill at leaf %0d (mid-group gap corrupts the wide word)", leaf);
`endif

endmodule : csd_wide_fill

`default_nettype wire
`endif // ARCHBETTER_CSD_WIDE_FILL_SV
