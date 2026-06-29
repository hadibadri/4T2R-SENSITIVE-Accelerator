// -----------------------------------------------------------------------------
// kv_bram.sv
//
// Global BRAM for the KV cache. Simple-dual-port:
//   * Port A : write          (wr_addr, wr_data, wr_en)
//   * Port B : registered read (rd_addr, rd_en -> rd_data, rd_valid)
//
// This is the storage element behind `kv_access_if.slave`. The dispatcher
// drives writes on OP_KV_WRITE and reads on OP_KV_READ; the read consumer is
// the attention block in a future phase.
//
// Latency contract (Phase-8: registered output, 2-cycle read):
//   A read issued on cycle N (rd_en=1) returns rd_data = mem[rd_addr] on
//   cycle N+2 with rd_valid=1. The read uses BOTH BRAM register stages — the
//   mandatory output latch AND the optional output register (OREG). This is
//   what clears the RAMB "no output register merged" methodology advisory
//   (SYNTH-6 ×72, one per BRAM36 in the 144b×16K array): a single-stage read
//   leaves the OREG unused and Vivado flags the sub-optimal BRAM->fabric path.
//   The OREG also shortens the BRAM->fabric combinational hop, which matters
//   once the attention consumer lands on a real timing path. kv_access_if and
//   tb_kv_bram both track the 2-cycle contract.
//
// Resource class:
//   ram_style="block" forces inference of true-dual-port BRAM36 / BRAM18
//   primitives. With KV_DEPTH=16384 and KV_DATA_W=144, Vivado infers a
//   144-bit-wide x 16K-deep array as ~64 BRAM36 primitives (~13% of the
//   XCKU5P BRAM budget).
//
// Resets:
//   Like UltraRAM, BRAM data arrays cannot be reset by fabric logic. We
//   reset only the rd_valid shadow flop. Cold-start reads (before any write
//   to that address) return the BRAM init value (0 by default), which the
//   consumer must not rely on; the dispatcher serializes writes-before-reads
//   on every address.
// -----------------------------------------------------------------------------
`ifndef ARCHBETTER_KV_BRAM_SV
`define ARCHBETTER_KV_BRAM_SV
`default_nettype none
`timescale 1ns/1ps

module kv_bram
    import types_pkg::*;
#(
    parameter int unsigned DATA_W = KV_DATA_W,   // 144
    parameter int unsigned DEPTH  = KV_DEPTH,    // 16384
    parameter int unsigned ADDR_W = KV_ADDR_W    // 14
) (
    input  wire logic clk,
    input  wire logic rst_n,

    kv_access_if.slave kv
);

    // -------------------------------------------------------------------------
    // Elaboration-time consistency.
    // -------------------------------------------------------------------------
    initial begin : elab_checks
        if (ADDR_W != $clog2(DEPTH)) begin
            $fatal(1, "kv_bram: ADDR_W=%0d inconsistent with DEPTH=%0d",
                   ADDR_W, DEPTH);
        end
    end

    // -------------------------------------------------------------------------
    // Storage. ram_style="block" steers Vivado into BRAM18/BRAM36 inference.
    // -------------------------------------------------------------------------
    (* ram_style = "block" *)
    logic [DATA_W-1:0] mem [DEPTH];

    // Two-stage read pipeline. rd_data_q is the BRAM's mandatory output latch;
    // rd_data_q2 is the optional output register (OREG). Both pack INTO the
    // BRAM36 primitive — the OREG is a clean, reset-free, unconditional flop of
    // the latch output, which is the inference pattern Vivado merges. Keeping
    // logic out from between them is what lets it merge (and clears SYNTH-6).
    logic [DATA_W-1:0] rd_data_q;
    logic [DATA_W-1:0] rd_data_q2;
    logic              rd_valid_q;
    logic              rd_valid_q2;

    // Write port (A) and the two read register stages. No reset on the data
    // path (BRAM has no reset on its data array/OREG); the rd_valid shadow is
    // the resettable fabric flop pair.
    always_ff @(posedge clk) begin
        if (kv.wr_en) begin
            mem[kv.wr_addr] <= kv.wr_data;
        end
        if (kv.rd_en) begin
            rd_data_q <= mem[kv.rd_addr];   // BRAM output latch (stage 1)
        end
        rd_data_q2 <= rd_data_q;            // BRAM OREG       (stage 2)
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_valid_q  <= 1'b0;
            rd_valid_q2 <= 1'b0;
        end else begin
            rd_valid_q  <= kv.rd_en;        // valid follows the latch
            rd_valid_q2 <= rd_valid_q;      // valid follows the OREG
        end
    end

    assign kv.rd_data  = rd_data_q2;
    assign kv.rd_valid = rd_valid_q2;

    // -------------------------------------------------------------------------
    // Simulation-only sanity checks. The kv_access_if itself asserts the
    // rd_en -> next-cycle rd_valid contract; this module just guards against
    // the only undefined-behavior case for simple-dual-port BRAM: writing and
    // reading the SAME address on the SAME cycle (Vivado leaves the read
    // result implementation-defined in this case).
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    property p_no_rw_collision;
        @(posedge clk) disable iff (!rst_n)
        (kv.wr_en && kv.rd_en) |-> (kv.wr_addr != kv.rd_addr);
    endproperty
    a_no_rw_collision: assert property (p_no_rw_collision)
        else $error("kv_bram: write and read targeted the same address on one cycle (undefined BRAM read-under-write)");
`endif

endmodule : kv_bram

`default_nettype wire
`endif // ARCHBETTER_KV_BRAM_SV
