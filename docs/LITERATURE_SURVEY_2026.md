# ArchBetter Literature Survey — Edge-LLM FPGA & Neuromorphic CIM (as of 2026-06-17)

> **Purpose.** A deeply-sourced sweep of the 2024→2026 edge-LLM accelerator and analog/neuromorphic CIM literature, run to (a) confirm no new baseline dominates ArchBetter's *combined* frontier, (b) sharpen the comparison table with quantitative numbers, and (c) map concrete architecture refinements onto our pillars. Companion to `CLAUDE.md` (§ source of truth) and `docs/ARCHBETTER_MASTERCLASS.md`. Every claim carries a citation; numbers reviewers can check.
>
> **Verdict (TL;DR).** **No single published work beats ArchBetter on the combined frontier** (TTFT × throughput × energy-eff × latency × GOPS/mm²) *and* carries our three SoC novelties. But the field moved in three ways we must answer in related work, none requiring an architecture pivot:
> 1. **MX / MXFP (OCP microscaling) is now the de-facto block-number standard** (OpenAI shipped MXFP4). Our BFP12 must be *positioned against* MX, not presented as if MX doesn't exist.
> 2. **Dynamic/runtime precision is an active area** (DP-LLM, FGMP) — adjacent to the Weight Shredding Oracle but on different axes; our novelty survives, the framing must be explicit.
> 3. **RRAM drift-resilience is active in 2026** (VeRA+) — but everyone does *digital post-hoc* compensation; **no one does physical compute-during-refresh**, so our AC drift-refresh stands strongest of the three.

---

## 0. Threat assessment per ArchBetter novelty (read this first)

