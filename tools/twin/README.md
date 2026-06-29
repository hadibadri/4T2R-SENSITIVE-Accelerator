# ArchBetter Digital Twin (bit-accurate)

A bit-accurate Python twin of the ArchBetter numeric path that runs a **real
TinyLlama-1.1B**, measures **perplexity** (the gate on our decode story), and
projects **TTFT / throughput** from the RTL-calibrated cycle model — with **honest,
sourced** competitor comparisons and visualization.

Runs on a **local RTX 4070 (recommended)** or free Colab. The v1 runner crashed
Colab; v2 (this version) does not — see *Why it no longer crashes* below.

## Files
| File | Role |
|---|---|
| `bitexact.py` | bit-accurate BFP12 / ternary / shred kernels, mirrored from `types_pkg.sv`; the slow-but-literal integer reference. `validate_against_golden()` makes "bit-exact" a PASS/FAIL |
| `twin_runner.py` | loads TinyLlama, rounds weights/activations through the bit-accurate path, `precision_sweep()` (PPL) + `perf_projection()` (TTFT/throughput) |
| `competitors.py` | **sourced** cohort numbers (arXiv-cited, scope+model-tagged, `None` for unreported) — nothing invented |
| `viz.py` | Pareto scatter + radar + honest tables (no vanity bars; we land where the number lands) |

## The two cells do DIFFERENT things — read this (it was the confusion)
- **Cell 2 = `perf_projection()` — the calibrated *timing* model. It is NOT arbitrary.**
  Timing **cannot** come from this Python: a numpy/torch BFP12 forward is ~1000× slower
  than the FPGA, so wall-clock here would be physically meaningless. The legitimate
  number is the analytical cycle model **calibrated to the cycle-exact RTL sim** (the
  measured 27165-cycle point). Disclosed as *model-projected (calibrated to bit-exact
  RTL)*, not silicon. This is exactly how serious accelerator papers report TTFT before tapeout.
- **Cell 3 = `precision_sweep()` — the model ACTUALLY run through the architecture's math.**
  This is the real experiment: TinyLlama's weights and activations are rounded to the
  ArchBetter BFP12 / shred / ternary formats and a true forward pass produces
  **perplexity**. The PPL delta vs fp16 is what decides how aggressive we can be, which
  picks the decode tok/s out of the 27→95 band (resolves A5/A6 in `docs/ANALYTICS_MODEL.md`).

## Why it no longer crashes (the v1→v2 fix)
v1 routed every `nn.Linear` through a Python `for`-loop block quantizer
(`np.ndindex` over every 16-element block) and re-quantized every weight to float64 on
**every forward call** — billions of iterations + ~4.4 GB float64 copies → Colab
watchdog kill. v2 uses the exact algebraic identity

```
sum_k mant_a[k]·mant_w[k]·2^(Ea+Ew)  ==  dequant(a) · dequant(w)
```

so the BFP12 integer-MAC equals *(BFP12-rounded activation) @ (BFP12-rounded weight)*
(the only difference is 44-bit accumulator saturation, already the golden-check caveat).
So v2 (1) rounds each weight to its policy ONCE, in place, (2) rounds activations with a
tiny **GPU-native vectorized** pre-hook, (3) runs the **normal fast matmul**. Same
numbers, seconds on a 4070, minutes on Colab CPU. `bitexact.py` stays the literal
integer reference for `validate_against_golden`.

## Run it locally on your RTX 4070 (recommended — no crashes, faster than free Colab)
You do **not** need Colab, and you do **not** use the ollama `llama3` GGUF (see note
below). One-time setup in the repo:
```bash
pip install torch --index-url https://download.pytorch.org/whl/cu121   # CUDA build for the 4070
pip install transformers accelerate datasets matplotlib pandas
```
Then from `tools/twin/`:
```python
import twin_runner as T, competitors as C, viz as V
print(C.HONESTY)

# (a) timing projection — calibrated cycle model (instant)
T.perf_projection(decode_model="bfp12_shred", dram_bw_gbs=25.6, sigma=1.8)

# (b) THE pivotal experiment — perplexity through the real arch math (uses the GPU)
ppl = T.precision_sweep(n_tokens=512)        # auto-detects cuda
```
`measure_perplexity()` / `precision_sweep()` take `device=None` and auto-select `cuda`
when available (fp16 on GPU, fp32 on CPU). TinyLlama-1.1B fp16 is ~2.2 GB — trivial on
12 GB of 4070 VRAM.

