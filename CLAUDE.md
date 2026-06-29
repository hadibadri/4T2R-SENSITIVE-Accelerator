# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Prime directive.** Every change must preserve the simulation-first discipline and the zero-warning quality bar. If a request would introduce unverified RTL, premature optimization, or behavior that cannot be expressed as a clean hardware contract, push back rather than comply silently.

---

## 0. Project mission

**ArchBetter** is a next-generation edge-LLM accelerator prototyped on **Xilinx Kintex UltraScale+ XCKU5P** (`xcku5p-ffvd900-3-e`) in **Vivado 2025.2**. The prototype is the vehicle for an elite-tier journal submission (target: *IEEE TVLSI*, *IEEE TCAS-I*, or peer venue with best-paper trajectory).

**Headline claim — two axes, both required.**
1. **Beat the digital edge-LLM cohort** — FlightLLM, TeLLMe, EdgeLLM — on the combined frontier of **time-to-first-token × throughput × energy-efficiency × latency × GOPS/mm²**, not on any single axis. This is the apples-to-apples comparison.
2. **Frame the analog-CIM ceiling honestly.** The 4T2R ReRAM CIM macro (28 nm, 81 kb, voltage-to-digital, 59–95.3 TOPS/W) is the silicon ceiling our digital twin is calibrated against; it is **not** an apples-to-apples comparison (analog tile, no system-level overhead). The contribution is the **SoC the CIM macro is missing**: dispatcher, NoC, sparse hybrid, KV cache, ping-pong, drift-refresh — the full system that a CIM tile slots into when fabricated. Do not claim TOPS/W parity with the analog macro on FPGA; reviewers will catch it.

**Three primary novelties (what makes this a best-paper candidate).**
- **Weight Shredding Oracle (§2.5)** — per-tile EWMA usage tracking + threshold-driven precision demotion (BFP12 → BFP8 → BFP6 → ternary → 0) with a promote-on-error perplexity insurance path. No edge-LLM accelerator does this.
- **AC-Assisted In-Situ Drift Refresh with 4T2R Common-Mode Cancellation (§2.6)** — refresh-during-compute by exploiting the differential cell topology to reject AC stimulus as common mode. Sub-µW class power overhead (TBD-pending-simulation).
- **qN → BFP12 dequant at the URAM fill boundary (§2.7)** — Q4_K / Q5_K / Q6_K / Q8_0 Llama / TinyLlama models served directly without perplexity degradation; 12-bit BFP mantissa is the explicit insurance margin against per-tile re-quantization rounding.

All three must close on silicon-credible RTL with **zero DRC and zero methodology warnings** (advisories triaged per §5).

Everything in this file is load-bearing. Future Claude sessions should treat it as the architectural source of truth and should update it (not drift from it) when design decisions evolve.

## 1. Target device & resource budget (xcku5p-ffvd900-3-e)

| Resource        | Available       | Headroom target | Rationale                                   |
|-----------------|-----------------|------------------|---------------------------------------------|
| CLB LUTs        | ~216,960        | ≤ 70%            | leave room for CLB-level routing            |
| Flip-Flops      | ~433,920        | ≤ 60%            | registered pipelines, skid buffers          |
| DSP48E2 slices  | 1,824           | ≤ 80%            | dense BFP12 mantissa MACs only; sparse core must use 0 DSP |
| Block RAM (36K) | 480 (~2.1 MB)   | ≤ 70%            | KV cache, small on-chip scratchpads         |
| UltraRAM (288K) | 64 (~18.4 Mb)   | ≤ 75%            | quad-bank ping-pong weight/activation store |
| Global clocks   | 24              | ≤ 50%            | single compute clock + memory clock         |

**Utilization policy:** we deliberately under-utilize. Pushing any resource above its headroom invites router congestion, long hold paths, and methodology warnings. A lower-utilization design that meets timing and DRC-clean beats a maximalist design that needs `--no_check` to close.

**Clocking intent (preliminary):** one compute clock for the compute fabric; a separate memory clock for DRAM/URAM refill. All CDC must go through proper XPM macros or `xpm_cdc_*` primitives — never ad-hoc synchronizers.

## 2. Architectural pillars

### 2.1 Hybrid SoC with Macro-Instruction Dispatcher (FlightLLM-style, asymmetric pipelining)

