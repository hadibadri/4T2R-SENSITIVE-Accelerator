// -----------------------------------------------------------------------------
// uram_bank.sv
//
// UltraRAM bank wrapper (XCKU5P URAM288, 72 b x 4K). Used as the leaf of the
// quad-URAM ping-pong pool driving the Dense and Sparse Cores.
//
// R6.8b: parameter WIDE places WIDE URAM288 leaves side-by-side at the SAME
// address to form a single DATA_W = WIDE*72 read/write per cycle. WIDE=1 (the
// default) is the legacy single-primitive bank. WIDE=3 (DATA_W=216) lets the
// dense activation path read a whole BFP12 block in one cycle (II=1 floor).
//
// Port map:
//   Write port : wr_en / wr_addr / wr_data
//   Read  port : rd_en / rd_addr -> rd_valid / rd_data (2-cycle latency)
//
// Timing contract:
//   A read issued on cycle N (rd_en=1) produces rd_valid=1, rd_data=mem[rd_addr]
//   on cycle N+2. The two-stage pipeline matches the URAM hard macro's own
//   optional output register, so rd_data becomes the primitive's OREG output
//   after place-and-route - this is what lets Vivado infer a clean URAM288
//   with no fabric-built flops in the read path.
//
// Resource class:
//   Exactly WIDE URAM primitives per bank (ram_style="ultra"). Zero DSPs, zero
//   BRAMs, zero LUTRAM. If Vivado reports anything other than WIDE x URAM288 for
//   this module, the inference template has drifted - fix the template, do not
//   change the budget.
//
// Notes on reset:
//   UltraRAM primitives do NOT support reset on their data arrays or OREG.
//   We therefore reset only the rd_valid shadow (which lives in fabric flops).
//   The data pipe gets its initial values from URAM init-to-zero at config
//   time; downstream consumers must not sample rd_valid until after rst_n
//   deasserts, which is the normal cold-start discipline.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_URAM_BANK_SV
`define ARCHBETTER_URAM_BANK_SV
`default_nettype none
`timescale 1ns/1ps

module uram_bank
    import types_pkg::*;
#(
    parameter int unsigned DATA_W = URAM_WIDTH_BITS,  // 72 (total external width)
    parameter int unsigned DEPTH  = URAM_DEPTH,       // 4096
    parameter int unsigned ADDR_W = URAM_ADDR_W,      // 12
    // R6.8b: number of 72b URAM288 leaves placed side-by-side at the SAME address
    // to form a wide read. WIDE=1 is the legacy single-primitive bank (unchanged).
    // WIDE=3 (DATA_W=216) is the dense-activation wide read. DATA_W = WIDE*LEAF_W.
    parameter int unsigned WIDE   = 1
) (
    input  wire logic                clk,
    input  wire logic                rst_n,

    // Write port.
    input  wire logic                wr_en,
    input  wire logic [ADDR_W-1:0]   wr_addr,
    input  wire logic [DATA_W-1:0]   wr_data,

    // Read port (2-cycle registered output).
    input  wire logic                rd_en,
    input  wire logic [ADDR_W-1:0]   rd_addr,
    output logic                     rd_valid,
    output logic [DATA_W-1:0]        rd_data
);

    // Per-leaf width. Each leaf is exactly one URAM288 (<= 72 b).
    localparam int unsigned LEAF_W = DATA_W / WIDE;

    // -------------------------------------------------------------------------
    // Elaboration-time consistency checks.
    // -------------------------------------------------------------------------
    initial begin : elab_checks
        if (ADDR_W != $clog2(DEPTH)) begin
            $fatal(1, "uram_bank: ADDR_W=%0d inconsistent with DEPTH=%0d",
                   ADDR_W, DEPTH);
        end
        if (LEAF_W * WIDE != DATA_W) begin
            $fatal(1, "uram_bank: DATA_W=%0d not divisible by WIDE=%0d", DATA_W, WIDE);
        end
        if (LEAF_W > 72) begin
            $fatal(1, "uram_bank: per-leaf width %0d (DATA_W/WIDE) exceeds URAM primitive width (72)",
                   LEAF_W);
        end
    end

    // -------------------------------------------------------------------------
    // Storage: WIDE URAM288 leaves side-by-side at the same address. Vivado
    // infers one URAM288 per leaf (LEAF_W<=72, DEPTH=4096, ram_style="ultra").
    // The leaves share rd_en/rd_addr/wr_en/wr_addr, so the whole DATA_W word is
    // read or written in a single cycle (this is the R6.8b wide-read mechanism).
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] rd_data_s2;

    for (genvar l = 0; l < int'(WIDE); l++) begin : g_leaf
        (* ram_style = "ultra" *)
        logic [LEAF_W-1:0] mem [DEPTH];

        // Two read-data pipeline stages inside the URAM primitive.
        logic [LEAF_W-1:0] rd_data_s1;
        logic [LEAF_W-1:0] rd_data_leaf_s2;

        always_ff @(posedge clk) begin
            if (wr_en) begin
                mem[wr_addr] <= wr_data[l*LEAF_W +: LEAF_W];
            end
            if (rd_en) begin
                rd_data_s1 <= mem[rd_addr];
            end
            rd_data_leaf_s2 <= rd_data_s1;
        end

        assign rd_data_s2[l*LEAF_W +: LEAF_W] = rd_data_leaf_s2;
    end : g_leaf

    // -------------------------------------------------------------------------
    // rd_valid shadow pipeline (fabric flops, resettable). Shared by all leaves
    // (single rd_en, single 2-cycle latency).
    // -------------------------------------------------------------------------
    logic rd_valid_s1;
    logic rd_valid_s2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_valid_s1 <= 1'b0;
            rd_valid_s2 <= 1'b0;
        end else begin
            rd_valid_s1 <= rd_en;
            rd_valid_s2 <= rd_valid_s1;
        end
    end

    assign rd_valid = rd_valid_s2;
    assign rd_data  = rd_data_s2;

    // -------------------------------------------------------------------------
    // Simulation-only sanity checks.
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    // Write-read-same-address on the same cycle is ambiguous on this hard
    // macro (URAM does not specify read-under-write behavior for collisions).
    // Flag it in sim so the consumer knows to space the accesses.
    property p_no_rw_collision;
        @(posedge clk) disable iff (!rst_n)
        (wr_en && rd_en) |-> (wr_addr != rd_addr);
    endproperty
    a_no_rw_collision: assert property (p_no_rw_collision)
        else $error("uram_bank: write and read to same address on the same cycle (undefined URAM collision)");
`endif

endmodule : uram_bank

`default_nettype wire
`endif // ARCHBETTER_URAM_BANK_SV