### Why not the ollama `llama3:latest` GGUF you already have?
That file is a **4-bit GGUF for llama.cpp**, a different model (Llama-3 8B) in a
container our pipeline can't read, already lossy-quantized. The twin needs the
**original fp16 weights** so the ArchBetter rounding is the *only* error source —
otherwise we'd be measuring llama.cpp's q4 error, not ours. So the twin pulls
`TinyLlama/TinyLlama-1.1B-Chat-v1.0` (safetensors fp16) from Hugging Face on first run.
Converting the GGUF into our BFP12 path would be both bizarre and scientifically wrong.
Leave ollama as-is; it's unrelated.

## Run it on free Colab (copy-paste cells)

**Cell 1 — deps + upload the 4 files** (Runtime ▸ change runtime type ▸ T4 GPU):
```python
!pip -q install transformers accelerate datasets matplotlib pandas
from google.colab import files
print("Upload bitexact.py, twin_runner.py, competitors.py, viz.py:")
files.upload()   # select all four
```

**Cell 2 — perf projection (instant; the calibrated cycle model, NOT arbitrary):**
```python
import twin_runner as T, competitors as C, viz as V
print(C.HONESTY)
T.perf_projection(decode_model="bfp12_shred", dram_bw_gbs=25.6, sigma=1.8)
```

**Cell 3 — the PIVOTAL experiment: perplexity sweep (the real arch run; no longer crashes):**
```python
ppl = T.precision_sweep(n_tokens=512)   # fp16 / bfp12 / bfp12_shred / ternary
base = ppl.get("fp16")
for k, v in ppl.items():
    d = (v - base) if isinstance(v, (int, float)) and isinstance(base, (int, float)) else None
    print(f"{k:14s} PPL={v}  Δvs-fp16={'' if d is None else round(d, 3)}")
# Δ tells you how aggressive you can be -> picks the decode tok/s out of 27..95.
```

**Cell 4 — honest visualization:**
```python
import matplotlib.pyplot as plt
display(V.cohort_table(C.COHORT, C.ARCHBETTER))      # sourced table, n/r where unreported
V.pareto_throughput_power(C.COHORT, C.ARCHBETTER); plt.show()   # we are NOT top-left of everyone
V.radar_frontier(C.COHORT, C.ARCHBETTER); plt.show()           # model-agnostic shape
V.efficiency_bars(C.COHORT, C.ARCHBETTER); plt.show()          # GOPS/W, sorted by value
V.archbetter_internal_power_pie(
    {"Signals":0.274,"Clocks":0.258,"CLB":0.158,"DSP":0.130,
     "BRAM":0.099,"MMCM":0.083,"URAM":0.069,"IO":0.009}); plt.show()
```

## Honesty contract (enforced in code, not just prose)
1. **No invented numbers.** Competitor values are exactly as published; unreported = `n/r` and the work is **dropped** from that axis (never a fabricated bar).
2. **Model mismatch surfaced.** Cohort tok/s is **LLaMA2-7B**; ours is **TinyLlama-1.1B** — *not* raw-comparable. Head-to-head uses model-agnostic axes (GOPS/W, power, clock); tok/s always carries its model.
3. **Power scope labeled.** core (ours, DRAM external, §11) vs system+HBM (FlightLLM/EdgeLLM) — annotated on every chart, never compared raw.
4. **Measured vs projected.** Our `[M]` (measured) and `[P]` (projected) points render distinctly; the decode tok/s and prefill GOPS are `[P]` until the perplexity sweep lands.
5. **No us-on-top.** Bars are sorted by value; the Pareto/radar show where we **lose** as plainly as where we win.

## Validation status (be honest about it)
- **Format-faithful now; bit-exact once the golden check passes.** Two rounding rules
  (`# RTL-XCHECK` in `bitexact.py`: BFP12 exponent/mantissa rounding, cross-block 44b
  alignment) must be confirmed against RTL golden vectors. Dump `{a_fp, w_fp, y_int44}`
  from `tb_archbetter_core`/`tb_archbetter_soc_top` into an `.npz` and run
  `bitexact.validate_against_golden("golden.npz")` → `(passed, max_ulp)`. Until it
  returns `(True, 0.0)`, the twin reports **UNVALIDATED** and PPL is provisional.
- **Perplexity** is the first real result that gates the decode claim (A5/A6). It is
  **measured** by running the model, not assumed.
- **TTFT/throughput** are model-projected (calibrated to the 27165-cycle RTL point),
  disclosed as such — not silicon-measured.

## What this resolves
The perplexity sweep converts the `[P]` decode rows into a defensible number: if BFP12+shred
holds PPL (near-lossless), decode is **27–54 tok/s** at standard board DRAM; if ternary-FFN also
holds, **47–95**. That, plus the measured core power and prefill compute roof, is an eval that
stands beside EdgeLLM/TeLLMe — on the *combined* edge frontier, with model + scope stated.