- A single **Macro-Instruction Dispatcher** consumes a compact ISA (64-bit macro words, see `types_pkg::macro_instr_t`) and fans out sub-ops to four targets: **Memory Manager**, **Dense Core**, **Sparse Core**, **NoC**.
- Pipelining is **asymmetric**: the Dense Core pipeline is deep (multi-stage BFP mantissa MAC → accumulate → normalize) while the Sparse Core pipeline is shallow (single-cycle LUT fetch + adder tree). The Dispatcher interleaves issue slots to hide the Sparse Core's idle bubbles in the Dense Core's wall-clock tail.
- Dispatcher issues **configuration before execution**: NoC paths are committed, ping-pong banks are chosen, and tile counts are latched *before* any streaming data flows. No per-beat routing decisions.

### 2.2 Heterogeneous compute cores

**Dense Core — BFP12 Grouped Vector Systolic Array over a 4T2R CIM Digital Twin**

> **Logical vs physical — read this before touching dense_array.sv.** A literal spatial 128×128 = 16384-PE array would need ≈32k DSPs (each PE infers ~2 DSP48E2: one mantissa multiply + one INT32 accumulator) on a 1824-DSP device. That is impossible. The architecture below is **logical 128×128, physical 16×32 (two `dense_group` instances side-by-side in the column dimension), time-multiplexed 32×**. Anyone who reads "128×128" as "instantiate 16384 PEs in generate" has misread the spec — the previous `dense_array.sv` made exactly that mistake and has been refactored.

- **Logical shape**: `128 × 128` element matrix-vector throughput per layer, partitioned into a **logical 8 × 4 grid of 16 × 32 tiles** (`DENSE_LOGICAL_TILES_ROW × DENSE_LOGICAL_TILES_COL = 8 × 4`).
- **Physical shape**: **two** `dense_group` instances (each 16 × 16 = 256 PEs) placed side-by-side in the column dimension to form a 16 × 32 = 512-PE physical kernel. **Phase-8 fused MACC (done):** each PE is now a single fully-pipelined DSP48E2 (AREG/BREG/MREG/PREG) doing multiply-and-temporal-accumulate via the internal P-register — **512 DSP48E2 total ≈ 28% of the 1824-DSP device** (was 1024 at 2 DSP/PE; the fusion cleared DPIP-2/DPOP-3/DPOP-4 and freed room to grow to 4 physical groups). **Phase-8b** then split the DSP48E2 input register into both built-in stages (A1+A2 / B1+B2) to clear DPIP-2 and shorten the operand setup path. The fused MACC therefore has a **4-cycle latency** (a_in → A1 → A2 → M-reg → P-reg), so the post-stream drain before `acc_snap` is **3 cycles** (dispatcher `S_GEMM_DRAIN = GEMM_DRAIN_CYCLES = 3`). The accumulator lives inside `cim_cell_4t2r`'s DSP; `dense_pe` is the snapshot wrapper.
- **Time-multiplex**: the dispatcher walks the logical 8×4 tile grid in raster order; each logical tile reuses the same two-group physical kernel. The 32-tile schedule is the layer's inner loop. Tile residency latency is hidden under URAM ping-pong fill.
- Each PE is a **digital twin** of a 4T2R memristor-based neuromorphic CIM cell: Ohm's-law GEMM modeled in fixed point, with injection points for future noise/non-idealities so the twin can be calibrated against real silicon once fabricated. The same noise hooks carry the AC-refresh stimulus from §2.6.
- Arithmetic: **BFP12** — 12-bit signed mantissa per element, 8-bit shared signed exponent per block of 16 elements. Mantissa×mantissa multiply **and** the K-dimension temporal accumulation are fused into a single **DSP48E2** per PE (multiply in the M-register, INT32 accumulate in the P-register, load-vs-accumulate selected by the pipelined `acc_clr`). Element widths are runtime-configurable down to BFP6 to support the shred ladder in §2.5.
- **Dataflow**: **weight-streaming with output-stationary tile accumulation**. For each logical tile (gr, gc) in [0..7]×[0..3]:
  1. Weights for tile (gr, gc) are streamed from the dense URAM ping-pong (CLAUDE.md §2.3) into the physical kernel's PE registers (512 weights × 12 bits ≈ 6 Kbits per tile, parallel-row scan or serial scan-in).
  2. Activations for group-row gr are broadcast via the NoC and consumed in lockstep by both physical groups.
  3. Each physical group produces a 16-column `group_acc_t` partial; together they form a 32-wide physical strip.
  4. The 32-wide partial is added into a **persistent array-level accumulator bank** of 128 `array_acc_t` accumulators, indexed by global column `c = gc * 32 + phys_col`, staying live across all 8 row-tiles.
  5. After all 8 row-tiles for a column-strip have been visited (`tile_gr` reaches 7), the column-strip's portion of the `array_acc_t` bank holds the final result. After all 4 column-strips have been visited, the full 128-column `y_out` is drained and `y_valid` pulses.
