# Weight-Resident Batched GEMM — design contract (C1.5)

**Status:** design / contract (no RTL yet). Per CLAUDE.md §3, this is frozen and reviewed before any module changes.

**Author context:** written after tracing `dense_act_streamer → dense_array → cim_cell → dense_group → dispatcher` (the C1.5 investigation). It fixes the single structural reason the fabric measured 0.11% DSP utilization.

---

## 1. The problem, precisely

Today every GEMM pass (one token's matrix-vector) walks the 8×4 tile grid and **reloads the 512 PE weights at every tile** (`S_LAYER_WLOAD`, ~256-cycle serial scan) for **one beat** of compute. The load-to-compute ratio is ~256:1 → ~0.11% DSP utilization. This is structural, not a workload artifact:

- The `cim_cell` accumulates K beats against **fixed** weights: `y[j] = Σ_k Σ_i a_k[i]·W[i,j]` (verified in `dense_group.sv:4`). So `K_TILE>1` sums activations against one weight plane — **not** a real GEMM. `K_TILE` cannot be the throughput lever.
- A real contraction `d>128` is covered by repeated gr-walks accumulated in the bank (different weights per super-tile).
- A **batch of T tokens** currently = T independent full walks, each reloading all weights. **No weight reuse exists.**

**Goal:** reuse each tile's resident weights across a batch of **T tokens** (the prefill phase), so the 256-cycle weight load amortizes over T tokens of compute → utilization climbs toward peak as T grows. Decode (T=1) stays memory-bound by nature and is measured separately.

## 2. The key enabling fact (why this is even possible)

Each token's contribution at tile `(gr,gc)` is a **1-beat reduction** (16-element spatial dot product against the resident 16×32 weight plane). With `acc_clr=1` on **every** beat, the fused-MACC P-register holds a *fresh* result every cycle (load, not accumulate) — so T tokens can stream at **II=1** and their 32-wide partials fall out one per cycle once the 4-stage pipe is full. The weight plane never moves. This is the compute-bound regime the fabric was built for; we just never drove it.

## 3. Dataflow change — loop order

**Current (decode, reload-bound):**
```
for gr in 0..GR-1:                  # 8 row-tiles
  for gc in 0..GC-1:                # 4 col-strips
    WLOAD(gr,gc)                    # 256-cyc serial scan  <-- paid per (gr,gc) PER TOKEN
    stream 1 beat (this token)
    drain, snap -> bank[gc-strip] += partial
y_valid  # one 128-wide token output
```

**New (prefill, weight-resident batched):**
```
for gr in 0..GR-1:
  for gc in 0..GC-1:
    WLOAD(gr,gc)                    # 256-cyc scan  <-- paid ONCE for the whole batch
    for t in 0..T-1:               # T tokens stream through resident weights
      stream 1 beat (token t, band gr)
      snap -> bank[t][gc-strip] += partial
for t in 0..T-1: drain bank[t] -> y_out stream   # T token outputs
```

Weight load is now amortized over **T** tokens. The token loop is **innermost** to the `(gr,gc)` loop — that is the whole point, and it forces a per-token accumulator bank (§5).

## 4. New macro opcode

`OP_GEMM_BATCH` (joins `OP_GEMM_ALL`/`OP_GEMM_LAYER`). Fields on the 64-bit macro word:
- `row_cnt` (GR), `col_cnt` (GC) — tile-grid extents (as today).
- `k_cnt` — beats per token per tile (normally 1 for the matrix-vector; reserved for true shared-weight reductions).
- `batch_t` (**new**, e.g. 10 bits) — number of tokens T streamed through each resident weight tile.

Decode is `OP_GEMM_BATCH` with `batch_t=1` (identical to today's `OP_GEMM_LAYER`); prefill uses `batch_t=T`. We keep `OP_GEMM_LAYER` as the T=1 alias so existing tests don't regress.

## 5. The accumulator bank — the main structural change

`dense_array`'s bank grows from `128` to **`T × 128`** `array_acc_t` cells: `bank[t][col]`, accumulated as token `t`'s partials arrive across the gr-walk.

- **Small T (≤ ~8):** register file (`8×128×44 ≈ 45 kFF`, ~10% of device) — simplest, v1.
- **Large T (prefill batches of 32–256+):** the bank must move to **BRAM/URAM** with pipelined read-modify-write (one token/cycle). This is the v2 capacity step; the device has 416 spare BRAM. `T×128×44` for T=256 = 1.4 Mbit ≈ 40 BRAM.
- Clear policy: `bank[*]` cleared at the batch's first `tile_first`; each `bank[t][gc*32 +: 32]` accumulates across the 8 gr row-tiles; drained per token after the last gr-tile.

## 6. Snap / valid semantics — staged

**v1 (serial-per-token, low risk):** keep the existing `acc_clr → 1 beat → 3-cyc drain → acc_snap` sequence, but issue it **T times per tile without reloading weights**. Per-token overhead = the 3-cycle drain → utilization caps at ~`512/8 ≈ 12.5%`, but that is a **>100× improvement** over 0.11% and requires **no change to `cim_cell`/`dense_pe`/`dense_group` snap logic** — only the bank (§5) and the walker (§7). Ship this first; it proves correctness and weight residency.

**v2 (pipelined-snap, compute-bound):** stream T beats at II=1 with `acc_clr=1` each, snapping the P-register **every cycle** (continuous), bank RMW one token/cycle. Utilization → `T/(≈260+T)` → ~80% at T=1024. This requires relaxing the `a_no_snap_with_fire` assertion in `dense_group`/`cim_cell` and making the group y_valid/`dense_pe` snapshot **continuous** (a per-cycle valid, not a single post-drain pulse). Higher risk; do it after v1 is green and measured.

## 7. Dispatcher walker change

Add an inner token counter to the `OP_GEMM_BATCH` FSM:
- `S_LAYER_WLOAD` (unchanged) → on `load_done`, set `tok_idx=0`, enter `S_GEMM_ACC`.
- `S_GEMM_ACC/DRAIN/SNAP` (per token): on `S_GEMM_SNAP`, if `tok_idx < T-1` → `tok_idx++`, **re-arm GEMM without reload** (stay on resident weights, back to `S_GEMM_ACC`); else advance the tile (`gc/gr`) → `S_LAYER_WLOAD` (reload for the next tile).
- The `tile_first`/`tile_last` lifecycle now spans the whole batch (bank clear on first tile of first token-pass; drain after the last gr-tile per token).

## 8. Activation layout & addressing

Per-token bands must be addressable. Layout in dense URAM: `act_base + t·TOKEN_STRIDE + gr·BAND_STRIDE` (T tokens × GR bands × beat). The `act_base_c` computation in `archbetter_core` extends to add `tok_idx·TOKEN_STRIDE`. The streamer already takes a per-op `base_addr`; we drive it per (gr, token).

## 9. Golden model (the correctness contract)

For prefill, the golden produces **T independent token outputs**:
```
for t in 0..T-1:
  for c in 0..USED_COLS-1:
    y[t][c] = Σ_gr Σ_r x[t][gr*16+r] · W[gr*16+r][c]
```
The TB snapshots all T `y_valid` pulses and bit-compares each against `y[t]`. This is a strict superset of the current single-token golden (T=1 case must still pass bit-identical).

## 10. Latency / utilization model (what we expect to measure)

Per tile: `256 (WLOAD) + T·(beat + overhead)`. 
- v1: overhead ≈ 7 (drain+snap) → per-tile `256 + 8T`; batch util ≈ `T·512 / (GR·GC·(256+8T)) · ...` → caps ~12.5%.
- v2: overhead ≈ 0 (pipelined) → per-tile `256 + T + 4` → util `T/(260+T)` → ~50% at T=256, ~80% at T=1024.
Report both phases: **prefill** (this mode, large T, target compute-bound GOPS/util) and **decode** (T=1, memory-bound, report tokens/s + energy/token). This is the FlightLLM/EdgeLLM-style both-phase result.

## 11. Implementation stages (each ends sim-green, zero-warning per §3)

- **R1 — types/contracts:** add `OP_GEMM_BATCH`, `batch_t` field, `BATCH_T_MAX` param, bank type widening in `types_pkg`/`interfaces`. No behavior yet.
- **R2 — `dense_array` bank → T×128 (registers, v1):** new bank + per-token index; `tb_dense_array` extended with a 2-token directed case. Bit-exact golden.
- **R3 — dispatcher walker token loop:** `OP_GEMM_BATCH` FSM; `tb_dispatcher_layer`/`tb_dispatcher_compute` extended.
- **R4 — `archbetter_core` per-token act addressing + `tb_archbetter_core` batched golden + STAGE-5 prefill/decode split.** First real both-phase number.
- **R5 — measure (SAIF + util) on the prefill workload.** Confirm util jump.
- **R6 (v2) — pipelined continuous snap** for compute-bound util. Separate, after v1 lands.

## 12. Risks

- **Bank capacity at large T** (§5): v1 caps T small (registers); v2/large-T needs BRAM RMW — design the bank port for that from the start so v2 doesn't re-architect.
- **v2 snap-pipelining touches the cell/group contract** (the `a_no_snap_with_fire` assertion and the single-pulse y_valid). Highest-risk change; isolated to R6 and gated behind v1 being green.
- **Timing:** the T×128 bank RMW adder + the wider bank mux may pressure the NoC-router→DSP critical path (already at +0.057 ns). Watch WNS at R2.
- **Golden/layout drift:** the per-token activation layout must match the streamer's addressing exactly (the class of bug that already bit `tb_cim_cell` — keep the golden and the packer in one file).

---

## 13. R6 / v2 — pipelined continuous snap: full task breakdown

> **Status:** design / contract reconstruction (no RTL yet). R1–R5 (v1) are complete and green; the system-level layer runs end-to-end through `archbetter_soc_top` (C2/C3 green). R6 is the last weight-residency stage and the one that turns the structural weight-load win into a **compute-bound DSP-utilization** number for the prefill phase. **Gated behind v1 being green (it is) and behind a representative large-T workload existing.** This section exists so R6 is not dependent on a cleared chat.

### 13.0 The measured reality (read before scoping R6)

v1 (R1–R5) was measured: decode `OP_GEMM_LAYER` K=1 = **0.11 % DSP util, 0.28 GOPS, 7306 cyc/token**; `OP_GEMM_BATCH` T=8 = **~0.6–0.8 % util, ~1.6–2.1 GOPS, ~983 cyc/token** (the 8× weight-load win is real and bit-exact). Util stays <1 % at T=8 because **the binding bottleneck is the 256-cycle SERIAL weight scan per tile** (`dense_weight_streamer`, 64 words/tile), NOT the per-token snap drain.

**Therefore the v2 ledger is two-term, and R6's snap fix is necessary but NOT sufficient:**
- v2 cuts the per-token compute overhead from ~8 cyc → ~II=1 (the snap term).
- But the per-tile cost is `256 (weight scan) + per-token·T`. At small T the 256 dominates regardless of the snap. Compute-bound util needs **BOTH** (a) the snap pipelined (this section) **AND** (b) **large T** (hundreds–thousands of tokens) so the 256-cycle scan amortizes: util → `T / (≈260 + T)` → ~50 % at T=256, ~80 % at T=1024.
- Optional third lever (do only if large-T util still misses target): **parallelize/shorten the weight scan** (the streamer's 64-word serial scan → wider parallel scan or multi-port URAM read), attacking the 256 term directly. Track as **R6.opt**, not on the critical path.

So R6's success metric is **prefill DSP util at large T**, reported alongside the decode (T=1) memory-bound number — the FlightLLM/EdgeLLM both-phase result (§10).

### 13.1 Mechanism (why II=1 continuous snap is correct for K=1)

For a matrix-vector (`K_TILE=1`) each token's contribution at tile `(gr,gc)` is a **1-beat reduction** with `acc_clr=1` (LOAD, not accumulate). The fused MACC (AREG=2/MREG/PREG, 4-cycle latency) therefore holds a *fresh, complete* product in `p_reg` every cycle. Stream T token-beats back-to-back at **II=1**; after the 4-stage pipe fills, **one token's complete 32-wide partial falls out every cycle**. v1 throws this away by draining + single-snapping per token; v2 captures it continuously.

The bank update changes from "accumulate K beats then snap once" to "**one RMW per cycle**": on each cycle a result emerges, `bank[tok_out][gc-strip] += phys_strip`, where `tok_out` is the token whose beat entered the pipe `LAT` cycles earlier. **`tok_out` must be produced by a shift register of `tile_tok` aligned to the cell→group→array result latency** — getting this alignment wrong silently mis-accumulates tokens (the highest-risk bug; assert it).

### 13.2 Per-module changes

- **`cim_cell_4t2r`:** already emits `acc_valid` per beat at +4 (the valid shift register exists). No datapath change; the noise/clr pipeline already aligns. Keep `acc_clr` co-firing every beat (load mode).
- **`dense_pe`:** today snapshots `cell_acc` only on `acc_snap` (single pulse). v2: pass `cell_acc` + `cell_acc_valid` through **continuously** (per-cycle valid), OR snap every cycle `acc_valid` is high. New mode must not break v1 — gate behind a `CONTINUOUS_SNAP` parameter or a runtime `stream_mode` so `OP_GEMM_ALL`/decode still use the single-snap path.
- **`dense_group`:** make `y_valid`/`y_out` **continuous** (per-cycle when the column-reduction pipe is producing) instead of a single post-drain pulse. The combinational 16-input column-reduction tree is unchanged; only the output-register valid gating changes.
- **`dense_array`:** **(a)** drive a `tok_out` index from a `tile_tok` shift register aligned to the group result latency; **(b)** bank becomes **RMW one token/cycle** (`bank[tok_out] += phys_strip`); **(c)** at large T the register bank (`T·128·44`) is infeasible → move bank to **BRAM/URAM** with pipelined read-modify-write. Within one `(gr,gc)` every cycle is a *different* `tok_out`, so there is **no same-address RMW hazard**; the same token is only re-touched on the next gr-tile (after a weight reload, far apart) — so a simple 1–2-cycle-latency BRAM RMW suffices, but assert the no-collision invariant.
- **`dispatcher`:** new continuous-stream issue for `OP_GEMM_BATCH` — stream T beats back-to-back with `acc_clr=1` each, **no per-token `S_GEMM_DRAIN`/`S_BATCH_REARM`**. One drain at the end of the tile's token run (pipe flush), then advance the tile. `gemm_issue_if`/`dense_sched_if` may need a `stream_len`/`continuous` sideband.
- **`dense_act_streamer`:** must deliver **T distinct token activation bands back-to-back at II=1** (v1 re-reads the same band — system-level batch is currently structural, not distinct-token; proven distinct only at unit level `tb_dense_array` T4). Per-token base = `act_base + tok·TOKEN_STRIDE + gr·BAND_STRIDE` (§8). The 144→192b two-read-per-beat assembly (act streamer) caps II at ~2; **widen the dense ping-pong cascade to 192b (1 read/beat)** to hit true II=1 — track as **R6.act-width**.
- **Assertions to relax (carefully, with replacements):** `dense_group::a_no_snap_with_fire` and `cim_cell::a_clr_*`/`dense_pe::a_no_clr_and_snap` semantics — in v2 snap IS continuous with beats. Replace each relaxed assertion with a v2-mode-specific invariant (e.g. "continuous y_valid implies a token beat entered exactly LAT cycles earlier", "tok_out monotonic within a tile's token run"). **Do not just delete them** — every relaxation gets a replacement contract, per the zero-warning/assertion discipline.

### 13.3 Staged sub-tasks (each ends sim-green + zero-warning per CLAUDE.md §3/§9)

- **R6.1 — contracts/params:** add `CONTINUOUS_SNAP`/`stream_mode` to types/interfaces; add `tok_out` sideband + latency param. No behavior. Elaboration-clean.
- **R6.2 — `dense_pe` + `dense_group` continuous snap** (mode-gated; v1 path untouched). Extend `tb_dense_pe`/`tb_dense_group` with a continuous-stream directed case; relaxed assertions get replacement invariants. Bit-exact vs golden.
- **R6.3 — `dense_array` tok_out pipeline + per-cycle bank RMW (registers, small T first).** Extend `tb_dense_array` with a multi-token II=1 case; verify `tok_out` alignment bit-exact (this is the alignment-bug gate). Keep bank in registers at small T to isolate the snap change from the capacity change.
- **R6.4 — `dispatcher` continuous-stream issue for `OP_GEMM_BATCH`.** Extend `tb_dispatcher_compute`/`tb_dispatcher_layer`. No per-token drain; single end-of-run flush.
- **R6.5 — distinct-token activation addressing** (`dense_act_streamer` per-token base + the 192b cascade widen, R6.act-width). `tb_dense_act_streamer` + `tb_archbetter_core` extended with **distinct-token** golden (each drained output differs).
- **R6.6 — bank → BRAM/URAM RMW for large T.** Re-target the `dense_array` bank; verify no-collision invariant; large-T directed test. This is the capacity step (§5/§12).
- **R6.7 — measure prefill util at large T** (`tb_archbetter_core` STAGE-5, then SAIF via C6). Confirm util → compute-bound; report decode (T=1) + prefill (large T) both-phase numbers.
- **R6.opt (only if needed) — parallelize the 256-cycle weight scan** to attack the residual `~260` term.

### 13.4 Exit criteria / gates

- Every R6.x ends sim-green with replacement assertions in place (no net loss of contract coverage).
- v1 paths (`OP_GEMM_ALL`/decode, single-snap) remain bit-exact and green throughout (mode-gated, regression-protected).
- R6.7 produces a **prefill DSP-util** number materially above the v1 ~12.5 % ceiling (target compute-bound, model `T/(≈260+T)`), reported next to the decode memory-bound number.
- WNS watched at R6.3 and R6.6 (bank RMW adder + wider mux pressure the NoC-router→DSP path already at the thin +0.057 ns OOC slack; non-OOC closure is C5).

### 13.5 Sequencing vs the C-plan

R6 is **independent of C4/C5** (XDC + non-OOC closure) but **feeds C6** (the representative compute-bound SAIF needs large-T prefill = R6 + C2 weight streaming from DRAM). Recommended order: **C4 → C5 (get the honest non-OOC closure + real MMCM/MIG) → R6 (compute-bound util) → C6 (vectored power on the R6 large-T prefill workload).** R6 can also proceed in parallel with C4/C5 since it touches the dense core, not the board seam.

---

## 14. R6.8b — activation-fetch width (the II floor): scope

### 14.0 Why this exists (the measured wall, audited 2026-06-22)

R6.5–R6.8a took GEMM-phase DSP util **0.81% → 9.69%** (effective II 16.2 → 10.3; ~6.8 pure-streaming after subtracting the per-tile 256-cyc weight scan). R6.8a-cont then proved the remaining wall is **not** fetch depth and **not** the present path:

- **Fetch depth is saturated at 8.** Adapter/streamer depth 8→16 gave *byte-identical* results (18376 cyc, II 10.32). 2→8 helped; 8→16 did nothing.
- **The present path is unconditionally 1 beat/cycle** (full audit): dispatcher `S_GEMM_CONT` advances purely on `beat_fire` (no per-beat stall); streamer present is `src.valid = !fifo_empty`; `noc_router.in_ready` is combinational; **`dense_array` sink is hardwired `a_strm.ready = 1'b1`**. Nothing downstream backpressures.

So the limiter is the **activation FILL rate**, and it is *structural*: one beat = one 192b BFP12 mantissa block (+8b exp = 200b of data) is read through a **single 72b URAM288 port** as **2 cascade words × 2 native reads = 4 serial native reads/beat = II=4 floor** (the per-tile scan + assembly stretch it to ~6.8). 288b of storage holds 200b of data. This is the only remaining lever on DSP util.

### 14.1 The physical constraint

`uram_pingpong` exposes one **72b** read port per bank (one compute-side bank read at a time; the other is the CSD fill side). Reading 200b through a 72b port is inherently ≥3 cycles. **Going below II=3 requires reading wider per cycle = multiple URAM288 side-by-side at the same address** (URAM cascade is for depth, not width — width = parallel banks). This is the architectural core of R6.8b.

### 14.2 Utilisation model (what each II buys)

Established model: `util ≈ T / (256 + II·T)` (256 = per-tile weight scan; 1·T of the II·T stream is useful).

| II | mechanism | util @ T=64 | util @ T=255 | util @ T=1024 |
|----|-----------|-------------|--------------|----------------|
| 4 (today) | 4 serial natives/beat, 1×72b port | 12.5% (cap; 9.7% meas.) | 28% | 80%* |
| 3 (Tier A) | pack 200b into 3 natives, 1×72b port | 14.5% | 33% | 80%* |
| 2 (Tier B) | 2×72b parallel port (144b/cyc) | 20% | 50% | 89% |
| 1 (Tier C) | 3×72b parallel port (216b/cyc) | 20%† | 50%† | **80%** |

\* II=4/3 only reach ~80% at T≫1024 — impractical (bank depth, see 14.5).
† II=1 at small T is scan-bound (the 256 dominates), so **II=1 alone is not the headline — it needs large T too** (R6.8c, §14.4). The headline 80% = **II=1 AND T=1024**.

**Takeaway:** Tier A (II=3) is nearly free but barely moves util. **Tier C (II=1) is the headline path** but is the largest change. Tier B (II=2) is the lower-risk intermediate.

### 14.3 Per-tier work breakdown

**Tier C (II=1) — the headline. Read a whole beat in one cycle.**
- **Storage:** widen the *dense* ping-pong compute/fill banks from 1×URAM288 to **3×URAM288 side-by-side** (216b logical word, same address). Dense pair goes 2→6 URAMs; pool total ~5→~9 of 64 (≈14%, well under the 75% headroom). `(* ram_style="ultra" *)` preserved.
- **Remove the cascade adapter from the dense activation path.** The 1→2 native serializer (`uram_cascade_adapter`) is the II=4 mechanism; a 216b parallel read replaces it. (Adapter stays on any path still using a 72b port — confirm the sparse/TLMM path, which can keep it.)
- **Streamer** (`dense_act_streamer`): drop the lo/hi cascade pairing — one read returns a full beat. `present`/FIFO/`outstanding` logic unchanged; assembly collapses to a passthrough. Beat format on `strm.src` is **byte-identical** (192b data + 8b user), so the NoC/array/goldens downstream are untouched.
- **CSD fill** (`csd_drain_engine`, `csd_engine`): write the activation strip **striped across the 3 sub-banks** (mantissa thirds + exp) instead of 4 sequential 72b words. The §2.7 qN→BFP12 dequant must emit the new striped layout at the URAM-fill boundary.
- **Memory manager**: instantiate the wide dense ping-pong; re-route the dense read port; keep sparse pair as-is.
- **Params/types**: add the dense-activation wide-read width (216b) + striping constants to `types_pkg`; `PP_DATA_W` on the dense path becomes 216 (or a packed-beat constant).

**Tier B (II=2) — intermediate.** Same as C but **2×URAM288** (144b/cyc); a beat is 2 reads (mant[0..7]+exp, mant[8..15]). Adapter retained but reads pairs in parallel. Dense pair 2→4 URAMs. Smaller golden/fill rework (still a 2-word layout, just parallel not serial).

**Tier A (II=3) — pack-only, cheapest, low payoff.** Keep the single 72b port; just **pack 200b into 3 natives (216b, 16b pad)** instead of 4 (288b, no padding waste). Generalize the adapter to issue N=3 natives/beat; streamer assembles 3 not 2+2. No new URAMs, no parallel ports. ~9.7%→~14.5% util — useful only as a stepping stone or if URAM budget were tight (it isn't).

### 14.4 R6.8c (separate prerequisite for the 80% headline): widen `BATCH_TOK_W`

`BATCH_TOK_W = 8` caps T ≤ 255 → ≤ 50% util even at II=1. The 80% headline needs **T = 1024 → `BATCH_TOK_W = 11`** (`tok_idx_t`, `gemm_batch_n_r`, the bank `{tok,gc}` address, and `BATCH_TOK` in the cont TBs). Mechanically simple but **gated by bank capacity (14.5)**. Scope as R6.8c, after R6.8b lands II=1 (no point widening T while II=4).

### 14.5 Costs & risks
- **Bank depth at large T:** the dense_array BRAM accumulator is `depth = BATCH_T × TILE_COLS(4)`, word 1408b. At T=1024 → 4096×1408b ≈ 5.77 Mb ≈ **~160 BRAM36 (~33% of 480)** — feasible but no longer negligible; verify against the §1 BRAM headroom and the KV-cache claim before committing R6.8c.
- **Timing:** R6.3/R6.6 already sit at ~+0.057 ns OOC slack on the NoC-router→DSP path. A 216b parallel read + striped fill adds mux/routing pressure; **watch WNS** (and prefer landing R6.8b after C5 non-OOC closure so the slack is real).
- **Goldens:** every TB that builds or consumes the activation image changes layout — `tb_archbetter_core_cont`, `tb_dense_act_streamer`, `tb_memory_manager`, `tb_uram_pingpong`, `tb_uram_cascade_adapter`, plus the §2.7 dequant golden. Bit-exact gate must re-pass per format.
- **Scope honesty:** the *v2 datapath correctness* and the *stall-free present-path audit* are already bankable. R6.8b is purely a util-headline lever; if the paper's framing tolerates ~10% (it is still ~12× v1-sustained and ≈ the v1 single-snap cap), R6.8b can be deferred entirely.

### 14.6 Staged sub-tasks (each ends sim-green + zero-warning per CLAUDE.md §3/§9)
- **R6.8b.1** — `types_pkg` wide-read + striping constants; widen dense `uram_bank`/`uram_pingpong` to 3× (param `WIDE=3`); `tb_uram_pingpong` wide-read case. *(delete `project_1.sim` after pkg edit — stale .sdb.)*
- **R6.8b.2** — CSD fill striped-layout write (`csd_drain_engine`/`csd_engine` + §2.7 dequant); `tb_csd_*` + golden bit-match.
- **R6.8b.3** — `dense_act_streamer` collapse cascade pairing → single wide beat; bypass adapter on dense path; `tb_dense_act_streamer` (II=1 case).
- **R6.8b.4** — `memory_manager` wide dense ping-pong wiring; `tb_memory_manager` regression.
- **R6.8b.5** — in-situ measure: `tb_archbetter_core_cont` @ BATCH_T=64 → expect **II≈1, util ≈20%** (T=64). Confirm present-path still stall-free; confirm v1 (PER_TOKEN) bit-identical.
- **R6.8c (optional)** — `BATCH_TOK_W=11`, bank-depth/BRAM check, T=1024 run → **util ≈80%**. *Then* C6 SAIF.

### 14.7 Exit criteria
- Bit-exact vs golden in all touched TBs (correctness never traded — CLAUDE.md §8).
- `tb_archbetter_core_cont` reports II≈1 (Tier C) with the present path still proven stall-free.
- v1 PER_TOKEN path byte-identical (zero regression).
- WNS non-negative at the target clock (post-C5, non-OOC); URAM/BRAM within §1 headroom.

### 14.8 R6.8b.2 design revision — WIDE=4 transparent container (supersedes the §14.3 WIDE=3 Tier C)

Mapping the real topology before writing the fill revealed two facts that change the plan:
1. **The dense ping-pong is shared** by the weight streamer and the act streamer — `archbetter_core` muxes both onto ONE cascade read port (`dense_rd_sel_wt = sched.load_busy`) through ONE `uram_cascade_adapter`. So a wide bank serves BOTH paths: it lifts the act II floor AND shrinks the 256-cyc weight scan. (Bonus util beyond the §14.2 table, which only modelled activations.)
2. **`csd_engine` fill is a content-agnostic 72b pass-through** (1 DRAM beat → 1 URAM word). A wide word is therefore a *transparent N-native container*: if the fill groups natives [W·N .. W·N+N-1] into wide word W's leaves and the read returns all N, the stored content (weight OR act block) is preserved bit-exactly **with no knowledge of the block structure**.

**Decision: use WIDE=4 (288 b), not WIDE=3 (216 b).** The current cascade layout already stores 4 natives/block = 288 b, so:
- **Zero golden / DRAM-image re-layout** — the existing 4-native-per-block image maps 1:1 onto 4 leaves. (This was §14.5's biggest risk; it evaporates.)
- **Power-of-2 leaf addressing**: `leaf = native_addr[1:0]`, `wide_addr = native_addr >> 2`. No mod-3.
- **Minimal streamer change (.3)**: the 288 b wide word IS the `{hi,lo}` cascade pair the streamer already slices; it just arrives in one read instead of four.
- **Storage unchanged** vs today (still 288 b/block). Cost is +2 URAM/bank vs WIDE=3 → dense pair 2→8 URAM, pool ~5→~11 of 64 (~17%, well under 75%).

`DENSE_ACT_URAM_*` is renamed `DENSE_PP_URAM_*` (it serves the whole shared dense pp, not just activations). Packing is a transparent container, so the §14.0 `{pad,block}` framing is dropped — the wide word holds 4 raw natives in leaf order.

**R6.8b.2 deliverable (revised):** a standalone `csd_wide_fill` adapter that assembles N=`DENSE_PP_URAM_WIDE` consecutive 72 b fill beats into one full-width wide write (leaf = `fill_addr % N`, wide_addr = `fill_addr / N`), keeping `csd_engine` and the R6.8b.1 full-width-write bank UNCHANGED. Unit-tested standalone (`tb_csd_wide_fill`); wired onto the dense fill branch in memory_manager at R6.8b.4. Per-descriptor N-alignment (n_beats % N == 0, base N-aligned) holds for the weight (224 natives/tile) and activation (32 natives/token) images and is asserted (fail-loud, like the Phase-2 `compressed==0` contract).