| Novelty (CLAUDE.md) | Nearest prior art (2025–26) | What they do | Why ArchBetter still novel | Action |
|---|---|---|---|---|
| **Shred Oracle** (§2.5): per-tile EWMA usage → precision demotion + URAM reclamation + promote-on-error | **DP-LLM** (NeurIPS'25, 2508.06041); **FGMP** (2504.14152); access-freq counters (patents) | DP-LLM: *input-dependent, per-token, layer-wise* precision via a learned error estimator + **fine-tuned** thresholds. FGMP: *static, sensitivity-based* block MXP with HW activation units. Counters: generic memory hotness. | None do **usage-frequency-driven, per-tile precision demotion that frees on-chip memory** with a **hardware promote-on-error perplexity insurance** loop and **no fine-tuning**. DP-LLM = input-driven *compute* precision; ours = usage-driven *memory* reclamation. | Cite DP-LLM + FGMP explicitly in related work; honestly credit Morris/approx-counting (Flajolet'85) for the counter; claim the *reclamation + insurance* combo. Optional: add an input-adaptive hook as future work. |
| **AC drift-refresh** (§2.6): compute-during-refresh via 4T2R common-mode rejection | **VeRA+** (2603.26016, Mar'26); global-correction-factor method; Update-Disturbance-Resilient crossbars; Hamun (2502.01502) | All **digital, post-hoc**: scale the digital output by a measured drift ratio, or train drift-robust, or wear-level. VeRA+ = compact drift-scaling *vectors*. | No one applies a **physical AC anneal stimulus during inference** and rejects it as **common mode** on the differential 4T2R sense amp (zero-throughput-cost in-situ refresh). Ours is *physical/in-situ*; theirs is *digital/after-the-fact*. | Cite VeRA+ as the digital-compensation baseline; frame AC-refresh as the *physical complement* (can stack). Keep µW numbers TBD-pending-sim (discipline rule). |
| **qN→BFP12 dequant** (§2.7): on-chip dequant at URAM fill, 12-bit insurance mantissa | **OCP MX/MXFP** (standard); **F-BFQ** (2510.13401); **MX+** (MICRO'25); **AMXFP4** (ACL'25); MicroMix | MX = shared E8M0 scale per 32-block, micro-FP mantissa (MXFP8 lossless, MXFP4 lossy). F-BFQ = runtime-switchable BFP variants on Kria. | Ours preserves a **12-bit mantissa as explicit re-quant insurance** (block-16 ≤ source group) — a *higher-fidelity* tier than MXFP, *plus* a **dynamic per-tile shred ladder** static MX formats don't have. | **Engage MX head-on**: position BFP12 as the high-fidelity dequant-insurance tier; map the shred ladder rungs (BFP8/BFP6) to MXFP6/MXFP4 vocabulary; consider MXFP-compatibility as future work. This is the biggest framing gap. |

**Bottom line:** plan unchanged. Polish, close C6, then (post-C6) consider the MX-vocabulary alignment and a sparse-attention dataflow as the two highest-value incorporations.

---

## 1. The 2025–2026 edge/embedded LLM FPGA cohort (quantitative)

All numbers single-batch LLaMA2-7B unless noted. **Power scope differs across works** — system (incl. HBM) vs core; flagged. ArchBetter (KU5P) reports **accelerator-core** power with DRAM/MIG external (CLAUDE.md §11), so comparisons must annotate scope.

| Work | Venue / id | Device | Class | Clock | Precision | Throughput | Energy-eff | Power (scope) |
|---|---|---|---|---|---|---|---|---|
| **FlightLLM** | FPGA'24 / 2401.03868 | Alveo U280 | datacenter | **225 MHz** | W4A8 (sparse) | 55 tok/s (U280); 153 tok/s (VHK158) | 1.22 tok/J | 45 W (system+HBM) |
| **EdgeLLM** | TCAD'25 / 2407.21325 | VCU128 | datacenter | ~ (not stated) | FP16×FP16 MHA, FP16×INT4 FFN | 69.4 tok/s | 1.22 tok/J | 56.8 W (system+HBM) |
| **TeLLMe (v1/v2)** | 2504.16266 / 2510.15926 | **KV260** | **edge** | **250 MHz** | ternary 1.58-b W / 8-b A, TLMM | ~9 tok/s @1024-ctx | (≤7 W envelope) | <7 W |
| **PD-Swap** | 2512.11550 | **KV260** | **edge** | ~ | ternary + DPR prefill/decode swap | up to **27 tok/s** | — | KV260 (~few W) |
| **SwiftKV** | 2601.10953 (Jan'26) | (edge MHA accel) | edge | ~ | edge attention | 81.5 tok/s → **1100 GOPS** | **60.12 GOPS/W** | — (beats FlightLLM/EdgeLLM) |
| **LUT-LLM** | FCCM'26 / 2511.06174 | AMD V80 | edge/mid | ~ | act-weight co-quant, 2D LUT | 1.66× < MI210 latency; 32B scalable | 1.72× A100 (1.7B), 2.16× (32B) | — |
| **TENET** | 2509.13765 | Stratix 10 MX | mid | **400 MHz** | sparse ternary LUT + HP cores | 1.45× A100 decode | **4.3× A100 energy** | — |
| **F-BFQ** | 2510.13401 | Kria | edge | ~ | runtime-switchable BFP | 5.2 tok/s (1.4× ARM NEON) | — | edge |
| **FAST-Prefill** | 2602.20515 | Alveo U280 | datacenter | ~ | dynamic sparse attention (prefill) | 2.5× TTFT vs A5000 | 4.5× vs GPU | — |
| **SpeedLLM** | 2507.14139 | (edge FPGA) | edge | ~ | co-design | 4.8× faster | 1.18× lower energy | edge |
| **LlamaF** | 2409.11424 | embedded FPGA | edge | ~ | Llama2, fully-quantized | — | — | edge |

**ASIC ceilings (NOT apples-to-apples — related-work anchors, like our 4T2R macro):**
- **Slim-Llama** (ISSCC'25, KAIST): 28 nm, **4.69 mW**, 3B-param Llama, **9 pJ/param**, 20.25 mm², 500 KB SRAM, binary/ternary, Sparsity-aware LUT (S-LUT) dual-mode + index reordering for bit-transition energy reduction. **Direct conceptual ancestor of our TLMM sparse core** — cite as the silicon proof of the ternary-LUT approach; ArchBetter is its FPGA-mapped form *plus* the dense BFP hybrid + shred + drift SoC.
- **4T2R ReRAM CIM macro** (our existing §ceiling): 28 nm, 81 kb, 59–95.3 TOPS/W. Analog tile, single macro, no system overhead.

---

## 2. Category deep-dives

### 2A. Digital edge-LLM FPGA (the apples-to-apples cohort)
- **FlightLLM** (2401.03868): macro-instruction mapping flow, configurable sparse engine, mixed-precision; the dispatcher/macro-ISA lineage ArchBetter's §2.1 descends from. 225 MHz on U280.
- **EdgeLLM** (2407.21325): CPU-FPGA heterogeneous, **group-systolic** mixed-precision PE array (FP16×FP16 attn, FP16×INT4 FFN). Validates our dense-systolic + heterogeneous-core split. 10–24% over FlightLLM on bandwidth/energy/throughput.
- **TeLLMe v1/v2** (2504.16266 / 2510.15926): the closest *edge* sibling — ternary + **table-lookup matmul (TLMM)** for both prefill & decode on **KV260** at **250 MHz**, ≤7 W. **Our TLMM sparse core is the same family**; differentiate on (a) the *dense BFP hybrid* alongside TLMM, (b) shred oracle, (c) drift refresh, (d) the full SoC fabric (NoC, ping-pong, CSD dequant).
- **PD-Swap** (2512.11550): prefill/decode disaggregation via **Dynamic Partial Reconfiguration** — static TLMM core + reconfigurable attention partition (token-parallel prefill engine vs KV-centric decode engine). 27 tok/s on KV260; decode gain 1.11×→2.02× as context grows. *Relevant to our dispatcher's asymmetric pipelining (§2.1) — we achieve phase specialization via issue-slot interleaving, not DPR; argue our approach avoids reconfiguration latency.*
- **SwiftKV** (2601.10953): edge attention algorithm + multi-head accelerator; **1100 GOPS, 60.12 GOPS/W**, beats FlightLLM/EdgeLLM. Newest throughput bar — add to the table.
- **LUT-LLM** (FCCM'26, 2511.06174): replaces linear layers with **2D table lookups over precomputed dot-products**, activation-weight co-quantization, bandwidth-aware centroid search. >1B params on AMD V80; scales to 32B. *Memory-based-compute neighbor to our TLMM; ours keeps a true BFP arithmetic dense core for fidelity.*
- **FAST-Prefill** (2602.20515): first FPGA long-context prefill with **dynamic sparse attention** + liveness-driven dual-tier KV cache; 2.5× TTFT, 4.5× energy vs GPU. *Strong candidate mechanism to fold into our NoC/attention path post-C6.*

### 2B. LUT / ternary-centric
- **TENET** (2509.13765): **Sparse Ternary LUT (STL)** core with symmetric-precompute table + **high-precision cores** + **Linear-Projection-aware sparse attention** + **dynamic N:M activation sparsity**. FPGA (Stratix 10 MX, 400 MHz) + ASIC; 4.3× A100 energy. **This is the closest architectural sibling to ArchBetter's dense+sparse hybrid** (HP dense core + ternary LUT core). Differentiate on: BFP12 dense (vs their HP cores), shred oracle (they have no adaptive memory reclamation), drift refresh, 4T2R twin.
- **Slim-Llama** (ISSCC'25): see ASIC ceilings above.
- **Platinum** (2511.21910): path-adaptable LUT accelerator for low-bit weight matmul — another LUT competitor; cite in the LUT-family paragraph.

### 2C. Block-number formats & quantization (the MX story — important)
- **OCP Microscaling (MX/MXFP)**: shared **E8M0** scale per **32-element** block + micro-FP elements. **MXFP8 ≈ lossless; MXFP4 lossy** → open challenge. OpenAI cut inference cost ~75% via MXFP4 (2025). **This is now the industry default block format.**
- **MX+** (MICRO'25) & **AMXFP4** (ACL'25): outlier-aware extensions, near-MXFP8 quality at ~4.25 b/elem. **MicroMix**: ≥95% FP16 zero-shot, 20–46% kernel speedup.
- **F-BFQ** (2510.13401): runtime-switchable BFP variants on Kria, 5.2 tok/s. **The closest format-flexibility neighbor to our shred ladder** — but F-BFQ switches *globally*; ours demotes *per tile* by usage.
- **"Pushing the Limits of BFP on Narrow Precision LLM Inference"** (AAAI'25): narrow-BFP outlier problem — supports our per-strip activation BFP grouping (§2.7) and SmoothQuant rotation choices.
- **ScaleBITS** (2602.17698): hardware-aligned mixed-precision bitwidth *search* — compile-time complement to our runtime shred.

**Implication for §2.7 (action):** Reframe the format pipeline to explicitly engage MX: (1) BFP12 = the **high-fidelity dequant-insurance tier** (12-b mantissa, block-16) *deliberately above* MXFP for re-quant safety; (2) the **shred ladder** (BFP8→BFP6→ternary) is a *dynamic per-tile* descent that static MXFP assignment lacks; (3) name MXFP6/MXFP4 as the precision-class analogues of our BFP8/BFP6 rungs so reviewers see the alignment; (4) future-work: MXFP-compatible block mode for ecosystem interop.

### 2D. Dynamic / adaptive precision (Shred Oracle neighbors)
- **DP-LLM** (NeurIPS'25, 2508.06041): per-layer, **per-token**, input-dependent precision via lightweight relative-error estimator + **fine-tuned** thresholds; key insight = layer sensitivity is *not static, changes per decode step*. **Differentiator:** DP-LLM adapts *compute* precision to *input*; Shred Oracle adapts *storage* precision to *access frequency* and *reclaims memory* — orthogonal axes; can coexist. (DP-LLM's "sensitivity is dynamic" finding actually *motivates* our promote-on-error insurance loop — cite it as support.)
- **FGMP** (2504.14152): fine-grained block MXP weight+activation with HW activation-precision units; **static sensitivity-based**, no reclamation.
- **Progressive Mixed-Precision Decoding** (2410.13461): phase-aware progressive precision lowering during decode — temporal analogue; cite.

### 2E. CIM / neuromorphic / ReRAM (the 4T2R-twin context)
- **MXFormer** (2602.12480): **Microscaling-FP Charge-Trap-Transistor CIM** transformer accelerator — *combines MX format + CIM*, the exact intersection of our BFP-twin + block-format story. **Must cite**; differentiate: ArchBetter is a *digital twin on FPGA* (calibratable, deployable now) + drift refresh + shred SoC, not a CTT analog macro.
- **Hybrid SLC-MLC RRAM Mixed-Signal PIM** (ISCA'25): gradient redistribution for transformer acceleration — MLC density story.
- **ReTransformer**, **memristor self-attention** (Nature Sci. Rep. 2024, s41598-024-75021-z): ReRAM crossbar attention — the analog-attention lineage.
- **All-in-One Analog AI (CMO/HfOx ReRAM)** (Adv. Funct. Mater. 2025, adfm.202504688): on-chip train+infer, **<4% drift after 72 h @85 °C** — a concrete drift datapoint to calibrate our digital twin against (cite for the drift-magnitude justification of §2.6).
- **"Memory Is All You Need"** (2406.08413): CIM-for-LLM survey — the framing reference for §2.2's CIM motivation.
- **4T2R macro** (existing): the 59–95.3 TOPS/W ceiling.

### 2F. Drift / reliability (AC-refresh neighbors)
- **VeRA+** (2603.26016, Mar'26): **vector-based lightweight *digital* drift compensation** for RRAM CIM (shared projection matrices + compact drift-scaling vectors), CNNs + Transformers. **The most recent and most direct drift competitor — must cite and differentiate.** Ours = physical in-situ AC anneal + common-mode rejection (zero-throughput, no digital correction pass); VeRA+ = digital scaling after drift. *They are stackable.*
- **Global-correction-factor** method (run test inputs post-program, scale digital output by drift ratio): the standard baseline; halt-and-measure cost — exactly what compute-during-refresh avoids.
- **Update-Disturbance-Resilient crossbars**, **Hamun** (2502.01502, approximate-compute lifespan extension): reliability via tolerance/wear-leveling, not refresh.

### 2G. KV cache & memory-bound decode
- **Persistent-state linear-attention** (2603.05931): full 2 MB recurrent state in BRAM → decode becomes compute-bound (Qwen3-Next GDN). Relevant to our KV-in-BRAM choice (§2.3).
- **CXL-SpecKV** (2512.11920): disaggregated speculative KV (datacenter) — out of edge scope, cite for completeness.
- **Embedded-FPGA decode bandwidth** (2502.10659): pushing memory BW/capacity utilization for decode — supports our ping-pong/URAM bandwidth argument.

---

## 3. Concrete architecture-sharpening actions (mapped to pillars/files)

Priority-ordered; none block C6, all are post-C6 candidates or related-work/framing edits.

1. **[Framing, do for the paper] Engage MX/MXFP head-on in §2.7.** Position BFP12 as the high-fidelity dequant-insurance tier above MXFP; map shred rungs to MXFP6/MXFP4 vocabulary. Add MX+, AMXFP4, F-BFQ, MXFormer to related work. *Highest-value framing gap.*
2. **[Framing] Related-work positioning of the Shred Oracle vs DP-LLM + FGMP.** Claim the *usage-driven memory-reclamation + promote-on-error insurance* combo; use DP-LLM's "sensitivity is dynamic" as support for the insurance loop. Honestly credit approximate-counting prior art.
3. **[Framing] Cite VeRA+ as the digital-drift baseline**; frame AC-refresh as the physical, zero-throughput complement (stackable). Keep µW TBD-pending-sim.
4. **[Post-C6 candidate] Sparse-attention dataflow** (FAST-Prefill liveness-driven dual-tier KV + TENET LP-aware sparse attention + dynamic N:M). Folds into our NoC/attention path; strong TTFT lever on long context — our current weak axis.
5. **[Post-C6 candidate] MXFP-compatible block mode** at the CSD dequant boundary for ecosystem interop (read MXFP-quantized checkpoints directly).
6. **[Metrics] Adopt the cohort's metric vocabulary** in eval: tok/s, **tok/J**, **GOPS/W**, **GOPS/mm²** (DSP-normalized), **TTFT**. Always annotate **power scope** (core vs system) — our KU5P core-power (DRAM external) is a *different and fairer* scope than FlightLLM/EdgeLLM's 45–57 W system+HBM; say so explicitly so the comparison is honest, not flattering.
7. **[Validation] Keep the dispatcher's asymmetric-pipelining story** as the alternative to PD-Swap's DPR (no reconfiguration latency) — a defensible design-choice contrast, not a deficiency.

---

## 4. Sources
Edge-LLM FPGA: FlightLLM [arXiv 2401.03868], EdgeLLM [2407.21325], TeLLMe [2504.16266] / v2 [2510.15926], PD-Swap [2512.11550], SwiftKV [2601.10953], LUT-LLM [2511.06174], TENET [2509.13765], FAST-Prefill [2602.20515], SpeedLLM [2507.14139], LlamaF [2409.11424], Platinum [2511.21910], F-BFQ [2510.13401]. Quant/MX: OCP MX standard, MX+ [MICRO'25 10.1145/3725843.3756118], AMXFP4 [ACL'25], MXFP PTQ benchmark [2601.09555], MXFP4 study [2603.08713], FGMP [2504.14152], ScaleBITS [2602.17698], Progressive MXP Decoding [2410.13461]. Dynamic precision: DP-LLM [2508.06041]. CIM/neuromorphic: MXFormer [2602.12480], Hybrid SLC-MLC RRAM PIM [ISCA'25], memristor self-attention [Nature s41598-024-75021-z], All-in-One CMO/HfOx [adfm.202504688], CIM survey [2406.08413], End-to-end PIM [2601.14260]. Drift: VeRA+ [2603.26016], Hamun [2502.01502], Update-Disturbance-Resilient [PMC12822454]. KV/memory: persistent-state linear attn [2603.05931], CXL-SpecKV [2512.11920], embedded-FPGA decode [2502.10659]. ASIC: Slim-Llama [ISSCC'25, IEEE 10904761].