- **The single most important invariant — group-local accumulation — still holds.** Partial sums never leave the physical 16×16 group on the global interconnect. Only fully-reduced 16-wide column outputs cross the array boundary. The output-stationary array accumulator is a *register file*, not a spatial reduction tree, and lives outside the group's PE fabric.
- **Why this beats a literal spatial array on KU5P**: same logical throughput per layer, 32× less DSP, fits the device with 56% headroom for shred / refresh / quant logic, and the time-multiplex mechanism naturally exposes the per-tile addressing the Weight Shredding Oracle (§2.5) needs to demote unused tiles. Phase-9 may scale to **4 physical groups** once the PE is reduced to 1 DSP/PE; the macro-ISA tile schedule absorbs that scaling without RTL changes outside the array harness.

**Sparse Core — TLMM (Table-Lookup Matrix Multiplication) for ternary FFN**
- Weights are ternary `{-1, 0, +1}` (see `types_pkg::tern_weight_e`).
- FFN multiplies are replaced by **pre-computed sum tables** stored in **LUTRAM / SRL primitives**; the weight pattern forms the address, and the table emits the signed sum of selected activations.
- **Zero DSP48E2 usage in this core.** If RTL for the sparse core instantiates a DSP, that is a bug, not a trade-off.
- Tile size `TLMM_TILE = 16` activations per lookup is the default; larger tiles explode table depth, smaller tiles kill efficiency.

### 2.3 Memory & Interconnect

**URAM staging (4 ping-pong banks + 1 OUT staging = 5 URAMs total)**
- Compute-side ping-pong: **bank 0, 1 → Dense Core** (compute/fill pair); **bank 2, 3 → Sparse Core** (compute/fill pair). These 4 banks are the input weight/activation staging.
- Result-side staging: **`u_out_uram` → dense_out_collector**. The dense layer result drains here before DRAM write-back (and forwarding to the dense2sparse FIFO for FFN). Sized for one-layer's worth of `array_acc_t` outputs; uses URAM (not BRAM) because the drain-to-DRAM bandwidth profile matches URAM's native 8-read / 8-write per cycle.
- **Total URAM utilization at Phase-7d synth: 5 / 64 (≈ 8 %)** — well under the 75 % headroom. There is significant room to grow (e.g. weight pre-staging for shred-promotion latency hiding, KV-cache spill, multi-layer pipelining).
- The **CSD (Compressed Sparse Dense) engine** handles DRAM → URAM background fills, decompressing on the fly so DRAM bandwidth sees only compressed traffic. Phase-8 extends this to qN→BFP12 dequant per §2.7.
- Compute side and fill side swap on dispatcher command (`OP_PINGPONG`), after a drain handshake with the consuming core — see `pingpong_if` below.

**Circuit-switched streaming NoC (Blackwell B200 style)**
- The Dispatcher hard-configures physical paths **before** layer execution (`OP_CFG_NOC`). Once a path is committed, routers become pure muxes — no per-flit arbitration, no AXI-style transaction layer, no routing tables walked at run time.
- Multicast paths are expressed as a destination bitmask (`types_pkg::noc_mask_t`). A multicast beat is only accepted when all selected destinations are ready (hold-on-backpressure invariant), unless an explicit skid stage is configured.
- **No AXI.** The NoC uses a lean `data / valid / ready / last (+ user)` contract; any use of AXI-Lite / AXI-Stream / AXI4 inside the accelerator fabric is a design-review block.

**KV cache**
- Managed by **Global BRAM** (not URAM — URAM is reserved for weights/activations). The KV cache is written via `OP_KV_WRITE` and read via `OP_KV_READ`; its address map is owned by the Memory Manager.

### 2.4 Dataflow summary

```
DRAM ──CSD──▶ URAM{0,1}(Dense ping-pong) ──▶ Dense Core ──NoC multicast──▶ Sparse Core (via dense2sparse_if FIFO)
                      URAM{2,3}(Sparse ping-pong) ─────────▲
                                                           │
                                      Dispatcher (macro-ISA) drives all pre-exec config
                                      BRAM (KV cache) ◀─── KV read/write ops
                                      BRAM (Shred usage table) ──▶ Shred Controller (§2.5)
                                      AC stim DAC ──▶ cim_cell_4t2r noise hooks (§2.6)
```

### 2.5 Weight Shredding Oracle — perplexity-aware on-chip memory reclamation

**Problem.** A served LLM uses many of its weights essentially never. KV-cache eviction is well-studied; weight-level adaptive precision is not, and is the single largest unexploited memory-efficiency lever on edge LLM hardware. This is a primary novelty of ArchBetter and has no analog in FlightLLM, TeLLMe, or EdgeLLM.

**Mechanism — two-tier EWMA + threshold-driven precision demotion.**

- **Per-tile usage counter.** Every 16×16 weight tile (matching the dense_group residency unit and the BFP-block exponent grain) carries a 12-bit Morris-style counter `u`. On every dispatch of that tile, `u ← u − (u >> k) + ACCESS_PULSE`. This is a stochastic EWMA — the bit-shift makes decay multiplicative, the pulse makes recency dominant. O(1) per access; no heap maintenance, no random access patterns. The 12-bit counter table is BRAM-resident, depth = total tile count, single-port.
- **Periodic shred sweep** (every `SHRED_EPOCH` tokens, default 1024). The `shred_controller` walks the counter table once and assigns a precision class to each tile via four thresholds:
  - `u > T_keep` → BFP12 (full precision)
  - `T_dim < u ≤ T_keep` → BFP8 (mantissa truncated to 8b)
  - `T_pen < u ≤ T_dim` → BFP6 (mantissa truncated to 6b)
  - `T_zero < u ≤ T_pen` → ternary; tile re-routed through TLMM (§2.2 Sparse Core)
  - `u ≤ T_zero` → zeroize; URAM range freed for reuse
- **Demotion happens during URAM ping-pong fill.** When a fill brings a tile in from DRAM, the shred class read alongside the descriptor decides the on-load mantissa width. No extra read port, no extra latency — the demotion is hidden in the existing fill path.
- **Promote-on-error path.** The dense post-processing path includes a residual-error monitor: a periodic high-precision shadow computation on a small fraction of tiles compares BFPN result against BFP12 reference. A residual above `T_residual` increments a "demerit" counter on the demoted tile and triggers promotion back up the ladder. This is the **perplexity insurance policy** — it prevents over-aggressive demotion from drifting the model.
- **Why not a min-heap.** The user's first instinct was a min-heap; min-heaps cost O(log N) per access and produce random-access BRAM patterns that fight burst-friendly URAM fill. EWMA + periodic sweep is O(1) per access and sequential on the sweep — cache-friendly, primitive-friendly, and well-grounded (Flajolet 1985 approximate counting; modern OS page-replacement uses the same trick).

**Hardware location.** `shred_controller` lives inside `memory_manager`, owns the usage-counter BRAM, and drives precision-class side-band into the dense URAM fill path. Adds a new opcode `OP_SHRED_SWEEP` to the macro-ISA (one-shot per epoch).

**Contract assertions.** A demoted tile that the residual monitor flags must reach BFP12 within one epoch. A zeroized tile that is requested non-zero is a contract violation (`$error`).

### 2.6 AC-Assisted In-Situ Drift Refresh — compute-during-refresh via 4T2R common-mode rejection

**Problem.** Memristive (HfO2/TaOx ReRAM, PCM) cells drift conductance over time as oxygen vacancies and metallic ions diffuse out of the conductive filament. This is the single largest reliability limit on analog CIM macros and a known cap on inference accuracy. Standard mitigations (periodic re-write, halt-and-refresh) cost throughput.

**Mechanism — physically defensible reframing of the user's "thermal tractor beam" intuition.**
- A small AC stimulus (frequency, amplitude TBD by SPICE-level simulation in the cim_cell_4t2r noise hooks; target operating point: amplitude well below `V_set/2`, frequency above the dielectric relaxation knee) is applied on WL/BL by a low-resolution DAC clocked off the system clock.
- Effect: AC stimulation maintains electrochemical equilibrium of vacancies/ions at the filament–matrix boundary; moderate, geometrically-localized Joule heating provides the activation energy for **defect annealing** (recombination of mismatched vacancies). The earlier framing of "Soret effect tractor beam pulling atoms back" has a sign problem (the Soret coefficient for most metal-ion-in-oxide systems is thermophobic — ions move toward *colder* regions, not toward the hot center). The AC-anneal mechanism described here is the literature-supported version of the same intent.
- Refresh stays inside the cell timing budget — it's a sub-percent duty cycle, not a halt.

**Architectural novelty (the SoC-level claim, distinct from device physics).**
- The 4T2R cell topology has two memristors in a differential pair with a column-bottom differential sense amp. The AC stimulus is applied **balanced** on both legs.
- A balanced AC signal is **common mode** to the differential sense amp, which rejects it (≥40 dB CMRR achievable with careful matching) without halting the read. Refresh therefore proceeds **during compute**, not between compute phases.
- This is the primary architectural contribution of this pillar: **refresh-during-compute is enabled by exploiting the differential cell topology**, not by stealing cycles from the dispatcher. Throughput cost ≈ zero. Power overhead claim: target **<1.5 µW per active cell at refresh duty cycle**, **TBD pending simulation in cim_cell_4t2r noise hooks** — this number does not enter any paper or claim until the simulation supports it.

**Hardware.** `drift_refresh_controller` schedules per-bank refresh sweeps and drives the AC pattern into the existing `cim_cell_4t2r` noise-hook injection ports (CLAUDE.md §2.2 already specifies these injection points; this is what they are for). Adds opcode `OP_REFRESH_TICK` (idle-loop background, dispatcher fires it at fixed cadence).

**Publication strategy.** The SoC paper (this repo's TVLSI submission) cites a separate device-physics letter on the AC mechanism and CMRR measurement (target *Nature Electronics* / *IEEE EDL*). Do not conflate the two contributions.

**Discipline rule.** The µW power, refresh frequency, and amplitude numbers stay marked **TBD-pending-simulation** in this file until the noise-hook simulation produces them. No hand-waved numbers in the paper. If a future Claude session is tempted to fill in a number from training data, **don't**.

### 2.7 Quantization & Format Pipeline — qN → BFP12 at the URAM fill boundary

**Why this is part of the architecture, not an afterthought.** Every model the user wants to serve (Llama 3 8B, TinyLlama 1B, …) ships in q4 / q5 / q6 / q8 quantization. The dense PE array natively multiplies BFP12. The conversion has to happen on-chip without leaking perplexity, and the conversion cost has to be hidden under existing latency.

**Two formats, two roles.**

| Tier         | Format                                    | Why                                                            |
|--------------|-------------------------------------------|----------------------------------------------------------------|
| DRAM         | Q4_K / Q5_K / Q6_K / Q8_0 / native BFP12  | bandwidth + capacity (8B params don't fit on-chip otherwise)   |
| URAM         | BFP12 (12-bit mantissa, shared 8-bit exp per 16) | what the dense PE array multiplies                       |
| TLMM weights | Ternary {−1, 0, +1}                        | sparse-core path (§2.2)                                        |

**The CSD engine is the dequant boundary.** §2.3 already specifies "decompressing on the fly" as the CSD's job; we extend this from sparsity-only to **format dequantization**. A new `csd_dequant` micro-pipeline inside `csd_drain_engine` handles per-format conversion as DRAM blocks land in URAM.

**Hard architectural invariant — block-size discipline.**
- `BFP_BLOCK_SIZE = 16` (already a parameter).
- Source quantization group size must be ≥ 16 (Q4_K = 32 or 256, Q5_K = 32, Q6_K = 16, Q8_0 = 32 — all valid).
- **Rule**: BFP destination block ≤ source quant group. Violating this forces re-quantization with collapsed dynamic range and is a perplexity leak. Synth-time check: every supported format's group size is parameterized and asserted at elaboration.

**Per-format dequant.**
- **Q8_0 (per-block fp16 scale):** sign-extend int8 mantissa, fold scale into BFP exponent. One shifter per lane.
- **Q6_K / Q5_K (per-group fp16 scale + min):** unpack nibble→signed, multiply by scale, add min, re-block into 16-mantissa BFP groups picking the max-magnitude exponent of the 16. One small multiplier per lane (NOT a DSP — sparse-core-style LUT-based shift-and-add for the scale fold-in).
- **Q4_K (super-block scale + per-sub-block scale):** two-stage; super-block scale folds into BFP exponent, sub-block scale rounds the mantissa.

**Activation outliers.** Llama-class activations have channel outliers that blow out a BFP exponent if blocked naively. Two stacked mitigations:
1. **SmoothQuant-style channel rotation** absorbed into the static layer descriptor at compile time. Free at runtime.
2. **Per-strip activation BFP grouping at the multicast NoC drop** — the 16-wide activation strip is already the unit we broadcast; each strip becomes its own BFP group.

**Validation gate.** Golden Python reference loads a real Q4_K Llama tensor, runs reference dequant → BFP12, bit-compares against RTL. PPL regression sweep is part of the eval section of the paper. **No format ships first-class until its golden-vs-RTL bitmatch passes.**

**Macro-ISA hooks.** New fields on `csd_descriptor_t`: `quant_fmt`, `group_size`, `scale_stride`, `zero_point_stride`. New enum `quant_fmt_e` in `types_pkg`: `Q4_K, Q5_K, Q6_K, Q8_0, BFP12_NATIVE, TERNARY_TLMM`.

## 3. Execution strategy (non-negotiable order)

1. **Hardware contracts first.** Parameters → types → interfaces. No module RTL is written until the interface it consumes/produces is frozen in `interfaces.sv` and its types are in `types_pkg.sv`.
2. **Module + testbench, bottom-up.** Each module ships with its own testbench in `src/tb/` mirroring its location in `src/rtl/`. Order: `cim_cell` → `pe` → `group` → `sparse_core` tile → `noc_router` → `dispatcher` → `memory_manager` → `top`.
3. **End-to-end simulation must pass** (all testbenches green, including a top-level integration TB) before any synthesis run is launched.
4. **Synthesis only after sim-clean.** Then the bar is **zero critical warnings** in `synth_design` and `report_methodology -checks {all}`; non-critical warnings must be triaged and either fixed or waived with a written justification in `src/scripts/waivers.tcl`.
5. **Implementation gating.** Only proceed to `impl_1` after synth is clean. `report_drc` must be empty at route.

Deviating from this order (e.g. "let me quickly synthesize this to see what happens") is how methodology warnings accumulate. Don't.

## 4. Repository layout

```
src/
├── rtl/
│   ├── common/          types_pkg.sv, interfaces.sv, utility packages
│   ├── dispatcher/      macro-instruction decoder + issue logic
│   ├── dense_core/
│   │   ├── cim_cell/    4T2R digital twin
│   │   ├── pe/          PE wrapping a CIM cell with BFP12 mantissa MAC
│   │   ├── group/       16×16 systolic group with group-local INT32 accumulator (the PHYSICAL kernel)
│   │   └── array/       1× physical group + tile-mux harness + array-level array_acc_t bank (logical 128×128, see §2.2)
│   ├── sparse_core/     TLMM engine, ternary sum tables, adder tree
│   ├── memory/          quad-URAM ping-pong, CSD engine (incl. csd_dequant per §2.7),
│   │                    BRAM KV cache, shred_controller (§2.5), drift_refresh_controller (§2.6)
│   ├── noc/             circuit-switched router, multicast fabric
│   └── top/             SoC top, clock/reset, pin bindings
├── tb/                  mirrors rtl/ one-for-one; every rtl module has a tb
├── params/              static configuration (.svh) and generator scripts
├── scripts/             Vivado TCL: add_sources.tcl, build.tcl, sim.tcl, waivers.tcl
└── constraints/         .xdc: pins, timing, clocks, false/multicycle paths
```

Rule: **every RTL module has a peer testbench** in `src/tb/`. A module without a testbench does not exist.

## 5. Vivado flow (all run from project root)

Open GUI:
```bash
vivado project_1.xpr
```

Load all sources into the project's filesets (run once after the tree grows):
```tcl
source src/scripts/add_sources.tcl
```

Compile-order note: `src/rtl/common/*.sv` (packages) must be added and ordered before any consumer. `update_compile_order -fileset sources_1` after every `add_files`.

Headless simulation of a specific TB:
```tcl
set_property top <tb_module> [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
launch_simulation
```

Batch synth → impl → bitstream (only after sim is clean):
```tcl
reset_run synth_1
launch_runs synth_1 -jobs 8;  wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8;  wait_on_run impl_1
```

Reports that gate quality:
```tcl
open_run impl_1
report_methodology -checks {all} -file reports/methodology.rpt
report_drc                        -file reports/drc.rpt
report_timing_summary -warn_on_violation -file reports/timing.rpt
report_utilization                -file reports/util.rpt
report_cdc                        -file reports/cdc.rpt
```

## 6. RTL coding standards (what "zero warnings" means in practice)

These are enforced on every file; a PR that violates them is not merged.

- **Language level:** SystemVerilog (IEEE 1800-2017), `-sv` compile. No Verilog-2001 fallback.
- `` `default_nettype none `` at the top of every `.sv` file; `` `default_nettype wire `` restored at EOF only if strictly required for a legacy include.
- **Always-blocks:**
  - Combinational → `always_comb`, never `always @*`.
  - Sequential → `always_ff @(posedge clk)` with a single clock. **Synchronous active-low reset** by convention (`rst_n`), because UltraScale+ FFs prefer sync reset; only use async reset when an external pin mandates it, and document why.
  - Latches → forbidden. Every `always_comb` assigns every driven signal on every path (use a `default:` or pre-assignment at block top).
- **Case statements:** use `unique case` (or `unique0 case` when a default-nop is intentional). Always include a `default:` arm, even under `unique` — this is the Vivado methodology rule.
- **Types:** `logic` only (not `wire`/`reg`). Signed arithmetic uses explicit `signed` types from `types_pkg`. No bare bit-widths in RTL — use typedefs or parameters.
- **Resets:** all flops have a defined reset value. No uninitialized state.
- **Clock domain crossings:** XPM only (`xpm_cdc_single`, `xpm_cdc_handshake`, `xpm_fifo_async`). Ad-hoc two-flop synchronizers are flagged by `report_cdc`.
- **Interfaces:** every module boundary uses a SystemVerilog `interface` with explicit `modport`, or a struct-typed port list. No loose signal bundles.
- **Assertions:** every interface file carries handshake assertions (`assert property`) guarded by `` `ifndef SYNTHESIS ``. Every FIFO has fill/overflow/underflow asserts.
- **DSP48E2 inference:** dense PE multiplies use the `(* use_dsp = "yes" *)` hint on the mantissa×mantissa multiply expression. Sparse core has `(* use_dsp = "no" *)` on its adder tree.
- **Resource hints:** `(* ram_style = "ultra" *)` for URAM arrays, `"block"` for BRAM, `"distributed"` for LUTRAM used by TLMM tables.
- **Parameters vs macros:** prefer `parameter` / `localparam`; `` `define `` is reserved for include guards and `SYNTHESIS` flags.
- **No magic numbers.** All widths, depths, and counts come from `types_pkg` or a local `localparam`.

## 7. Naming conventions

| Kind                  | Convention         | Example                       |
|-----------------------|--------------------|-------------------------------|
| File                  | `snake_case.sv`    | `dense_pe.sv`                 |
| Module                | `snake_case`       | `module dense_pe`             |
| Interface             | `snake_case_if`    | `interface pingpong_if`       |
| Package               | `snake_case_pkg`   | `package types_pkg`           |
| Parameter / localparam| `UPPER_SNAKE`      | `BFP12_MANT_W`                |
| Signal                | `snake_case`       | `rd_addr`, `swap_req`         |
| Typedef               | `snake_case_t`     | `bfp12_mant_t`                |
| Enum                  | `snake_case_e`, members `UPPER_SNAKE` | `bank_sel_e::BANK_A` |
| Active-low reset      | `rst_n`            | always single-syllable        |
| Testbench             | `tb_<dut>`         | `tb_dense_pe`                 |

## 8. Journal-grade quality bar — explicit asks

When in doubt about a design choice, optimize for the following in this order:

1. **Correctness** — bit-exact vs golden reference in sim.
2. **Methodology cleanliness** — zero `report_methodology` warnings.
3. **Timing closure with headroom** — ≥ 10% WNS slack at target frequency.
4. **Area** — we are bounded by XCKU5P; a smaller design at the same throughput wins the paper.
5. **Throughput** — must exceed FlightLLM / TeLLMe / EdgeLLM on the shared benchmark set.
6. **Latency** — measured as dispatcher issue to first output token; must be below prior art.
7. **Energy efficiency** — captured via `report_power` in the eval section.

Never trade (1) or (2) for anything lower.

## 9. Workflow checklist for every new module

Before writing a line of module RTL, confirm all of:

- [ ] All types the module touches exist in `types_pkg.sv`.
- [ ] All ports use interfaces from `interfaces.sv` (or a new interface has been added there, reviewed, and asserted on).
- [ ] The testbench skeleton exists under `src/tb/…` with at least a directed test and a random test wrapping a golden reference.
- [ ] The module's resource class is declared (which DSP / RAM / SRL primitives it should infer).
- [ ] The module's latency contract (issue→output cycles) is written in its header comment.

After the module RTL is written:

- [ ] All testbenches for this module pass in XSim.
- [ ] Lint via `check_syntax` and `synth_design -rtl -rtl_skip_mlo` on the module alone is clean.
- [ ] `report_cdc` is empty for any multi-clock module.
- [ ] CLAUDE.md is updated if any architectural contract changed.

## 10. Device & toolchain invariants

- Vivado 2025.2, XSim as the sim default, `xil_defaultlib` as the default library.
- `EnableCoreContainer=FALSE` — IP is stored expanded; check in `.xci` only, never generated products.
- No `BoardPart` — this is a part-level project; pinouts live in `src/constraints/*.xdc` and are owned by the team, not by a board file.
- The `.xpr` is managed by Vivado; do not hand-edit. Source-of-truth changes go through `src/scripts/*.tcl`.

## 11. Platform & closure strategy (KU5P headline, VU9P validation)

**Two devices, two roles — do not conflate them.**
- **XCKU5P (`xcku5p-ffvd900-3-e`) is the HEADLINE prototype.** All published efficiency / area / GOPS-mm² / power numbers are reported on KU5P, because the paper's claim is **edge-LLM** and KU5P is an edge-credible Kintex part. The §1 budget table is KU5P and stays the reference.
- **XCVU9P is HARDWARE VALIDATION ONLY.** The user will eventually run the real architecture (and TinyLlama) on an UltraScale+ **VU9P** dev board. VU9P is a datacenter-class Virtex part (3-SLR SSI) — it is **not** an edge device and must **never** be the headline number, or the edge framing collapses. It exists to prove the design runs on real silicon.
- Both are UltraScale+, so the RTL is **already portable** (`DSP48E2` / `URAM288` / `RAMB36` / `MMCM` exist on both). The KU5P→VU9P move is: change the part, regenerate the DDR4 MIG for the board, swap the physical `.xdc`, and add a single-SLR `pblock` (the design is ~3-4% of VU9P, so floorplan it into one SLR to avoid SLL-crossing). The timing `.xdc` ports unchanged.

**Closure direction — get OUT of OOC.** The OOC builds (`set_ooc_mode.tcl`) are a stopgap: `archbetter_top`/`archbetter_core` expose ~6564 internal signals as ports, which cannot fit 386 package pins, forcing `-mode out_of_context`. OOC numbers are **fabric-only** — no I/O, no clock tree, partial DRC, and (uniquely) **power is unpublishable** because it is vectorless AND OOC. The journal artifact requires a **non-OOC, fully-pinned, clocked** implementation. Build it via a thin top wrapper `archbetter_soc_top` that:
- bundles the wide host ports behind a **narrow control/loader interface** (imem, CSD descriptors, layer base addrs, start/done) so the design fits on pins;
- adapts the accelerator's native `csd_dram_if`/`csd_dram_wr_if` to an **AXI4 master** seam, with the **DDR4 MIG as a swappable block** behind it (the only board-specific block);
- generates the compute clock from a board oscillator via an **MMCM** with a synchronized reset.

`archbetter_soc_top` is the only file that sees board specifics; everything at `archbetter_core` and below stays untouched across KU5P↔VU9P.

**Power-evidence standard:** post-route **vectored** `report_power`, SAIF-annotated from a *representative* full-layer/sustained sim (gold-standard variant uses post-route timing-sim SAIF). Hierarchy-scope the report to the accelerator; DRAM/MIG declared external (accelerator-core power boundary). A vectorless number never enters the paper (§2/§8). A SAIF over a non-representative toy workload (e.g. the K=1 single matrix-vector) is equally inadmissible — the workload must keep the dense array genuinely busy.
